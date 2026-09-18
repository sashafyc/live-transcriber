#!/usr/bin/env python3
"""Сборка приложения: иконка, py2app, проверка результата.

Отдельный скрипт, потому что после py2app нужно поправить иконку: в бандл она
попадает ссылкой на файл проекта, а системе такие ссылки читать нельзя, если
проект лежит в защищённой папке вроде «Документы». Тогда вместо иконки
показывается пустой квадрат.
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "dist", "Live Transcriber.app")
PYTHON = os.path.join(ROOT, ".venv", "bin", "python3")


def run(cmd: list[str]) -> None:
    print("→", " ".join(cmd))
    result = subprocess.run(cmd, cwd=ROOT)
    if result.returncode != 0:
        sys.exit(f"не удалось выполнить: {' '.join(cmd)}")


def main() -> None:
    run([PYTHON, os.path.join("scripts", "make_icon.py")])

    for folder in ("build", "dist"):
        shutil.rmtree(os.path.join(ROOT, folder), ignore_errors=True)
    run([PYTHON, "setup_app.py", "py2app"])

    icon = os.path.join(APP, "Contents", "Resources", "icon.icns")
    if os.path.islink(icon):
        target = os.path.realpath(icon)
        os.unlink(icon)
        shutil.copy2(target, icon)
        print("иконка скопирована внутрь бандла вместо ссылки")

    # Кеш иконок помнит старую версию бандла
    subprocess.run(["touch", APP])

    size = subprocess.run(["du", "-sh", APP], capture_output=True)
    print("\nготово:", APP)
    print("размер:", size.stdout.decode().split()[0])
    print("проверить запуском:  open", f'"{APP}"')


if __name__ == "__main__":
    main()
