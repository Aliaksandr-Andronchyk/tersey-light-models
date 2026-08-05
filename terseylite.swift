#!/usr/bin/env swift
// Tersey Lite — тончайшая коробка: один ввод → и Claude, и Codex отвечают.
// Нативный AppKit, один файл + cube.s (фейковое 3D на рукописном ARM64-асме).
// Сборка:  clang -c cube.s -o cube.o && swiftc -O terseylite.swift cube.o -o TerseyLite
import AppKit

// ── палитра (светлая, как у большого Tersey) ─────────────────────────────
func hex(_ h: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(h.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let BG = hex("#faf9f5"), FG = hex("#1a1a18"), MUT = hex("#8a8778"), LINE = hex("#e3e0d6")
let CLA = hex("#c96442"), COD = hex("#2f7d6b"), OKC = hex("#3a8a4a"), ERRC = hex("#c0392b")

let selfPath = #filePath
func weightKB() -> String {
    var sz = (try? FileManager.default.attributesOfItem(atPath: selfPath))?[.size] as? Int ?? 0
    if sz == 0, let exe = Bundle.main.executablePath { // из .app исходника не видно — вес бинарника
        sz = (try? FileManager.default.attributesOfItem(atPath: exe))?[.size] as? Int ?? 0
    }
    return String(format: "вес: %.1f КБ", Double(sz) / 1024)
}

// ── фейковое 3D: математика в cube.s, рукописный ARM64 ───────────────────
@_silgen_name("cube_rotpro")
func cubeRotPro(_ sinY: Double, _ cosY: Double, _ sinX: Double, _ cosX: Double,
                _ out: UnsafeMutablePointer<Double>)

final class CubeView: NSView {
    var a = 0.6, b = 0.35
    override init(frame: NSRect) {
        super.init(frame: frame)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            s.a += 0.029; s.b += 0.017
            s.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 40) }
    override func draw(_ dirty: NSRect) {
        var pts = [Double](repeating: 0, count: 16)
        cubeRotPro(sin(a), cos(a), sin(b), cos(b), &pts)
        let cx = bounds.midX, cy = bounds.midY
        let s = min(bounds.width, bounds.height) * 0.62
        func pt(_ i: Int) -> NSPoint {
            NSPoint(x: cx + CGFloat(pts[i * 2]) * s, y: cy + CGFloat(pts[i * 2 + 1]) * s)
        }
        let path = NSBezierPath()
        path.lineWidth = 1
        for i in 0..<8 {
            for j in (i + 1)..<8 where ((i ^ j).nonzeroBitCount == 1) {
                path.move(to: pt(i)); path.line(to: pt(j))
            }
        }
        CLA.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

// ── поиск CLI и запуск ───────────────────────────────────────────────────
func findBin(_ name: String, _ extra: [String]) -> String {
    let home = NSHomeDirectory()
    var cands = extra.map { $0.replacingOccurrences(of: "~", with: home) }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        cands.append("\(dir)/\(name)")
    }
    return cands.first { FileManager.default.isExecutableFile(atPath: $0) } ?? name
}
let claudeBin = findBin("claude", ["~/.local/bin/claude"])
let codexBin = findBin("codex", ["~/.local/opt/node-v22.23.1-darwin-arm64/bin/codex"])

// окружение для CLI: codex.js стартует через `env node`, а node у GUI-процессов
// не в PATH — подкладываем каталоги обоих найденных бинарников
func cliEnv() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY", "OPENAI_API_KEY", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID", "CODEX_API_KEY"] { env.removeValue(forKey: key) }
    let dirs = [claudeBin, codexBin].map { ($0 as NSString).deletingLastPathComponent }
        .filter { !$0.isEmpty }
    env["PATH"] = (dirs + [env["PATH"] ?? ""]).joined(separator: ":")
    return env
}

// блокирующий запуск (для --version)
func runCLI(_ argv: [String], timeout: TimeInterval, cwd: URL? = nil) -> (out: String, err: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    if let cwd { p.currentDirectoryURL = cwd }
    p.environment = cliEnv()
    let outP = Pipe(), errP = Pipe()
    p.standardOutput = outP; p.standardError = errP
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return ("", "[ошибка] \(error.localizedDescription)", false) }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    let o = outP.fileHandleForReading.readDataToEndOfFile()
    let e = errP.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: o, encoding: .utf8) ?? "",
            String(data: e, encoding: .utf8) ?? "",
            p.terminationStatus == 0)
}

