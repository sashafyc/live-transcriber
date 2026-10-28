#!/bin/zsh
# Выпуск версии: номер, история изменений, значок в README, коммит, тег, релиз на GitHub.
#
#   scripts/release.sh patch "Починил пропажу звука после сна"
#   scripts/release.sh minor "Добавил поиск по истории" added
#
# Третий аргумент — раздел истории: fixed (по умолчанию), added, changed.
# К релизу прикладывается собранное приложение, архивом.
set -euo pipefail
cd "$(dirname "$0")/.."

part=${1:?"первый аргумент: major, minor или patch"}
notes=${2:?"второй аргумент: что изменилось, одной фразой"}
case ${3:-fixed} in
    added) section="Добавлено" ;;
    changed) section="Изменено" ;;
    *) section="Исправлено" ;;
esac
[[ -z "$(git status --porcelain)" ]] || { echo "есть незакоммиченные изменения — сначала разберитесь с ними"; exit 1; }

plist=Info.plist
old=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $plist)
IFS=. read -r major minor patch <<< "$old"
case $part in
    major) new="$((major + 1)).0.0" ;;
    minor) new="$major.$((minor + 1)).0" ;;
    patch) new="$major.$minor.$((patch + 1))" ;;
    *) echo "первый аргумент: major, minor или patch"; exit 1 ;;
esac
echo "версия $old → $new"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new" $plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $plist) + 1 ))" $plist
sed -i '' "s/версия-$old-blue/версия-$new-blue/" README.md
entry="## [$new] — $(date +%F)\n\n### $section\n- $notes\n\n"
awk -v entry="$entry" '!done && /^## \[/ { printf "%s", entry; done = 1 } { print }' CHANGELOG.md > CHANGELOG.tmp
mv CHANGELOG.tmp CHANGELOG.md

./build.sh
app="${TMPDIR:-/tmp}/lt-build/Live Transcriber.app"
zip="${TMPDIR:-/tmp}/lt-build/Live-Transcriber-$new.zip"
ditto -c -k --keepParent "$app" "$zip"

git add Info.plist CHANGELOG.md README.md
git commit -m "$new: $notes"
git tag -a "v$new" -m "$new: $notes"
git push origin main "v$new"
gh release create "v$new" "$zip" --title "v$new" --notes "### $section
- $notes"
echo "готово: v$new"
