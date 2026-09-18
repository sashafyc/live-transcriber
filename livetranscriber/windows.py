"""Окна приложения. Все вызовы — только из главного потока."""

from __future__ import annotations

import logging
import os
import subprocess

from AppKit import (
    NSAlert, NSAlertFirstButtonReturn, NSAlertSecondButtonReturn,
    NSAlertThirdButtonReturn, NSApp, NSApplicationActivationPolicyAccessory,
    NSApplicationActivationPolicyRegular, NSBezelBorder, NSColor,
    NSFloatingWindowLevel, NSFont, NSFontAttributeName,
    NSForegroundColorAttributeName, NSMakeRect, NSMutableAttributedString,
    NSPasteboard, NSPasteboardTypeString, NSPopUpButton, NSScrollView,
    NSSecureTextField, NSSwitchButton, NSTextField, NSTextView, NSButton, NSView,
    NSBackingStoreBuffered, NSPanel, NSWindowStyleMaskClosable,
    NSWindowStyleMaskResizable, NSWindowStyleMaskTitled,
)
from Foundation import NSObject, NSSelectorFromString

from . import config, markup

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


def set_markdown(view: NSTextView, text: str, size: float = 12) -> None:
    """Показывает разметку как разметку: жирный рисуется шрифтом.

    Без этого читатель видит в окне сами звёздочки и решётки — ровно то,
    от чего разметка должна была избавить.
    """
    plain, bold_spans = markup.spans(markup.normalize(text))
    body = NSMutableAttributedString.alloc().initWithString_(plain)
    whole = (0, len(plain))
    body.addAttribute_value_range_(NSFontAttributeName,
                                   NSFont.systemFontOfSize_(size), whole)
    # Цвет обязательно системный, иначе в тёмной теме текст сливается с фоном
    body.addAttribute_value_range_(NSForegroundColorAttributeName,
                                   NSColor.labelColor(), whole)
    bold_font = NSFont.boldSystemFontOfSize_(size)
    for start, length in bold_spans:
        body.addAttribute_value_range_(NSFontAttributeName, bold_font, (start, length))
    view.textStorage().setAttributedString_(body)


def text_area(text: str, x: float, y: float, width: float, height: float,
              monospace: bool = False, rich: bool = False) -> NSScrollView:
    scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(x, y, width, height))
    scroll.setHasVerticalScroller_(True)
    scroll.setBorderType_(NSBezelBorder)
    view = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, width, height))
    view.setEditable_(False)
    view.setRichText_(False)
    if rich:
        set_markdown(view, text)
    else:
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


# ── немодальные окна ────────────────────────────────────
# Модальное окно останавливает всё приложение: пока оно открыто, меню в строке
# состояния не отвечает. 18.09.2026 такое окно ушло за другие окна, и приложение
# выглядело зависшим — значок остался красным, пункты меню серыми. Поэтому окна,
# которые появляются сами или открыты подолгу, сделаны обычными.

_open_panels: list = []


class _PanelController(NSObject):
    """Кнопки панели и снятие ссылки при закрытии."""

    def onFirst_(self, sender):
        callback = getattr(self, "first_callback", None)
        if callback:
            callback()

    def onSecond_(self, sender):
        callback = getattr(self, "second_callback", None)
        if callback:
            callback()

    def onClose_(self, sender):
        panel = getattr(self, "panel", None)
        if panel:
            panel.close()

    def onSelect_(self, sender):
        callback = getattr(self, "select_callback", None)
        if callback:
            callback(sender.indexOfSelectedItem())

    def onToggle_(self, sender):
        callback = getattr(self, "toggle_callback", None)
        if callback:
            callback(bool(sender.state()))

    def windowWillClose_(self, notification):
        # Без этого панель остаётся в списке и живёт до конца работы приложения
        panel = getattr(self, "panel", None)
        for index, (window, _) in enumerate(list(_open_panels)):
            if window is panel:
                _open_panels.pop(index)
                break


def _make_panel(title: str, width: float, height: float):
    panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        NSMakeRect(0, 0, width, height),
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, False)
    panel.setTitle_(title)
    panel.setReleasedWhenClosed_(False)
    panel.setLevel_(NSFloatingWindowLevel)
    panel.setHidesOnDeactivate_(False)
    panel.center()
    return panel


