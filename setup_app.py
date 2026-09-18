"""Сборка .app через py2app. Запускать через scripts/build_app.py."""

import re
from pathlib import Path

from setuptools import setup

ROOT = Path(__file__).parent
VERSION = re.search(r'__version__ = "([^"]+)"',
                    (ROOT / "livetranscriber" / "__init__.py").read_text(encoding="utf-8")).group(1)

setup(
    app=["main.py"],
    name="Live Transcriber",
    version=VERSION,
    options={
        "py2app": {
            "iconfile": "assets/icon.icns",
            "packages": ["rumps", "requests", "certifi", "charset_normalizer",
                         "idna", "urllib3", "livetranscriber"],
            "includes": ["objc", "Foundation", "AppKit"],
            "plist": {
                "CFBundleName": "Live Transcriber",
                "CFBundleDisplayName": "Live Transcriber",
                "CFBundleIdentifier": "pro.ainvest.live-transcriber",
                "CFBundleVersion": VERSION,
                "CFBundleShortVersionString": VERSION,
                # Приложение живёт в строке меню, иконка в Dock не нужна
                "LSUIElement": True,
                "LSMinimumSystemVersion": "13.0",
                "NSMicrophoneUsageDescription":
                    "Live Transcriber записывает микрофон, чтобы расшифровать разговор.",
                "NSHighResolutionCapable": True,
            },
        }
    },
    setup_requires=["py2app"],
)
