"""Отправка саммари в Telegram через бота."""

from __future__ import annotations

import html
import logging
import re

import requests

from .config import parse_chat

API = "https://api.telegram.org/bot{token}/{method}"
MAX_MESSAGE = 4000  # лимит 4096, оставляем запас на разметку


class TelegramError(RuntimeError):
    pass


def check(token: str, chat: str) -> tuple[bool, str]:
    if not token:
        return False, "токен не задан"
    try:
        r = requests.get(API.format(token=token, method="getMe"), timeout=15)
    except requests.RequestException as e:
        return False, f"нет связи: {e}"
    if r.status_code == 401:
        return False, "токен не принят (401)"
    if r.status_code >= 400:
        return False, f"ошибка {r.status_code}"
    name = r.json().get("result", {}).get("username", "?")
    if not chat:
        return True, f"бот @{name}, но чат не задан"
    chat_id, thread = parse_chat(chat)
    return True, f"бот @{name}, чат {chat_id}" + (f", тема {thread}" if thread else "")


def to_html(markdown: str) -> str:
    """Markdown → разметка Telegram.

    Telegram не показывает ни заголовки решётками, ни таблицы: они приходят
    к читателю как есть и мешают. Заголовки делаем жирными строками, таблицы
    разворачиваем в строки, маркеры списка приводим к точке.
    """
    text = html.escape(markdown or "", quote=False)
    lines_in = text.split("\n")
    lines_out: list[str] = []
    table: list[list[str]] = []

    def flush_table() -> None:
        if not table:
            return
        rows = [row for row in table
                if not all(re.fullmatch(r":?-{2,}:?", cell or "") for cell in row)]
        header = rows[0] if len(rows) > 1 else []
        for row in rows[1:] if header else rows:
            pairs = []
            for index, cell in enumerate(row):
                if not cell:
                    continue
                name = header[index] if index < len(header) else ""
                pairs.append(f"{name}: {cell}" if name and name.lower() not in ("кто", "что")
                             else cell)
            if pairs:
                lines_out.append("• " + " — ".join(pairs))
        table.clear()

    for line in lines_in:
        stripped = line.strip()
        if stripped.startswith("|") and stripped.endswith("|") and stripped.count("|") >= 2:
            table.append([cell.strip() for cell in stripped.strip("|").split("|")])
            continue
        flush_table()

        heading = re.match(r"^\s*#{1,6}\s*(.+?)\s*$", line)
        if heading:
            title = heading.group(1).rstrip(":")
            # Номер раздела оставляем, он помогает ориентироваться
            lines_out.append(f"<b>{title}</b>")
            continue

        bullet = re.match(r"^(\s*)[-*+]\s+(.+)$", line)
        if bullet:
            indent = "   " if len(bullet.group(1)) >= 2 else ""
            lines_out.append(f"{indent}• {bullet.group(2)}")
            continue

        lines_out.append(line)
    flush_table()

    result = "\n".join(lines_out)
    result = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", result, flags=re.S)
    result = re.sub(r"__(.+?)__", r"<b>\1</b>", result, flags=re.S)
    result = re.sub(r"`([^`\n]+?)`", r"<code>\1</code>", result)
    result = re.sub(r"(?<![\w*])\*([^*\n]+?)\*(?![\w*])", r"<i>\1</i>", result)
    # Больше двух пустых строк подряд Telegram всё равно схлопывает
    result = re.sub(r"\n{3,}", "\n\n", result)
    return result.strip()


def _split(text: str) -> list[str]:
    """Режем по абзацам, чтобы не рвать предложения."""
    if len(text) <= MAX_MESSAGE:
        return [text]
    parts, current = [], ""
    for block in text.split("\n\n"):
        if len(current) + len(block) + 2 > MAX_MESSAGE and current:
            parts.append(current.rstrip())
            current = ""
        while len(block) > MAX_MESSAGE:
            parts.append(block[:MAX_MESSAGE])
            block = block[MAX_MESSAGE:]
        current += block + "\n\n"
    if current.strip():
        parts.append(current.rstrip())
    return parts


def send(text: str, token: str, chat: str) -> int:
    """Отправляет саммари, возвращает число доставленных сообщений."""
    if not token or not chat:
        raise TelegramError("не заданы токен бота или чат")
    chat_id, thread = parse_chat(chat)
    if not chat_id:
        raise TelegramError(f"не понял адрес чата: {chat!r}")

    sent = 0
    for part in _split(to_html(text)):
        payload = {"chat_id": chat_id, "text": part,
                   "disable_web_page_preview": True}
        if thread:
            payload["message_thread_id"] = thread
        # HTML надёжнее markdown: ломается только на незакрытых тегах,
        # а если всё же сломался — шлём тем же текстом без разметки.
        r = requests.post(API.format(token=token, method="sendMessage"),
                          json={**payload, "parse_mode": "HTML"}, timeout=60)
        if r.status_code >= 400:
            logging.warning("Telegram отверг разметку (%s), шлю простым текстом: %s",
                            r.status_code, r.text[:200])
            plain = re.sub(r"<[^>]+>", "", part)
            r = requests.post(API.format(token=token, method="sendMessage"),
                              json={**payload, "text": html.unescape(plain)}, timeout=60)
        if r.status_code >= 400:
            raise TelegramError(f"{r.status_code}: {r.text[:200]}")
        sent += 1
    logging.info("Саммари отправлено в Telegram: %d сообщений", sent)
    return sent
