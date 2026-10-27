#!/bin/zsh
# Сборка «Live Transcriber 2.app». С флагом --install кладёт в /Applications и запускает.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/LiveTranscriber"
# Бандл собираем вне Документов: их синкает iCloud, и File Provider навешивает на .app
# атрибуты сразу после xattr -cr — codesign падает с «detritus not allowed»
APP="${TMPDIR:-/tmp}/lt-build/Live Transcriber 2.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp "$BIN" "$APP/Contents/MacOS/"
cp ../assets/icon.icns "$APP/Contents/Resources/"
xattr -cr "$APP"

# Подпись Apple Development (бесплатный Apple ID в Xcode) не меняется между сборками,
# и разрешения macOS не слетают. Без неё — ad-hoc, и разрешения придётся выдавать заново.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Подпись: ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LiveTranscriber || true
    rm -rf "/Applications/Live Transcriber 2.app"
    ditto "$APP" "/Applications/Live Transcriber 2.app"
    open "/Applications/Live Transcriber 2.app"
fi
