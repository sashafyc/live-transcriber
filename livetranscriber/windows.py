"""Окна приложения. Все вызовы — только из главного потока."""

from __future__ import annotations

import logging
import os
import subprocess

from AppKit import (
    NSAlert, NSAlertFirstButtonReturn, NSAlertSecondButtonReturn,
    NSAlertThirdButtonReturn, NSApp, NSApplicationActivationPolicyAccessory,
    NSApplicationActivationPolicyRegular, NSBezelBorder, NSFloatingWindowLevel,
    NSFont, NSMakeRect, NSPasteboard, NSPasteboardTypeString, NSPopUpButton,
    NSScrollView, NSSecureTextField, NSSwitchButton, NSTextField, NSTextView,
    NSButton, NSView,
)
from Foundation import NSObject, NSSelectorFromString

from . import config

BUTTON_FIRST = NSAlertFirstButtonReturn
BUTTON_SECOND = NSAlertSecondButtonReturn
BUTTON_THIRD = NSAlertThirdButtonReturn


# ── мелкие помощники ────────────────────────────────────
def copy_to_clipboard(text: str) -> None:
    board = NSPasteboard.generalPasteboard()
    board.clearContents()
    board.setString_forType_(text, NSPasteboardTypeString)


def reveal_in_finder(path: str) -> None:
    if os.path.exists(path):
        subprocess.Popen(["open", "-R", path])


def open_path(path: str) -> None:
    if os.path.exists(path):
        subprocess.Popen(["open", path])


def label(text: str, x: float, y: float, width: float, size: float = 12,
          bold: bool = False) -> NSTextField:
    field = NSTextField.alloc().initWithFrame_(NSMakeRect(x, y, width, 18))
    field.setStringValue_(text)
    field.setBezeled_(False)
    field.setDrawsBackground_(False)
    field.setEditable_(False)
    field.setSelectable_(True)
    field.setFont_(NSFont.boldSystemFontOfSize_(size) if bold
                   else NSFont.systemFontOfSize_(size))
    return field


def text_area(text: str, x: float, y: float, width: float, height: float,
              monospace: bool = False) -> NSScrollView:
    scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(x, y, width, height))
    scroll.setHasVerticalScroller_(True)
    scroll.setBorderType_(NSBezelBorder)
    view = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, width, height))
    view.setEditable_(False)
    view.setRichText_(False)
    view.setFont_(NSFont.monospacedSystemFontOfSize_weight_(11, 0) if monospace
                  else NSFont.systemFontOfSize_(12))
    view.setString_(text or "")
    scroll.setDocumentView_(view)
    return scroll


def _alert(title: str, info: str = "", buttons: tuple[str, ...] = ("OK",),
           accessory=None, floating: bool = True) -> int:
    """Модальное окно поверх остальных приложений."""
    NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    NSApp.activateIgnoringOtherApps_(True)
    alert = NSAlert.alloc().init()
    alert.setMessageText_(title)
    if info:
        alert.setInformativeText_(info)
    for caption in buttons:
        alert.addButtonWithTitle_(caption)
    if accessory is not None:
        alert.setAccessoryView_(accessory)
    if floating:
        window = alert.window()
        window.setLevel_(NSFloatingWindowLevel)
        window.setHidesOnDeactivate_(False)
    try:
        return alert.runModal()
    finally:
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)


def info(title: str, message: str = "") -> None:
    _alert(title, message, ("Закрыть",))


def confirm(title: str, message: str, ok: str = "Да", cancel: str = "Отмена") -> bool:
    return _alert(title, message, (ok, cancel)) == BUTTON_FIRST


