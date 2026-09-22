"""Транскрибация чанков через AssemblyAI. Работает прямо с мака, без сервера."""

from __future__ import annotations

import array
import io
import logging
import os
import re
import subprocess
import threading
import time
import wave

import requests

from .audio import (CHANNELS, SAMPLE_RATE, SAMPLE_WIDTH, SILENCE_RMS,
                    levels, which)

API_BASE = "https://api.assemblyai.com/v2"
POLL_INTERVAL = 3
POLL_TIMEOUT = 600

# Через медленный канал заливка рвётся по таймауту (проверено 18.09.2026),
# поэтому запас времени большой и есть повторные попытки.
UPLOAD_TIMEOUT = 300
UPLOAD_ATTEMPTS = 3
RETRY_PAUSE = (3, 8, 20)


class TranscribeError(RuntimeError):
    pass


def pcm_to_wav(pcm: bytes, channels: int = CHANNELS) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(SAMPLE_WIDTH)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm)
    return buf.getvalue()


def encode(pcm: bytes, channels: int = CHANNELS) -> tuple[bytes, str]:
    """PCM → FLAC для заливки. Без ffmpeg остаёмся на WAV.

    FLAC сжимает без потерь примерно вдвое. Сжатие с потерями здесь вредно:
    оно съедает те самые оттенки голоса, по которым речь делится на спикеров.
    """
    tool = which("ffmpeg")
    if not tool:
        return pcm_to_wav(pcm, channels), "wav"
    cmd = [tool, "-y", "-nostats", "-loglevel", "error",
           "-f", "s16le", "-ar", str(SAMPLE_RATE), "-ac", str(channels), "-i", "pipe:0",
           "-codec:a", "flac", "-compression_level", "8", "-f", "flac", "pipe:1"]
    try:
        proc = subprocess.run(cmd, input=pcm, capture_output=True, timeout=120)
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout, "flac"
        logging.warning("Сжатие не удалось, шлю WAV: %s",
                        proc.stderr.decode("utf-8", errors="replace")[:200])
    except Exception:  # noqa: BLE001
        logging.exception("сжатие чанка сорвалось, шлю WAV")
    return pcm_to_wav(pcm, channels), "wav"


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


