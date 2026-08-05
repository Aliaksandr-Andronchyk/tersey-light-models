#!/bin/zsh
# Сборка TerseyModels. Подпись ad-hoc; свой сертификат: IDENTITY="..." ./build.sh
set -e
cd "$(dirname "$0")"
clang -c cube.s -o cube.o
swiftc -O terseylite.swift cube.o -o TerseyModels

APP=${APP:-~/Applications/TerseyModels.app}
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp TerseyModels "$APP/Contents/MacOS/TerseyModels"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "готово: $APP"