# ── окно старта ─────────────────────────────────────────
def start_dialog(mic_name: str, output_name: str, blackhole_ok: bool,
                 default_prompt: str) -> dict | None:
    """Название записи и промт. Возвращает None, если отменили."""
    view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 440, 250))

    view.addSubview_(label("Название:", 0, 224, 90))
    name_field = NSTextField.alloc().initWithFrame_(NSMakeRect(95, 220, 345, 24))
    name_field.setStringValue_("Созвон")
    view.addSubview_(name_field)

    view.addSubview_(label("Что сделать с записью:", 0, 192, 300))
    prompt_view = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, 440, 140))
    prompt_view.setFont_(NSFont.systemFontOfSize_(11))
    prompt_view.setString_(default_prompt)
    prompt_scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(0, 46, 440, 140))
    prompt_scroll.setHasVerticalScroller_(True)
    prompt_scroll.setBorderType_(NSBezelBorder)
    prompt_scroll.setDocumentView_(prompt_view)
    view.addSubview_(prompt_scroll)

    sound = "звук собеседника пишется" if blackhole_ok else "⚠️ звук собеседника НЕ пишется"
    view.addSubview_(label(f"Микрофон: {mic_name}", 0, 24, 440, size=11))
    view.addSubview_(label(f"Выход: {output_name} · {sound}", 0, 6, 440, size=11))

    choice = _alert("Новая запись", "", ("Начать запись", "Проверить звук", "Отмена"), view)
    if choice == BUTTON_SECOND:
        return {"action": "check"}
    if choice != BUTTON_FIRST:
        return None
    return {
        "action": "start",
        "title": name_field.stringValue().strip() or "Созвон",
        "prompt": prompt_view.string().strip() or default_prompt,
    }


# ── окно саммари ────────────────────────────────────────
def summary_window(title: str, summary: str, record_path: str,
                   telegram_note: str = "") -> str | None:
    """Показывает итог. Возвращает действие: copy / telegram / open / None."""
    view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 560, 400))
    view.addSubview_(text_area(summary, 0, 24, 560, 376))
    if telegram_note:
        view.addSubview_(label(telegram_note, 0, 2, 560, size=11))

    choice = _alert(f"Итог — {title}", "",
                    ("Скопировать", "Отправить в Telegram", "Закрыть"), view)
    if choice == BUTTON_FIRST:
        copy_to_clipboard(summary)
        return "copy"
    if choice == BUTTON_SECOND:
        return "telegram"
    return None


# ── история ─────────────────────────────────────────────
class _Handler(NSObject):
    """Мост между контролами AppKit и обычными python-функциями.

    PyObjC разрешает в таком классе только методы вида name_(self, sender),
    поэтому вся логика живёт в колбэках, а не здесь.
    """

    def onSelect_(self, sender):
        callback = getattr(self, "select_callback", None)
        if callback:
            callback(sender.indexOfSelectedItem())

    def onToggle_(self, sender):
        callback = getattr(self, "toggle_callback", None)
        if callback:
            callback(bool(sender.state()))


def history_window(records: list, retention_days: int) -> dict | None:
    """Список записей за срок хранения. Возвращает действие с выбранной записью."""
    if not records:
        info("История пуста", f"Записи хранятся {retention_days} дней. "
                              "Пока ни одной нет.")
        return None

    view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 620, 440))

    popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
        NSMakeRect(0, 412, 620, 26), False)
    for record in records:
        popup.addItemWithTitle_(record.label())

    text_view = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, 620, 370))
    text_view.setEditable_(False)
    text_view.setRichText_(False)
    text_view.setFont_(NSFont.systemFontOfSize_(12))
    scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(0, 34, 620, 370))
    scroll.setHasVerticalScroller_(True)
    scroll.setBorderType_(NSBezelBorder)
    scroll.setDocumentView_(text_view)

    state = {"index": 0, "mode": "summary"}

    def render() -> None:
        record = records[max(0, min(state["index"], len(records) - 1))]
        text = record.summary() if state["mode"] == "summary" else record.transcript()
        if not text:
            text = ("Итог не сохранился" if state["mode"] == "summary"
                    else "Транскрипт пустой")
        text_view.setString_(text)
        text_view.scrollRangeToVisible_((0, 0))

    def on_select(index: int) -> None:
        state["index"] = index
        render()

    def on_toggle(is_transcript: bool) -> None:
        state["mode"] = "transcript" if is_transcript else "summary"
        render()

    handler = _Handler.alloc().init()
    handler.select_callback = on_select
    handler.toggle_callback = on_toggle
    popup.setTarget_(handler)
    popup.setAction_(NSSelectorFromString("onSelect:"))

    toggle = NSButton.alloc().initWithFrame_(NSMakeRect(0, 6, 300, 20))
    toggle.setButtonType_(NSSwitchButton)
    toggle.setTitle_("Показать транскрипт вместо итога")
    toggle.setTarget_(handler)
    toggle.setAction_(NSSelectorFromString("onToggle:"))

    view.addSubview_(popup)
    view.addSubview_(scroll)
    view.addSubview_(toggle)
    render()

    choice = _alert(f"История за {retention_days} дней", "",
                    ("Скопировать", "Показать файлы", "Закрыть"), view)
    index = popup.indexOfSelectedItem()
    record = records[max(0, min(index, len(records) - 1))]
    if choice == BUTTON_FIRST:
        copy_to_clipboard(text_view.string())
        return {"action": "copy", "record": record}
    if choice == BUTTON_SECOND:
        reveal_in_finder(record.path)
        return {"action": "reveal", "record": record}
    return None