// потоковый запуск: каждая строка stdout → onLine (JSONL от обоих CLI)
func streamCLI(_ argv: [String], cwd: URL?, timeout: TimeInterval,
               onLine: @escaping (String) -> Void) -> (err: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    if let cwd { p.currentDirectoryURL = cwd }
    p.environment = cliEnv()
    let outP = Pipe(), errP = Pipe()
    p.standardOutput = outP; p.standardError = errP
    p.standardInput = FileHandle.nullDevice
    let lock = NSLock()
    var buf = Data(), errData = Data()
    outP.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        lock.lock()
        buf.append(d)
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.prefix(upTo: nl)
            buf = Data(buf.suffix(from: buf.index(after: nl)))
            if let s = String(data: line, encoding: .utf8), !s.isEmpty { onLine(s) }
        }
        lock.unlock()
    }
    errP.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        lock.lock(); errData.append(d); lock.unlock()
    }
    do { try p.run() } catch { return ("[ошибка] \(error.localizedDescription)", false) }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    p.waitUntilExit()
    outP.fileHandleForReading.readabilityHandler = nil
    errP.fileHandleForReading.readabilityHandler = nil
    lock.lock()
    if !buf.isEmpty, let s = String(data: buf, encoding: .utf8),
       !s.trimmingCharacters(in: .whitespaces).isEmpty { onLine(s) }
    let err = String(data: errData, encoding: .utf8) ?? ""
    lock.unlock()
    return (err, p.terminationStatus == 0)
}

// баннер codex из stderr: model / sandbox / reasoning effort
func codexBanner(_ err: String) -> String {
    var model = "", sandbox = "", eff = ""
    for l in err.components(separatedBy: "\n") {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("model: ") { model = String(t.dropFirst(7)) }
        else if t.hasPrefix("sandbox: ") { sandbox = String(t.dropFirst(9)) }
        else if t.hasPrefix("reasoning effort: ") { eff = String(t.dropFirst(18)) }
    }
    return [model, eff.isEmpty ? "" : "effort \(eff)", sandbox]
        .filter { !$0.isEmpty }.joined(separator: " · ")
}

