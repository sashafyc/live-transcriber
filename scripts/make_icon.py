#!/usr/bin/env python3
"""Иконка приложения: тёмный кружок с красной точкой записи и звуковой волной.

Важно: .icns должен содержать все размеры. Если оставить только один,
macOS показывает пустой квадрат вместо иконки.
"""

import os
import shutil
import subprocess

from PIL import Image, ImageDraw

SIZES = [16, 32, 64, 128, 256, 512, 1024]
BASE = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def draw(size: int = BASE) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = size / 1024

    # Скруглённый тёмный корпус
    d.rounded_rectangle([40 * k, 40 * k, 984 * k, 984 * k], radius=224 * k,
                        fill=(28, 30, 38, 255))

    # Звуковая волна: столбики разной высоты
    bars = [170, 300, 440, 300, 170]
    bar_w = 56 * k
    gap = 44 * k
    total = len(bars) * bar_w + (len(bars) - 1) * gap
    x = (size - total) / 2
    center_y = size / 2 - 40 * k
    for height in bars:
        h = height * k
        d.rounded_rectangle([x, center_y - h / 2, x + bar_w, center_y + h / 2],
                            radius=bar_w / 2, fill=(236, 238, 245, 255))
        x += bar_w + gap

    # Точка записи
    r = 74 * k
    cx, cy = size / 2, size / 2 + 300 * k
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(228, 62, 62, 255))
    return img


def build() -> str:
    iconset = os.path.join(ROOT, "assets", "icon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset, exist_ok=True)

    master = draw(BASE)
    master.save(os.path.join(ROOT, "assets", "icon.png"))
    for size in SIZES:
        master.resize((size, size), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{size}x{size}.png"))
        if size * 2 <= BASE:
            master.resize((size * 2, size * 2), Image.LANCZOS).save(
                os.path.join(iconset, f"icon_{size}x{size}@2x.png"))

    icns = os.path.join(ROOT, "assets", "icon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    shutil.rmtree(iconset, ignore_errors=True)
    return icns


if __name__ == "__main__":
    print("иконка собрана:", build())
