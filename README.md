# TERSEY · models

Лёгкий нативный macOS-терминал для Claude Code и Codex с переключателями моделей —
включая самые лёгкие: Claude **haiku** и компактные Codex-модели.
Один Swift-файл + вращающийся куб на arm64-ассемблере. Бинарник ~222 КБ.

- Claude: авто / fable / opus / sonnet / **haiku**
- Codex: авто / sol / luna / terra / pro

## Сборка

```sh
./build.sh
```

Поставит `~/Applications/TerseyModels.app` (подпись ad-hoc; свой сертификат: `IDENTITY=... ./build.sh`).

Ключей внутри нет: перед запуском дочерних CLI вычищаются `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY` и родственные переменные — работает только подписочный логин
установленных `claude` / `codex`.

Требования: macOS 13+, Xcode CLT, установленные CLI `claude` и/или `codex`.
