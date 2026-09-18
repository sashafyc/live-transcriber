#!/usr/bin/env python3
"""Выпуск новой версии: номер, история изменений, тег и релиз на GitHub.

    python3 scripts/release.py patch "Починил пропажу звука после сна"
    python3 scripts/release.py minor "Добавил поиск по истории"

Скрипт сам поднимает номер версии, дописывает строку в CHANGELOG.md, обновляет
значок версии в README, делает коммит, тег и релиз. Так на GitHub всегда видно,
какая версия сейчас и что в ней исправлено.
"""

import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INIT = os.path.join(ROOT, "livetranscriber", "__init__.py")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
README = os.path.join(ROOT, "README.md")

SECTIONS = {"fixed": "Исправлено", "added": "Добавлено", "changed": "Изменено"}


def read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def current_version() -> str:
    return re.search(r'__version__ = "([^"]+)"', read(INIT)).group(1)


def bump(version: str, part: str) -> str:
    major, minor, patch = (int(x) for x in version.split("."))
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True)
    output = result.stdout.decode("utf-8", errors="replace").strip()
    if check and result.returncode != 0:
        sys.exit(f"git {' '.join(args)}: {result.stderr.decode('utf-8', errors='replace')}")
    return output


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    part = sys.argv[1]
    if part not in ("major", "minor", "patch"):
        sys.exit("первый аргумент: major, minor или patch")
    notes = sys.argv[2]
    section = SECTIONS.get(sys.argv[3] if len(sys.argv) > 3 else "fixed", "Исправлено")

    if git("status", "--porcelain"):
        sys.exit("есть незакоммиченные изменения — сначала разберитесь с ними")

    old = current_version()
    new = bump(old, part)
    today = datetime.date.today().isoformat()
    print(f"версия {old} → {new}")

    write(INIT, read(INIT).replace(f'__version__ = "{old}"', f'__version__ = "{new}"'))
    write(README, read(README).replace(f"версия-{old}-blue", f"версия-{new}-blue"))

    changelog = read(CHANGELOG)
    entry = f"## [{new}] — {today}\n\n### {section}\n- {notes}\n\n"
    marker = "## ["
    position = changelog.index(marker)
    write(CHANGELOG, changelog[:position] + entry + changelog[position:])

    git("add", "livetranscriber/__init__.py", "CHANGELOG.md", "README.md")
    git("commit", "-m", f"{new}: {notes}")
    git("tag", "-a", f"v{new}", "-m", f"{new}: {notes}")
    git("push", "origin", "main")
    git("push", "origin", f"v{new}")

    release = subprocess.run(
        ["gh", "release", "create", f"v{new}", "--title", f"v{new}", "--notes",
         f"### {section}\n- {notes}"], cwd=ROOT, capture_output=True)
    if release.returncode == 0:
        print("релиз опубликован:", release.stdout.decode().strip())
    else:
        print("тег запушен, но релиз не создан:",
              release.stderr.decode("utf-8", errors="replace").strip()[:200])
    print(f"готово: v{new}")


if __name__ == "__main__":
    main()
