#!/bin/zsh
# Сборка «Live Transcriber.app». С флагом --install кладёт в /Applications и запускает.
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
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Подпись: ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LiveTranscriber || true
    rm -rf "/Applications/Live Transcriber.app"
    ditto "$APP" "/Applications/Live Transcriber.app"
    open "/Applications/Live Transcriber.app"
fi