// ── UI ───────────────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var outC: NSTextView!, outX: NSTextView!
    var entry: NSTextField!, status: NSTextField!, btn: NSButton!
    var labC: NSTextField!, labX: NSTextField!
    var metaC: NSTextField!, metaX: NSTextField!
    var modeSeg: NSSegmentedControl!, effortSeg: NSSegmentedControl!
    var modelPopC: NSPopUpButton!, modelPopX: NSPopUpButton!
    var dirBtn: NSButton!
    var pending = 0
    // ── фейковое 3D всей аппы: CALayer-перспектива + параллакс за мышкой ──
    var tiltOn = true
    var tiltViews: [(NSView, CGFloat)] = [] // (вью, базовый наклон по Y в радианах)
    var mouseDX: CGFloat = 0, mouseDY: CGFloat = 0
    var sessC: String?, sessX: String? // память диалога (resume)
    // состояние текущего запроса (трогаем только с main)
    var metaEndC = "", okC = true, gotTextC = false
    var tokensX = "", gotTextX = false
    // рабочая папка агентов; при запуске из .app cwd = "/", тогда — ~/Avatar
    var workDir: URL = {
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd == "/" ? NSHomeDirectory() + "/Avatar" : cwd)
    }()

    let mono = NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    let monob = NSFont(name: "Menlo-Bold", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .bold)
    let small = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)

    var isWork: Bool { modeSeg.selectedSegment == 1 }
    var effort: String { ["low", "medium", "high"][effortSeg.selectedSegment] }
    // выбор модели: пустая строка = дефолт CLI (у claude — настройка подписки,
    // у codex — model из ~/.codex/config.toml)
    let modelsC = ["", "fable", "opus", "sonnet", "haiku"]
    let modelsX = ["", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-pro"]
    var modelC: String { modelsC[max(0, modelPopC.indexOfSelectedItem)] }
    var modelX: String { modelsX[max(0, modelPopX.indexOfSelectedItem)] }

    func modelPop(_ titles: [String]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.font = small
        p.controlSize = .small
        p.setContentHuggingPriority(.required, for: .horizontal)
        return p
    }

    func label(_ text: String, _ color: NSColor, _ f: NSFont) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = color; l.font = f; l.backgroundColor = .clear
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func pane() -> (NSScrollView, NSTextView) {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        sv.borderType = .lineBorder
        tv.isEditable = false
        tv.font = mono
        tv.backgroundColor = .white
        tv.textContainerInset = NSSize(width: 12, height: 10)
        return (sv, tv)
    }

    func append(_ tv: NSTextView, _ text: String, _ color: NSColor) {
        let a = NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: mono])
        tv.textStorage?.append(a)
        tv.scrollToEndOfDocument(nil)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu(), appItem = NSMenuItem()
        let sub = NSMenu()
        sub.addItem(withTitle: "Quit TERSEY · lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = sub; menu.addItem(appItem)
        // Edit-меню — без него Cmd+C/V/X/A не работают в поле ввода
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "TERSEY · lite"
        window.minSize = NSSize(width: 700, height: 460)
        window.backgroundColor = BG
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        ])
        func full(_ v: NSView) { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true }

        // шапка: куб (асм!) + имя + вес + режим/effort + папка + новый + статус
        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 12
        status = label("готов", MUT, small)
        modeSeg = NSSegmentedControl(labels: ["план", "ворк"], trackingMode: .selectOne,
                                     target: nil, action: nil)
        modeSeg.selectedSegment = 1 // по дефолту ворк = байпас
        modeSeg.font = small
        effortSeg = NSSegmentedControl(labels: ["low", "med", "high"], trackingMode: .selectOne,
                                       target: nil, action: nil)
        effortSeg.selectedSegment = 2
        effortSeg.font = small
        let newBtn = NSButton(title: "новый", target: self, action: #selector(reset))
        newBtn.bezelStyle = .rounded
        newBtn.font = small
        dirBtn = NSButton(title: "📁 \(workDir.lastPathComponent)", target: self, action: #selector(pickDir))
        dirBtn.bezelStyle = .rounded
        dirBtn.font = small
        dirBtn.toolTip = workDir.path
        let t3 = NSButton(checkboxWithTitle: "3д", target: self, action: #selector(toggle3d(_:)))
        t3.state = .on
        t3.font = small
        head.addView(CubeView(frame: .zero), in: .leading)
        head.addView(label("TERSEY · lite", FG, monob), in: .leading)
        head.addView(label(weightKB(), OKC, small), in: .leading)
        head.addView(modeSeg, in: .center)
        head.addView(effortSeg, in: .center)
        head.addView(dirBtn, in: .center)
        head.addView(newBtn, in: .center)
        head.addView(t3, in: .center)
        head.addView(status, in: .trailing)
        root.addArrangedSubview(head); full(head)

        let sep = NSBox()
        sep.boxType = .custom; sep.fillColor = LINE; sep.borderWidth = 0
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(sep); full(sep)

        // заголовки колонок: имя + версия слева, выбор модели справа
        labC = label("CLAUDE", CLA, small)
        labX = label("CODEX", COD, small)
        modelPopC = modelPop(["авто", "fable", "opus", "sonnet", "haiku"])
        modelPopX = modelPop(["авто", "sol", "luna", "terra", "pro"])
        modelPopC.toolTip = "модель Claude (авто = дефолт подписки)"
        modelPopX.toolTip = "модель Codex (авто = из ~/.codex/config.toml)"
        let headC = NSStackView(views: [labC, modelPopC])
        let headX = NSStackView(views: [labX, modelPopX])
        for h in [headC, headX] {
            h.orientation = .horizontal
            h.spacing = 6
        }
        labC.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labX.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heads = NSStackView(views: [headC, headX])
        heads.orientation = .horizontal
        heads.distribution = .fillEqually
        heads.spacing = 10
        root.addArrangedSubview(heads); full(heads)

        // две панели вывода (транскрипт диалога)
        let (svC, tvC) = pane(); let (svX, tvX) = pane()
        outC = tvC; outX = tvX
        let body = NSStackView(views: [svC, svX])
        body.orientation = .horizontal
        body.distribution = .fillEqually
        body.spacing = 10
        root.addArrangedSubview(body); full(body)
        body.setContentHuggingPriority(.defaultLow, for: .vertical)

        // мета-строки: модель · токены · права · effort
        metaC = label(" ", MUT, small)
        metaX = label(" ", MUT, small)
        let metas = NSStackView(views: [metaC, metaX])
        metas.orientation = .horizontal
        metas.distribution = .fillEqually
        root.addArrangedSubview(metas); full(metas)

        // строка ввода
        entry = NSTextField()
        entry.font = mono
        entry.placeholderString = "спроси обоих…"
        entry.target = self
        entry.action = #selector(send)
        btn = NSButton(title: "Отправить", target: self, action: #selector(send))
        btn.bezelStyle = .rounded
        let bar = NSStackView(views: [label("❯", MUT, monob), entry, btn])
        bar.orientation = .horizontal
        bar.spacing = 8
        root.addArrangedSubview(bar); full(bar)
        entry.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // предзаполнено — просто нажми Отправить, чтобы проверить
        entry.stringValue = "Одним словом: столица Франции?"

        // ── сцена фейкового 3D: панели — разворот книги, всё следит за мышкой ──
        window.contentView!.wantsLayer = true
        tiltViews = [(root, 0), (svC, 0.11), (svX, -0.11)]
        for (v, _) in tiltViews {
            v.wantsLayer = true
            v.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                   object: v, queue: .main) { [weak self] _ in
                self?.applyTilts()
            }
        }
        window.acceptsMouseMovedEvents = true
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] ev in
            guard let s = self, let cv = s.window.contentView else { return ev }
            let p = cv.convert(ev.locationInWindow, from: nil)
            s.mouseDX = max(-0.5, min(0.5, p.x / max(cv.bounds.width, 1) - 0.5))
            s.mouseDY = max(-0.5, min(0.5, p.y / max(cv.bounds.height, 1) - 0.5))
            s.applyTilts()
            return ev
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(entry)
        window.layoutIfNeeded()
        DispatchQueue.main.async { self.applyTilts() }

        // версии CLI — подтягиваем асинхронно, не блокируя окно
        DispatchQueue.global().async {
            let v = runCLI([claudeBin, "--version"], timeout: 20).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").first ?? ""
            DispatchQueue.main.async { if !v.isEmpty { self.labC.stringValue = "CLAUDE  \(v)" } }
        }
        DispatchQueue.global().async {
            let v = runCLI([codexBin, "--version"], timeout: 20).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").last ?? ""
            DispatchQueue.main.async { if !v.isEmpty { self.labX.stringValue = "CODEX  \(v)" } }
        }

        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.send() }
        }
    }

    @objc func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = workDir
        panel.prompt = "Работать здесь"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            self.workDir = url
            self.dirBtn.title = "📁 \(url.lastPathComponent)"
            self.dirBtn.toolTip = url.path
            self.reset() // сессии привязаны к папке — начинаем заново
        }
    }

    @objc func reset() {
        sessC = nil; sessX = nil
        outC.string = ""; outX.string = ""
        metaC.stringValue = " "; metaX.stringValue = " "
        status.stringValue = "новый диалог"; status.textColor = MUT
    }

    @objc func send() {
        let prompt = entry.stringValue.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty, pending == 0 else { return }
        pending = 2
        btn.isEnabled = false
        entry.stringValue = ""
        status.stringValue = "думают…"; status.textColor = CLA
        append(outC, "❯ \(prompt)\n", MUT)
        append(outX, "❯ \(prompt)\n", MUT)
        metaEndC = ""; okC = true; gotTextC = false
        tokensX = ""; gotTextX = false

        let work = isWork, eff = effort
        let mC = modelC, mX = modelX
        let permC = work ? "bypass" : "plan"
        let resumeC = sessC, resumeX = sessX
        let dir = workDir

        // ── CLAUDE: stream-json, текст притекает дельтами ────────────────
        DispatchQueue.global().async {
            var argv = [claudeBin, "-p", prompt, "--output-format", "stream-json",
                        "--include-partial-messages", "--verbose", "--effort", eff]
            if !mC.isEmpty { argv += ["--model", mC] }
            if let s = resumeC { argv += ["--resume", s] }
            argv += work ? ["--dangerously-skip-permissions"] : ["--permission-mode", "plan"]
            let r = streamCLI(argv, cwd: dir, timeout: 600) { line in
                guard let d = line.data(using: .utf8),
                      let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                else { return }
                DispatchQueue.main.async { self.claudeEvent(j) }
            }
            DispatchQueue.main.async {
                if !self.gotTextC {
                    let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.append(self.outC, msg.isEmpty ? "(пусто)" : msg, ERRC)
                }
                let meta = self.metaEndC.isEmpty ? "\(permC) · effort \(eff)"
                    : "\(self.metaEndC) · \(permC) · effort \(eff)"
                self.finish(self.outC, self.metaC, meta, self.okC && r.ok)
            }
        }

        // ── CODEX: --json, элементы притекают по мере готовности ─────────
        DispatchQueue.global().async {
            var argv = [codexBin, "exec"]
            if let s = resumeX { argv += ["resume", s] }
            argv += ["--skip-git-repo-check", "--json", "-c", "model_reasoning_effort=\"\(eff)\""]
            // у сабкоманды resume нет флагов --sandbox/-m, поэтому всюду через -c
            if !mX.isEmpty { argv += ["-c", "model=\"\(mX)\""] }
            argv += work ? ["--dangerously-bypass-approvals-and-sandbox"]
                : ["-c", "sandbox_mode=\"read-only\""]
            argv.append(prompt)
            let r = streamCLI(argv, cwd: dir, timeout: 600) { line in
                guard let d = line.data(using: .utf8),
                      let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                else { return }
                DispatchQueue.main.async { self.codexEvent(j) }
            }
            DispatchQueue.main.async {
                if !self.gotTextX {
                    let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.append(self.outX, msg.isEmpty ? "(пусто)" : msg, ERRC)
                }
                var meta = codexBanner(r.err)
                if !self.tokensX.isEmpty { meta += (meta.isEmpty ? "" : " · ") + "\(self.tokensX) ток" }
                self.finish(self.outX, self.metaX, meta, r.ok)
            }
        }
    }

    // события claude stream-json (main thread)
    func claudeEvent(_ j: [String: Any]) {
        switch j["type"] as? String {
        case "system":
            if (j["subtype"] as? String) == "init", let sid = j["session_id"] as? String { sessC = sid }
        case "stream_event":
            guard let ev = j["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_delta",
               let del = ev["delta"] as? [String: Any],
               del["type"] as? String == "text_delta",
               let t = del["text"] as? String {
                gotTextC = true
                append(outC, t, FG)
            } else if ev["type"] as? String == "content_block_start",
                      let cb = ev["content_block"] as? [String: Any],
                      cb["type"] as? String == "tool_use",
                      let name = cb["name"] as? String {
                gotTextC = true
                append(outC, "⚙ \(name)\n", MUT)
            }
        case "result":
            if let sid = j["session_id"] as? String { sessC = sid }
            okC = !(j["is_error"] as? Bool ?? false)
            var bits: [String] = []
            if let mu = j["modelUsage"] as? [String: Any], let m = mu.keys.sorted().first {
                bits.append(m.replacingOccurrences(of: "claude-", with: ""))
            }
            if let u = j["usage"] as? [String: Any] {
                let inp = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                    + (u["cache_creation_input_tokens"] as? Int ?? 0)
                bits.append("\(inp)→\(u["output_tokens"] as? Int ?? 0) ток")
            }
            metaEndC = bits.joined(separator: " · ")
        default: break
        }
    }

    // события codex --json (main thread)
    func codexEvent(_ j: [String: Any]) {
        switch j["type"] as? String {
        case "thread.started":
            if let tid = j["thread_id"] as? String { sessX = tid }
        case "item.started":
            if let item = j["item"] as? [String: Any],
               item["type"] as? String == "command_execution",
               let cmd = item["command"] as? String {
                gotTextX = true
                append(outX, "⚙ $ \(cmd)\n", MUT)
            }
        case "item.completed":
            guard let item = j["item"] as? [String: Any] else { return }
            if item["type"] as? String == "agent_message", let t = item["text"] as? String {
                gotTextX = true
                append(outX, t + "\n", FG)
            }
        case "turn.completed":
            if let u = j["usage"] as? [String: Any] {
                let inp = u["input_tokens"] as? Int ?? 0
                tokensX = "\(inp)→\(u["output_tokens"] as? Int ?? 0)"
            }
        default: break
        }
    }

    func finish(_ pane: NSTextView, _ meta: NSTextField, _ metaText: String, _ ok: Bool) {
        append(pane, "\n", ok ? FG : ERRC)
        meta.stringValue = metaText.isEmpty ? " " : metaText
        pending -= 1
        if pending <= 0 {
            btn.isEnabled = true
            status.stringValue = "готов"; status.textColor = OKC
            window.makeFirstResponder(entry)
        }
    }

    // перспектива через layer.transform: геометрия окна не меняется,
    // GPU композитит бесплатно — вся «3D-сцена» стоит ноль CPU
    func applyTilts() {
        for (v, base) in tiltViews {
            guard let l = v.layer else { continue }
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let f = v.frame
            l.position = CGPoint(x: f.midX, y: f.midY)
            guard tiltOn else { l.transform = CATransform3DIdentity; l.shadowOpacity = 0; continue }
            var t = CATransform3DIdentity
            t.m34 = -1.0 / 750 // фокусное расстояние фейковой камеры
            t = CATransform3DRotate(t, base + mouseDX * 0.10, 0, 1, 0)
            t = CATransform3DRotate(t, mouseDY * 0.08, 1, 0, 0)
            l.transform = t
            if base != 0 { // тени глубины — только у наклонённых панелей
                l.shadowColor = NSColor.black.cgColor
                l.shadowOpacity = 0.16
                l.shadowRadius = 12
                l.shadowOffset = CGSize(width: base > 0 ? 5 : -5, height: -6)
            }
        }
    }

    @objc func toggle3d(_ sender: NSButton) {
        tiltOn = sender.state == .on
        applyTilts()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
