"""Транскрибация чанков через AssemblyAI. Работает прямо с мака, без сервера."""

from __future__ import annotations

import io
import logging
import os
import subprocess
import threading
import time
import wave

import requests

from .audio import CHANNELS, SAMPLE_RATE, SAMPLE_WIDTH, which

API_BASE = "https://api.assemblyai.com/v2"
POLL_INTERVAL = 3
POLL_TIMEOUT = 600

# Минута WAV — почти два мегабайта, и через медленный канал такая заливка
# рвётся по таймауту (проверено 18.09.2026). Сжимаем: та же минута в mp3 64k
# весит около 480 КБ, на распознавание речи это не влияет.
UPLOAD_TIMEOUT = 300
UPLOAD_ATTEMPTS = 3
RETRY_PAUSE = (3, 8, 20)


class TranscribeError(RuntimeError):
    pass


def pcm_to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(CHANNELS)
        wav.setsampwidth(SAMPLE_WIDTH)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm)
    return buf.getvalue()


def encode(pcm: bytes) -> tuple[bytes, str]:
    """PCM → mp3 для заливки. Без ffmpeg остаёмся на WAV."""
    tool = which("ffmpeg")
    if not tool:
        return pcm_to_wav(pcm), "wav"
    cmd = [tool, "-y", "-nostats", "-loglevel", "error",
           "-f", "s16le", "-ar", str(SAMPLE_RATE), "-ac", str(CHANNELS), "-i", "pipe:0",
           "-codec:a", "libmp3lame", "-b:a", "64k", "-f", "mp3", "pipe:1"]
    try:
        proc = subprocess.run(cmd, input=pcm, capture_output=True, timeout=120)
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout, "mp3"
        logging.warning("Сжатие не удалось, шлю WAV: %s",
                        proc.stderr.decode("utf-8", errors="replace")[:200])
    except Exception:  # noqa: BLE001
        logging.exception("сжатие чанка сорвалось, шлю WAV")
    return pcm_to_wav(pcm), "wav"


def _post_with_retry(url: str, headers: dict, data: bytes, timeout: int) -> requests.Response:
    """Сеть на маке моргает (VPN, wifi) — не теряем запись из-за одной ошибки."""
    last: Exception | None = None
    for attempt in range(1, UPLOAD_ATTEMPTS + 1):
        try:
            return requests.post(url, headers=headers, data=data, timeout=timeout)
        except requests.RequestException as e:
            last = e
            pause = RETRY_PAUSE[min(attempt - 1, len(RETRY_PAUSE) - 1)]
            logging.warning("Заливка не удалась (попытка %d из %d): %s. Жду %d с",
                            attempt, UPLOAD_ATTEMPTS, e, pause)
            if attempt < UPLOAD_ATTEMPTS:
                time.sleep(pause)
    raise TranscribeError(f"не удалось залить аудио за {UPLOAD_ATTEMPTS} попытки: {last}")


def check_key(api_key: str) -> tuple[bool, str]:
    """Проверка ключа для окна настроек."""
    if not api_key:
        return False, "ключ не задан"
    try:
        r = requests.get(f"{API_BASE}/transcript", params={"limit": 1},
                         headers={"Authorization": api_key}, timeout=15)
    except requests.RequestException as e:
        return False, f"нет связи: {e}"
    if r.status_code == 401:
        return False, "ключ не принят (401)"
    if r.status_code >= 400:
        return False, f"ошибка {r.status_code}"
    return True, "ключ рабочий"