def _single_track(pcm: bytes, channels: int) -> tuple[bytes, int, str | None]:
    """Если одна дорожка пустая, оставляем только вторую.

    На пустой дорожке распознавание выдумывает текст: в расшифровке
    появлялись титры вроде «Редактор субтитров». Молчащую дорожку лучше
    не отправлять вовсе, а имя говорящего мы и так знаем по номеру дорожки.
    """
    if channels != 2 or not pcm:
        return pcm, channels, None
    mic, other = levels(pcm, 2)[:2]
    keep = None
    if other < SILENCE_RMS <= mic:
        keep, name = 0, ME
    elif mic < SILENCE_RMS <= other:
        keep, name = 1, OTHER
    if keep is None:
        return pcm, channels, None
    samples = array.array("h")
    samples.frombytes(pcm[:len(pcm) // 4 * 4])
    logging.info("Вторая дорожка пустая, отправляю только «%s»", name)
    return samples[keep::2].tobytes(), 1, name


def transcribe(pcm: bytes, api_key: str, language: str = "ru",
               channels: int = 1, diarize: bool = True) -> str:
    """Один чанк PCM → текст с метками спикеров."""
    if not api_key:
        raise TranscribeError("не задан ключ AssemblyAI")

    pcm, channels, only = _single_track(pcm, channels)
    payload_bytes, fmt = encode(pcm, channels)
    headers = {"Authorization": api_key}
    logging.info("Отправляю %s, %.1f МБ", fmt, len(payload_bytes) / 1e6)

    r = _post_with_retry(f"{API_BASE}/upload", headers, payload_bytes, UPLOAD_TIMEOUT)
    if r.status_code >= 400:
        raise TranscribeError(f"загрузка не удалась: {r.status_code} {r.text[:200]}")
    audio_url = r.json()["upload_url"]

    payload = {
        "audio_url": audio_url,
        # Для русского доступна только universal-2: universal-3-5-pro его
        # пока не знает, и перечисление обеих моделей лишь плодит ошибки
        "speech_models": ["universal-2"],
        "language_code": language,
    }
    if channels > 1:
        # Каждая дорожка расшифровывается отдельно: первая — микрофон,
        # вторая — собеседник. Метки не путаются между кусками записи.
        payload["multichannel"] = True
    if diarize:
        payload["speaker_labels"] = True
        # Границы считаются для каждой дорожки отдельно, поэтому потолок низкий
        payload["speaker_options"] = {"min_speakers_expected": 1,
                                      "max_speakers_expected": 2 if channels > 1 else 4}
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
            logging.info("Модель: %s", data.get("speech_model_used") or "не указана")
            return _format(data, only)
        if status == "error":
            raise TranscribeError(data.get("error", "неизвестная ошибка"))
    raise TranscribeError("истекло время ожидания результата")


MIC_CHANNEL = "1"
ME = "Я"
OTHER = "Собеседник"


def _speaker_name(channel: str, speaker: str, many: bool) -> str:
    """Дорожка микрофона — это сам пользователь, вторая — собеседники."""
    if channel == MIC_CHANNEL:
        return ME
    if many and speaker:
        return f"{OTHER} {speaker}"
    return OTHER


def _words(text: str) -> set:
    # Знаки препинания и «ё» в двух дорожках расставлены по-разному,
    # поэтому сравниваем только сами слова и без «ё»
    return set(re.findall(r"\w+", text.lower().replace("ё", "е")))


def _stems(text: str) -> set:
    # Одно и то же слово две дорожки слышат с разными окончаниями
    # («бюджета» и «бюджеты»), поэтому сравниваем по началу слова
    return {w[:5] for w in _words(text)}


def _similar(first: str, second: str) -> float:
    a, b = _stems(first), _stems(second)
    if not a or not b:
        return 0.0
    return len(a & b) / min(len(a), len(b))


def _overlaps(first: dict, second: dict) -> bool:
    return not (first.get("end", 0) < second.get("start", 0)
                or first.get("start", 0) > second.get("end", 0))


ECHO_SIMILARITY = 0.5
ECHO_SHORT_WORDS = 3


def _drop_echo(items: list[dict]) -> list[dict]:
    """Убирает голос собеседника, попавший в микрофон через динамики.

    Без наушников речь собеседника слышна обеим дорожкам, и разговор в
    расшифровке двоится. Сначала ищем явные повторы. Если они есть, значит
    звук из динамиков действительно протекает в микрофон, и тогда убираем
    ещё и короткие обрывки, сказанные поверх чужой речи. Когда повторов нет
    (пользователь в наушниках), короткие реплики остаются нетронутыми.
    """
    others = [u for u in items if str(u.get("channel") or "") != MIC_CHANNEL]
    if not others:
        return items

    def repeats(u: dict) -> bool:
        return any(_overlaps(u, o)
                   and _similar(u.get("text", ""), o.get("text", "")) >= ECHO_SIMILARITY
                   for o in others)

    mine = [u for u in items if str(u.get("channel") or "") == MIC_CHANNEL]
    leaking = sum(1 for u in mine if repeats(u)) >= 2

    kept, dropped = [], 0
    for u in items:
        if str(u.get("channel") or "") != MIC_CHANNEL:
            kept.append(u)
            continue
        short_over_speech = (leaking
                             and len(_words(u.get("text", ""))) <= ECHO_SHORT_WORDS
                             and any(_overlaps(u, o) for o in others))
        if repeats(u) or short_over_speech:
            dropped += 1
        else:
            kept.append(u)
    if dropped:
        logging.info("Убрал из микрофона %d кусков эха динамиков", dropped)
    return kept


def _format(data: dict, only: str | None = None) -> str:
    items = data.get("utterances")
    if not items:
        return (data.get("text") or "").strip()
    if only:
        # Дорожка одна и мы знаем, чья она: голоса различать не по чему
        text = " ".join((u.get("text") or "").strip() for u in items).strip()
        return f"**{only}:** {text}" if text else ""

    multi = bool(data.get("audio_channels", 1) and int(data.get("audio_channels", 1)) > 1)
    if multi:
        items = _drop_echo(items)

    # Метка вида «1A» означает дорожку 1 и спикера A внутри неё
    def split(u: dict) -> tuple[str, str]:
        channel = str(u.get("channel") or "")
        speaker = str(u.get("speaker") or "")
        if not channel and speaker[:1].isdigit():
            channel, speaker = speaker[:1], speaker[1:]
        return channel, speaker

    voices = {s for c, s in map(split, items) if c != MIC_CHANNEL and s}
    items = sorted(items, key=lambda u: u.get("start", 0))

    # Разбор по дорожкам возвращает речь мелкими кусками, иногда по одному
    # слову. Читать такое невозможно, поэтому соседние куски одного голоса
    # снова собираются в реплику.
    lines: list[list[str]] = []
    last_name = None
    for u in items:
        channel, speaker = split(u)
        name = _speaker_name(channel, speaker, len(voices) > 1) if multi \
            else f"Спикер {speaker or '?'}"
        text = (u.get("text") or "").strip()
        if not text:
            continue
        if name == last_name:
            lines[-1].append(text)
        else:
            lines.append([name, text])
            last_name = name
    return "\n".join(f"**{parts[0]}:** {' '.join(parts[1:])}" for parts in lines)


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

    def submit(self, pcm: bytes, index: int, channels: int = 1) -> None:
        self._slots.acquire()
        t = threading.Thread(target=self._work, args=(pcm, index, channels), daemon=True)
        self._threads.append(t)
        t.start()

    def _work(self, pcm: bytes, index: int, channels: int = 1) -> None:
        text = ""
        try:
            text = transcribe(pcm, self.api_key, self.language, channels)
            if not text:
                self.empty += 1
                logging.warning("Чанк %d: речь не распознана", index)
            else:
                logging.info("Чанк %d: %d символов", index, len(text))
        except Exception as e:  # noqa: BLE001
            self.failed += 1
            logging.exception("Чанк %d не транскрибирован", index)
            self._rescue(pcm, index, channels)
            if self.on_error:
                self.on_error(str(e), index)
        finally:
            self._slots.release()
            self._store(index, text)

    def _rescue(self, pcm: bytes, index: int, channels: int = 1) -> None:
        if not self.rescue_dir:
            return
        try:
            os.makedirs(self.rescue_dir, exist_ok=True)
            data, fmt = encode(pcm, channels)
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