def _show_panel(panel, controller) -> None:
    panel.setDelegate_(controller)
    controller.panel = panel
    _open_panels.append((panel, controller))
    NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    NSApp.activateIgnoringOtherApps_(True)
    panel.makeKeyAndOrderFront_(None)
    panel.orderFrontRegardless()
    NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)


def _panel_button(title: str, x: float, width: float, controller, action: str) -> NSButton:
    button = NSButton.alloc().initWithFrame_(NSMakeRect(x, 12, width, 30))
    button.setTitle_(title)
    button.setBezelStyle_(1)
    button.setTarget_(controller)
    button.setAction_(NSSelectorFromString(action))
    return button


# ── окно саммари ────────────────────────────────────────
def summary_window(title: str, summary: str, record_path: str,
                   note: str = "", on_send=None, on_copy=None) -> None:
    """Показывает итог. Окно обычное: приложение продолжает работать."""
    width, height = 620, 520
    panel = _make_panel(f"Итог — {title}", width, height)
    controller = _PanelController.alloc().init()
    content = panel.contentView()

    scroll = text_area(summary, 16, 58, width - 32, height - 100, rich=True)
    content.addSubview_(scroll)

    if note:
        content.addSubview_(label(note, 16, height - 36, width - 32, size=11))

    def copy_summary() -> None:
        copy_to_clipboard(markup.normalize(summary))
        if on_copy:
            on_copy()

    controller.first_callback = copy_summary
    controller.second_callback = on_send
    content.addSubview_(_panel_button("Скопировать", 16, 150, controller, "onFirst:"))
    if on_send:
        content.addSubview_(_panel_button("Отправить в Telegram", 174, 200,
                                          controller, "onSecond:"))
    content.addSubview_(_panel_button("Закрыть", width - 116, 100, controller, "onClose:"))

    _show_panel(panel, controller)


# ── история ─────────────────────────────────────────────
def history_window(records: list, retention_days: int) -> None:
    """Список записей за срок хранения. Окно обычное, не блокирует приложение."""
    if not records:
        info("История пуста",
             f"Записи хранятся {retention_days} дней. Пока ни одной нет.")
        return

    width, height = 680, 560
    panel = _make_panel(f"История за {retention_days} дней", width, height)
    controller = _PanelController.alloc().init()
    content = panel.contentView()

    popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
        NSMakeRect(16, height - 60, width - 32, 26), False)
    for record in records:
        popup.addItemWithTitle_(record.label())

    text_view = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, width - 32, height - 160))
    text_view.setEditable_(False)
    text_view.setRichText_(False)
    scroll = NSScrollView.alloc().initWithFrame_(
        NSMakeRect(16, 88, width - 32, height - 160))
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
        set_markdown(text_view, text)
        text_view.scrollRangeToVisible_((0, 0))

    def on_select(index: int) -> None:
        state["index"] = index
        render()

    def on_toggle(is_transcript: bool) -> None:
        state["mode"] = "transcript" if is_transcript else "summary"
        render()

    def current():
        return records[max(0, min(state["index"], len(records) - 1))]

    controller.select_callback = on_select
    controller.toggle_callback = on_toggle
    controller.first_callback = lambda: copy_to_clipboard(text_view.string())
    controller.second_callback = lambda: reveal_in_finder(current().path)

    popup.setTarget_(controller)
    popup.setAction_(NSSelectorFromString("onSelect:"))

    toggle = NSButton.alloc().initWithFrame_(NSMakeRect(16, 56, 320, 20))
    toggle.setButtonType_(NSSwitchButton)
    toggle.setTitle_("Показать расшифровку вместо итога")
    toggle.setTarget_(controller)
    toggle.setAction_(NSSelectorFromString("onToggle:"))

    content.addSubview_(popup)
    content.addSubview_(scroll)
    content.addSubview_(toggle)
    content.addSubview_(_panel_button("Скопировать", 16, 150, controller, "onFirst:"))
    content.addSubview_(_panel_button("Показать файлы", 174, 170, controller, "onSecond:"))
    content.addSubview_(_panel_button("Закрыть", width - 116, 100, controller, "onClose:"))
    render()

    _show_panel(panel, controller)


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
