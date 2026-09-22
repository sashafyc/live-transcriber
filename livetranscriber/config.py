"""Конфиг приложения: ключи и настройки в Application Support, не в репозитории."""

from __future__ import annotations

import json
import os
import re
import stat

APP_SUPPORT = os.path.expanduser("~/Library/Application Support/Live Transcriber")
CONFIG_PATH = os.path.join(APP_SUPPORT, "config.json")
RECORDS_DIR = os.path.join(APP_SUPPORT, "records")
LOG_DIR = os.path.join(APP_SUPPORT, "logs")

RETENTION_DAYS = 30
AUDIO_RETENTION_DAYS = 7

DEFAULT_PROMPT = (
    "Итог созвона. Формат:\n"
    "1. Ключевые мысли и идеи — по спикерам\n"
    "2. Важные детали, факты, цифры — ничего не упускать\n"
    "3. Договорённости и планы — реестр: кто, что, когда\n"
    "4. Личное / эмоциональное — эмоции спикеров, на что обратить внимание\n"
    "Не определяй рабочий или не рабочий созвон. Просто дай итог."
)

DEFAULTS = {
    "assemblyai_key": "",
    "deepseek_key": "",
    "telegram_token": "",
    "telegram_chat": "",      # ссылка на чат или chat_id, thread разбирается из ссылки
    "language": "ru",
    "prompt": DEFAULT_PROMPT,
    "retention_days": RETENTION_DAYS,
    "audio_retention_days": AUDIO_RETENTION_DAYS,
    "send_to_telegram": True,
    "show_start_window_on_launch": True,
}

# Ключи, которые нельзя печатать в логах целиком
SECRET_FIELDS = ("assemblyai_key", "deepseek_key", "telegram_token")


def mask(value: str) -> str:
    """Безопасное представление ключа для логов: 8 первых символов."""
    if not value:
        return "<пусто>"
    return value[:8] + "…"


def load() -> dict:
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except FileNotFoundError:
        pass
    except Exception:
        # Битый конфиг не должен мешать запуску: работаем на дефолтах
        pass
    return cfg


def save(cfg: dict) -> None:
    os.makedirs(APP_SUPPORT, exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG_PATH)
    # Ключи читает только владелец
    os.chmod(CONFIG_PATH, stat.S_IRUSR | stat.S_IWUSR)


def is_configured(cfg: dict) -> bool:
    """Минимум для записи: ключ AssemblyAI. Остальное опционально."""
    return bool(cfg.get("assemblyai_key"))


def missing_keys(cfg: dict) -> list[str]:
    out = []
    if not cfg.get("assemblyai_key"):
        out.append("ключ AssemblyAI (без него не будет транскрибации)")
    if not cfg.get("deepseek_key"):
        out.append("ключ DeepSeek (без него не будет саммари)")
    if cfg.get("send_to_telegram"):
        if not cfg.get("telegram_token"):
            out.append("токен Telegram-бота (без него саммари не уйдёт в чат)")
        if not cfg.get("telegram_chat"):
            out.append("чат Telegram (без него саммари не уйдёт в чат)")
    return out


def parse_chat(value: str) -> tuple[str, int | None]:
    """Из ссылки или сырого значения достаём chat_id и thread_id.

    Понимает:
      https://t.me/c/1234567890/42  → ("-1001234567890", 42)
      https://t.me/c/1234567890       → ("-1001234567890", None)
      https://t.me/channelname        → ("@channelname", None)
      -1001234567890/42             → ("-1001234567890", 42)
      -1001234567890                  → ("-1001234567890", None)
      @channelname                    → ("@channelname", None)
    """
    value = (value or "").strip()
    if not value:
        return "", None

    m = re.search(r"t\.me/c/(\d+)(?:/(\d+))?", value)
    if m:
        chat = "-100" + m.group(1)
        thread = int(m.group(2)) if m.group(2) else None
        return chat, thread

    m = re.search(r"t\.me/(?:s/)?([A-Za-z][\w_]{3,})", value)
    if m:
        return "@" + m.group(1), None

    m = re.fullmatch(r"(-?\d+)(?:/(\d+))?", value)
    if m:
        thread = int(m.group(2)) if m.group(2) else None
        return m.group(1), thread

    if value.startswith("@"):
        return value, None
    return value, None