# ── настройки ───────────────────────────────────────────
def settings_window(cfg: dict, on_check) -> dict | None:
    """Ключи и адрес чата. on_check(значения) → строка отчёта."""
    view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 520, 290))

    fields: dict[str, NSTextField] = {}
    rows = [
        ("assemblyai_key", "Ключ AssemblyAI:", True, "нужен для транскрибации"),
        ("deepseek_key", "Ключ DeepSeek:", True, "нужен для саммари"),
        ("telegram_token", "Токен Telegram-бота:", True, "нужен для отправки в чат"),
        ("telegram_chat", "Чат Telegram:", False, "ссылка вида https://t.me/c/123.../456"),
    ]
    y = 244
    for key, caption, secret, hint in rows:
        view.addSubview_(label(caption, 0, y, 170))
        cls = NSSecureTextField if secret else NSTextField
        field = cls.alloc().initWithFrame_(NSMakeRect(175, y - 4, 345, 24))
        field.setStringValue_(cfg.get(key, "") or "")
        view.addSubview_(field)
        fields[key] = field
        view.addSubview_(label(hint, 175, y - 24, 345, size=10))
        y -= 52

    send_toggle = NSButton.alloc().initWithFrame_(NSMakeRect(175, 30, 345, 20))
    send_toggle.setButtonType_(NSSwitchButton)
    send_toggle.setTitle_("Отправлять итог в Telegram")
    send_toggle.setState_(1 if cfg.get("send_to_telegram", True) else 0)
    view.addSubview_(send_toggle)

    launch_toggle = NSButton.alloc().initWithFrame_(NSMakeRect(175, 8, 345, 20))
    launch_toggle.setButtonType_(NSSwitchButton)
    launch_toggle.setTitle_("Показывать окно записи при запуске")
    launch_toggle.setState_(1 if cfg.get("show_start_window_on_launch", True) else 0)
    view.addSubview_(launch_toggle)

    def collect() -> dict:
        data = {key: fields[key].stringValue().strip() for key in fields}
        data["send_to_telegram"] = bool(send_toggle.state())
        data["show_start_window_on_launch"] = bool(launch_toggle.state())
        return data

    while True:
        choice = _alert("Настройки", "Ключи хранятся только на этом маке, "
                                     "в репозиторий они не попадают.",
                        ("Сохранить", "Проверить ключи", "Отмена"), view)
        if choice == BUTTON_SECOND:
            info("Проверка ключей", on_check(collect()))
            continue
        if choice == BUTTON_FIRST:
            return collect()
        return None


# ── проверка звука ──────────────────────────────────────
def audio_report_window(report: dict) -> None:
    body = "\n".join(report["lines"])
    view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 520, 280))
    view.addSubview_(text_area(body, 0, 0, 520, 280, monospace=True))
    title = "Звук в порядке" if report["ok"] else "Со звуком есть проблемы"
    _alert(title, "; ".join(report["problems"]), ("Закрыть",), view)