def transcribe(pcm: bytes, api_key: str, language: str = "ru",
               diarize: bool = True) -> str:
    """Один чанк PCM → текст с метками спикеров."""
    if not api_key:
        raise TranscribeError("не задан ключ AssemblyAI")

    payload_bytes, fmt = encode(pcm)
    headers = {"Authorization": api_key}
    logging.info("Отправляю %s, %.1f МБ", fmt, len(payload_bytes) / 1e6)

    r = _post_with_retry(f"{API_BASE}/upload", headers, payload_bytes, UPLOAD_TIMEOUT)
    if r.status_code >= 400:
        raise TranscribeError(f"загрузка не удалась: {r.status_code} {r.text[:200]}")
    audio_url = r.json()["upload_url"]

    payload = {
        "audio_url": audio_url,
        "speech_models": ["universal-3-5-pro", "universal-2"],
        "language_code": language,
        "speaker_labels": diarize,
    }
    r = requests.post(f"{API_BASE}/transcript", headers=headers, json=payload, timeout=60)
    if r.status_code >= 400:
        raise TranscribeError(f"запрос не принят: {r.status_code} {r.text[:200]}")
    transcript_id = r.json()["id"]

    deadline = time.time() + POLL_TIMEOUT
    while time.time() < deadline:
        time.sleep(POLL_INTERVAL)
        r = requests.get(f"{API_BASE}/transcript/{transcript_id}",
                         headers=headers, timeout=60)
        if r.status_code >= 400:
            raise TranscribeError(f"опрос не удался: {r.status_code}")
        data = r.json()
        status = data.get("status")
        if status == "completed":
            return _format(data)
        if status == "error":
            raise TranscribeError(data.get("error", "неизвестная ошибка"))
    raise TranscribeError("истекло время ожидания результата")


def _format(data: dict) -> str:
    if data.get("utterances"):
        return "\n".join(f"**Спикер {u['speaker']}:** {u['text']}"
                         for u in data["utterances"])
    return (data.get("text") or "").strip()


class ChunkPipeline:
    """Очередь чанков: транскрибируем параллельно, пишем строго по порядку."""

    def __init__(self, api_key: str, language: str, on_text, on_error=None,
                 workers: int = 2, rescue_dir: str | None = None):
        self.api_key = api_key
        self.language = language
        # Куда сложить аудио, которое не удалось расшифровать: лучше кусок
        # файла на диске, чем молча потерянный разговор
        self.rescue_dir = rescue_dir
        self.on_text = on_text          # (текст, номер чанка)
        self.on_error = on_error        # (сообщение, номер чанка)
        self.workers = workers
        self._results: dict[int, str] = {}
        self._next_to_write = 1
        self._lock = threading.Lock()
        self._slots = threading.Semaphore(workers)
        self._threads: list[threading.Thread] = []
        self.failed = 0
        self.empty = 0

    def submit(self, pcm: bytes, index: int) -> None:
        self._slots.acquire()
        t = threading.Thread(target=self._work, args=(pcm, index), daemon=True)
        self._threads.append(t)
        t.start()

    def _work(self, pcm: bytes, index: int) -> None:
        text = ""
        try:
            text = transcribe(pcm, self.api_key, self.language)
            if not text:
                self.empty += 1
                logging.warning("Чанк %d: речь не распознана", index)
            else:
                logging.info("Чанк %d: %d символов", index, len(text))
        except Exception as e:  # noqa: BLE001
            self.failed += 1
            logging.exception("Чанк %d не транскрибирован", index)
            self._rescue(pcm, index)
            if self.on_error:
                self.on_error(str(e), index)
        finally:
            self._slots.release()
            self._store(index, text)

    def _rescue(self, pcm: bytes, index: int) -> None:
        if not self.rescue_dir:
            return
        try:
            os.makedirs(self.rescue_dir, exist_ok=True)
            data, fmt = encode(pcm)
            path = os.path.join(self.rescue_dir, f"нерасшифровано-{index:03d}.{fmt}")
            with open(path, "wb") as f:
                f.write(data)
            logging.warning("Аудио чанка %d сохранено: %s", index, path)
        except Exception:  # noqa: BLE001
            logging.exception("не удалось сохранить аудио чанка %d", index)

    def _store(self, index: int, text: str) -> None:
        with self._lock:
            self._results[index] = text
            while self._next_to_write in self._results:
                ready = self._results.pop(self._next_to_write)
                if ready:
                    self.on_text(ready, self._next_to_write)
                self._next_to_write += 1

    def wait(self, timeout: float = 900) -> None:
        deadline = time.time() + timeout
        for t in list(self._threads):
            remaining = max(0.1, deadline - time.time())
            t.join(timeout=remaining)
        # Дырки в нумерации (упавшие чанки) не должны блокировать выдачу
        with self._lock:
            for index in sorted(self._results):
                text = self._results.pop(index)
                if text:
                    self.on_text(text, index)
