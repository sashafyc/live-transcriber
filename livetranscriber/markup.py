"""Приведение markdown к тому, что показывают окно приложения и Telegram.

Модель отвечает обычным markdown, но ни Telegram, ни текстовое поле AppKit не
показывают заголовки решётками и таблицы: читатель видит их как есть. Здесь
разметка приводится к общему виду — жирные подзаголовки, точки списка,
таблицы строками, — а уже потом каждый получатель рисует её по-своему.
"""

from __future__ import annotations

import re

BOLD = re.compile(r"\*\*(.+?)\*\*", re.S)
HEADING = re.compile(r"^\s*#{1,6}\s*(.+?)\s*$")
BULLET = re.compile(r"^(\s*)[-*+]\s+(.+)$")
SEPARATOR = re.compile(r":?-{2,}:?")
# Подписи колонок, которые ничего не добавляют к строке
NOISY_HEADERS = {"кто", "что", "когда", "срок", "кому", "статус"}


def _table_rows(table: list[list[str]]) -> list[str]:
    rows = [row for row in table
            if not all(SEPARATOR.fullmatch(cell or "") for cell in row)]
    if not rows:
        return []
    header = rows[0] if len(rows) > 1 else []
    out = []
    for row in (rows[1:] if header else rows):
        parts = []
        for index, cell in enumerate(row):
            if not cell:
                continue
            name = header[index] if index < len(header) else ""
            if name and name.strip().lower() not in NOISY_HEADERS:
                parts.append(f"{name}: {cell}")
            else:
                parts.append(cell)
        if parts:
            out.append("• " + " — ".join(parts))
    return out


def normalize(markdown: str) -> str:
    """Заголовки → жирные строки, таблицы → строки, маркеры списка → точки."""
    lines_out: list[str] = []
    table: list[list[str]] = []

    def flush() -> None:
        if table:
            lines_out.extend(_table_rows(table))
            table.clear()

    for line in (markdown or "").split("\n"):
        stripped = line.strip()
        if stripped.startswith("|") and stripped.endswith("|") and stripped.count("|") >= 2:
            table.append([cell.strip() for cell in stripped.strip("|").split("|")])
            continue
        flush()

        heading = HEADING.match(line)
        if heading:
            title = heading.group(1).rstrip(":")
            # Заголовок мог уже прийти жирным — двойных звёздочек быть не должно
            title = BOLD.sub(r"\1", title)
            lines_out.append(f"**{title}**")
            continue

        bullet = BULLET.match(line)
        if bullet:
            indent = "   " if len(bullet.group(1)) >= 2 else ""
            lines_out.append(f"{indent}• {bullet.group(2)}")
            continue

        lines_out.append(line)
    flush()

    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines_out)).strip()


def spans(text: str) -> tuple[str, list[tuple[int, int]]]:
    """Убирает двойные звёздочки и возвращает границы жирных кусков.

    Нужно окну приложения: там жирный рисуется шрифтом, а не символами.
    """
    plain: list[str] = []
    bold: list[tuple[int, int]] = []
    position = 0
    last = 0
    for match in BOLD.finditer(text):
        plain.append(text[last:match.start()])
        position += match.start() - last
        inner = match.group(1)
        bold.append((position, len(inner)))
        plain.append(inner)
        position += len(inner)
        last = match.end()
    plain.append(text[last:])
    return "".join(plain), bold
