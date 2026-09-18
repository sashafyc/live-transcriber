"""Саммари транскрипта через DeepSeek."""

from __future__ import annotations

import logging

import requests

API_URL = "https://api.deepseek.com/chat/completions"
MODEL = "deepseek-chat"

# Часовой разговор — это примерно 40 тысяч символов, влезает целиком.
# Всё что длиннее режем на части, иначе упрёмся в контекст модели.
MAX_DIRECT_CHARS = 120_000
PART_CHARS = 90_000

SYSTEM = (
    "Ты помощник, который делает итоги рабочих и личных разговоров на русском языке. "
    "Пиши по делу, без воды и канцелярита. Ничего не выдумывай: если чего-то в "
    "транскрипте нет, не пиши об этом.\n"
    "Итог читают в Telegram, поэтому оформляй так: подзаголовок раздела — "
    "отдельной строкой жирным через **двойные звёздочки**, пункты — с дефиса. "
    "Не используй таблицы и решётки для заголовков: в Telegram они не работают. "
    "Договорённости оформляй пунктами вида «кто — что — срок»."
)


class SummaryError(RuntimeError):
    pass


def check_key(api_key: str) -> tuple[bool, str]:
    if not api_key:
        return False, "ключ не задан"
    try:
        r = requests.post(API_URL,
                          headers={"Authorization": f"Bearer {api_key}"},
                          json={"model": MODEL,
                                "messages": [{"role": "user", "content": "ответь словом ок"}],
                                "max_tokens": 5},
                          timeout=30)
    except requests.RequestException as e:
        return False, f"нет связи: {e}"
    if r.status_code == 401:
        return False, "ключ не принят (401)"
    if r.status_code == 402:
        return False, "на балансе нет средств (402)"
    if r.status_code >= 400:
        return False, f"ошибка {r.status_code}: {r.text[:120]}"
    return True, "ключ рабочий"


def _ask(api_key: str, prompt: str, text: str, max_tokens: int = 4000) -> str:
    try:
        r = requests.post(
            API_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={
                "model": MODEL,
                "messages": [
                    {"role": "system", "content": SYSTEM},
                    {"role": "user", "content": f"{prompt}\n\nТранскрипт:\n\n{text}"},
                ],
                "temperature": 0.3,
                "max_tokens": max_tokens,
            },
            timeout=300,
        )
    except requests.RequestException as e:
        raise SummaryError(f"нет связи с DeepSeek: {e}") from e
    if r.status_code >= 400:
        raise SummaryError(f"DeepSeek вернул {r.status_code}: {r.text[:200]}")
    try:
        return r.json()["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, ValueError) as e:
        raise SummaryError(f"неожиданный ответ DeepSeek: {r.text[:200]}") from e


def summarize(transcript: str, api_key: str, prompt: str) -> str:
    """Транскрипт → итог. Длинные разговоры сводим по частям."""
    text = (transcript or "").strip()
    if not text:
        raise SummaryError("транскрипт пустой, сводить нечего")
    if not api_key:
        raise SummaryError("не задан ключ DeepSeek")

    if len(text) <= MAX_DIRECT_CHARS:
        logging.info("Саммари: один запрос, %d символов", len(text))
        return _ask(api_key, prompt, text)

    parts = [text[i:i + PART_CHARS] for i in range(0, len(text), PART_CHARS)]
    logging.info("Саммари: длинный разговор, %d символов → %d частей", len(text), len(parts))
    digests = []
    for number, part in enumerate(parts, 1):
        digest = _ask(api_key,
                      f"Это часть {number} из {len(parts)} длинного разговора. "
                      "Выпиши подробно всё важное: мысли, факты, цифры, договорённости. "
                      "Без вступления и выводов.",
                      part, max_tokens=3000)
        digests.append(f"--- Часть {number} ---\n{digest}")
    return _ask(api_key, prompt + "\n\nНиже — конспекты частей разговора по порядку.",
                "\n\n".join(digests))
