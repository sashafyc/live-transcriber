"""Отправка саммари в Telegram через бота."""

from __future__ import annotations

import html
import logging
import re

import requests

from . import markup
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
    """Markdown → разметка Telegram."""
    text = html.escape(markup.normalize(markdown), quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text, flags=re.S)
    text = re.sub(r"__(.+?)__", r"<b>\1</b>", text, flags=re.S)
    text = re.sub(r"`([^`\n]+?)`", r"<code>\1</code>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+?)\*(?![\w*])", r"<i>\1</i>", text)
    return text.strip()


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
