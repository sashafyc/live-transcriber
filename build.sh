#!/bin/zsh
# Сборка «Live Transcriber.app». С флагом --install кладёт в /Applications и запускает,
# с --dmg собирает образ для релиза: приложение и ярлык на Программы.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Всё собранное держим вне Документов: их синкает iCloud. Он выгружает файлы кэша сборки
# из локального хранилища, и компилятор виснет на чтении (28.10.2026), а на .app навешивает
# атрибуты сразу после xattr -cr — codesign падает с «detritus not allowed»
OUT="${TMPDIR:-/tmp}/lt-build"
swift build -c release --arch arm64 --scratch-path "$OUT/spm"
BIN="$(swift build -c release --arch arm64 --scratch-path "$OUT/spm" --show-bin-path)/LiveTranscriber"
APP="$OUT/Live Transcriber.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp "$BIN" "$APP/Contents/MacOS/"
cp assets/icon.icns "$APP/Contents/Resources/"
xattr -cr "$APP"

# Подпись Apple Development (бесплатный Apple ID в Xcode) не меняется между сборками,
# и разрешения macOS не слетают. Без неё — ad-hoc, и разрешения придётся выдавать заново.
# В релиз её не кладём: в подписи видна почта разработчика. Для релиза — свой сертификат
# «Live Transcriber» из Связки ключей (самоподписанный, тоже не меняется), если он есть.
if [[ "${1:-}" == "--dmg" ]]; then
    IDENTITY=$(security find-identity -p codesigning | awk -F'"' '$2 == "Live Transcriber" {print $2; exit}')
else
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Подпись: ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LiveTranscriber || true
    rm -rf "/Applications/Live Transcriber.app"
    ditto "$APP" "/Applications/Live Transcriber.app"
    open "/Applications/Live Transcriber.app"
fi

if [[ "${1:-}" == "--dmg" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
    STAGE="$OUT/dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/Live Transcriber.app"
    ln -s /Applications "$STAGE/Программы"
    DMG="$OUT/Live-Transcriber-$VERSION.dmg"
    hdiutil create -volname "Live Transcriber" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    echo "Образ: $DMG"
fi
