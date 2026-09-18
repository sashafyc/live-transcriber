"""Записи на диске: транскрипт, саммари, лог сессии. Хранение — 30 дней."""

from __future__ import annotations

import json
import logging
import logging.handlers
import os
import re
import shutil
import time
from datetime import datetime, timedelta, timezone

from . import config

MSK = timezone(timedelta(hours=3))

_session_handler: logging.Handler | None = None


def now_msk() -> datetime:
    return datetime.now(MSK)


def slugify(text: str) -> str:
    text = (text or "").strip().replace(" ", "-")
    text = re.sub(r"[^\w\-.]", "", text, flags=re.UNICODE)
    return text[:60] or "call"


def setup_logging() -> str:
    """Общий лог приложения с ротацией. Возвращает путь к файлу."""
    os.makedirs(config.LOG_DIR, exist_ok=True)
    path = os.path.join(config.LOG_DIR, "app.log")
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    if not any(getattr(h, "_lt_app_log", False) for h in root.handlers):
        # encoding обязателен: в .app-бандле локаль ASCII, иначе кириллица теряется
        h = logging.handlers.RotatingFileHandler(
            path, maxBytes=2_000_000, backupCount=3, encoding="utf-8")
        h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s",
                                         datefmt="%Y-%m-%d %H:%M:%S"))
        h._lt_app_log = True
        root.addHandler(h)
    # Сетевые библиотеки на уровне debug печатают полные адреса запросов,
    # а в адресе Telegram содержится токен бота. В лог такому попадать нельзя.
    for noisy in ("urllib3", "requests", "charset_normalizer"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    return path


class Record:
    """Папка одной записи: transcript.md, summary.md, session.log, meta.json."""

    def __init__(self, path: str):
        self.path = path

    # ── создание и поиск ────────────────────────────────
    @classmethod
    def create(cls, title: str, prompt: str) -> "Record":
        os.makedirs(config.RECORDS_DIR, exist_ok=True)
        stamp = now_msk().strftime("%Y-%m-%d-%H%M")
        name = f"{stamp}-{slugify(title)}"
        path = os.path.join(config.RECORDS_DIR, name)
        suffix = 2
        while os.path.exists(path):
            path = os.path.join(config.RECORDS_DIR, f"{name}-{suffix}")
            suffix += 1
        os.makedirs(path)
        rec = cls(path)
        rec.write_meta({
            "title": title,
            "prompt": prompt,
            "started_at": now_msk().isoformat(timespec="seconds"),
            "duration_sec": 0,
            "status": "recording",
        })
        rec.append_transcript(f"# Транскрипт — {now_msk():%d.%m.%Y %H:%M} — {title}\n")
        return rec

    @classmethod
    def list_all(cls) -> list["Record"]:
        if not os.path.isdir(config.RECORDS_DIR):
            return []
        names = sorted(os.listdir(config.RECORDS_DIR), reverse=True)
        return [cls(os.path.join(config.RECORDS_DIR, n)) for n in names
                if os.path.isdir(os.path.join(config.RECORDS_DIR, n))]

    # ── файлы ───────────────────────────────────────────
    @property
    def name(self) -> str:
        return os.path.basename(self.path)

    @property
    def transcript_path(self) -> str:
        return os.path.join(self.path, "transcript.md")

    @property
    def summary_path(self) -> str:
        return os.path.join(self.path, "summary.md")

    @property
    def log_path(self) -> str:
        return os.path.join(self.path, "session.log")

    def _read(self, path: str) -> str:
        try:
            with open(path, encoding="utf-8") as f:
                return f.read()
        except FileNotFoundError:
            return ""

    def transcript(self) -> str:
        return self._read(self.transcript_path)

    def summary(self) -> str:
        return self._read(self.summary_path)

    def append_transcript(self, text: str) -> None:
        with open(self.transcript_path, "a", encoding="utf-8") as f:
            f.write(text.rstrip() + "\n\n")

    def write_summary(self, text: str) -> None:
        with open(self.summary_path, "w", encoding="utf-8") as f:
            f.write(text.rstrip() + "\n")

    # ── метаданные ──────────────────────────────────────
    def meta(self) -> dict:
        try:
            with open(os.path.join(self.path, "meta.json"), encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}

    def write_meta(self, data: dict) -> None:
        meta = self.meta()
        meta.update(data)
        with open(os.path.join(self.path, "meta.json"), "w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)

    @property
    def title(self) -> str:
        return self.meta().get("title") or self.name

    def started_at(self) -> datetime | None:
        raw = self.meta().get("started_at")
        try:
            return datetime.fromisoformat(raw) if raw else None
        except ValueError:
            return None

    def human_duration(self) -> str:
        secs = int(self.meta().get("duration_sec") or 0)
        return f"{secs // 60}:{secs % 60:02d}"

    def label(self) -> str:
        """Строка для списка истории."""
        started = self.started_at()
        when = f"{started:%d.%m %H:%M}" if started else self.name[:16]
        mark = "" if self.summary() else "  (без саммари)"
        return f"{when}  ·  {self.title}  ·  {self.human_duration()}{mark}"

    # ── лог сессии ──────────────────────────────────────
    def attach_log(self) -> None:
        """Дублируем общий лог в session.log этой записи."""
        global _session_handler
        self.detach_log()
        h = logging.FileHandler(self.log_path, encoding="utf-8")
        h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s",
                                         datefmt="%H:%M:%S"))
        logging.getLogger().addHandler(h)
        _session_handler = h

    @staticmethod
    def detach_log() -> None:
        global _session_handler
        if _session_handler is not None:
            logging.getLogger().removeHandler(_session_handler)
            try:
                _session_handler.close()
            except Exception:
                pass
            _session_handler = None


def cleanup(retention_days: int = config.RETENTION_DAYS) -> int:
    """Удаляет записи и старые логи за пределами срока хранения."""
    removed = 0
    cutoff = time.time() - retention_days * 86400
    for rec in Record.list_all():
        started = rec.started_at()
        age_ok = (started.timestamp() if started else os.path.getmtime(rec.path)) < cutoff
        if age_ok:
            shutil.rmtree(rec.path, ignore_errors=True)
            removed += 1
    if os.path.isdir(config.LOG_DIR):
        for name in os.listdir(config.LOG_DIR):
            path = os.path.join(config.LOG_DIR, name)
            if os.path.isfile(path) and os.path.getmtime(path) < cutoff:
                os.remove(path)
                removed += 1
    if removed:
        logging.info("Хранение %d дней: удалено объектов — %d", retention_days, removed)
    return removed
