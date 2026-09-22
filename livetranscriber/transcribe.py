"""Транскрибация чанков через AssemblyAI. Работает прямо с мака, без сервера."""

from __future__ import annotations

import array
import io
import logging
import math
import os
import re
import subprocess
import threading
import time
import wave

import requests

from .audio import (CHANNELS, SAMPLE_RATE, SAMPLE_WIDTH, SILENCE_RMS,
                    SPEECH_RMS, levels, which)

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


SILENCE_GAP_SEC = 3.0        # пауза длиннее этой вырезается
KEEP_EDGE_SEC = 0.4          # сколько тишины оставить по краям речи
WINDOW_MS = 100


def _trim_silence(pcm: bytes, channels: int) -> bytes:
    """Вырезает длинные паузы перед отправкой.

    Распознавание не умеет молчать: на участке без речи оно достраивает то,
    что чаще всего стояло рядом с тишиной в обучающих данных — титры
    переводчиков. Чем меньше тишины уходит, тем меньше выдумок. Заодно
    расшифровка считается по длительности, так что пауза стоит денег.

    Дорожки режутся одновременно, иначе речь на них разъедется во времени.
    """
    frame = SAMPLE_WIDTH * channels
    step = int(SAMPLE_RATE * frame * WINDOW_MS / 1000)
    if not pcm or len(pcm) < step * 2:
        return pcm
    windows = [pcm[i:i + step] for i in range(0, len(pcm) - step + 1, step)]
    loud = [max(levels(w, channels)) >= SILENCE_RMS for w in windows]
    edge = int(KEEP_EDGE_SEC * 1000 / WINDOW_MS)
    gap = int(SILENCE_GAP_SEC * 1000 / WINDOW_MS)

    keep = [False] * len(windows)
    for index, is_loud in enumerate(loud):
        if is_loud:
            for near in range(max(0, index - edge), min(len(windows), index + edge + 1)):
                keep[near] = True
    # Короткие паузы внутри речи оставляем: без них слова слипаются
    start = None
    for index in range(len(windows) + 1):
        quiet = index < len(windows) and not keep[index]
        if quiet and start is None:
            start = index
        elif not quiet and start is not None:
            if index - start <= gap:
                for near in range(start, index):
                    keep[near] = True
            start = None

    if all(keep):
        return pcm
    trimmed = b"".join(w for w, ok in zip(windows, keep) if ok)
    if len(trimmed) < SAMPLE_RATE * frame:      # меньше секунды речи
        return trimmed
    logging.info("Вырезал пауз: %.0f из %.0f секунд",
                 (len(pcm) - len(trimmed)) / (SAMPLE_RATE * frame),
                 len(pcm) / (SAMPLE_RATE * frame))
    return trimmed


BLEED_FRAME_MS = 20          # кадр, которым меряем просачивание
BLEED_SPREAD = 5             # ±100 мс: столько звук идёт от колонок до микрофона
BLEED_MARGIN = 3.0           # во столько раз своя речь громче просочившейся
BLEED_LINK = 0.25            # связь громкостей, выше которой дорожки слышат друг друга


def _duck_bleed(pcm: bytes, channels: int) -> bytes:
    """Глушит в микрофоне то, что он услышал из колонок.

    Когда собеседник звучит не в наушниках, микрофон пишет его вместе с
    хозяином. Дорожки распознаются порознь, и одна и та же речь возвращается
    дважды разными словами — расшифровка превращается в кашу из чередующихся
    обрывков. Отсев по тексту тут бессилен: слова-то разные. Поэтому режем по
    звуку — кадры, где микрофон лишь повторяет собеседника, но тише него.

    Своя речь громче просочившейся в разы, поэтому она остаётся.
    """
    if channels != 2 or not pcm:
        return pcm
    size = int(SAMPLE_RATE * BLEED_FRAME_MS / 1000)
    samples = array.array("h")
    samples.frombytes(pcm[:len(pcm) // 4 * 4])
    mic, other = samples[0::2], samples[1::2]
    if len(mic) < size * 2:
        return pcm

    def envelope(track: array.array) -> list[float]:
        return [math.sqrt(sum(float(v) * v for v in track[i:i + size]) / size)
                for i in range(0, len(track) - size + 1, size)]

    heard = envelope(mic)
    played = envelope(other)
    count = min(len(heard), len(played))
    # Громкость собеседника берём с запасом по времени: звук доходит до
    # микрофона с задержкой, и кадры дорожек не совпадают ровно
    near = [max(played[max(0, i - BLEED_SPREAD):i + BLEED_SPREAD + 1])
            for i in range(count)]
    if _link(heard[:count], near) < BLEED_LINK:
        return pcm                      # наушники: микрофон живёт сам по себе

    ratios = sorted(heard[i] / near[i] for i in range(count) if near[i] >= SPEECH_RMS)
    if not ratios:
        return pcm
    gain = ratios[len(ratios) // 2]
    muted = 0
    for i in range(count):
        if near[i] < SPEECH_RMS or heard[i] >= near[i] * gain * BLEED_MARGIN:
            continue
        mic[i * size:(i + 1) * size] = array.array("h", bytes(size * 2))
        muted += 1
    if not muted:
        return pcm
    logging.info("Микрофон слышит колонки (в %.2f от собеседника), "
                 "заглушил %.0f из %.0f секунд",
                 gain, muted * BLEED_FRAME_MS / 1000, count * BLEED_FRAME_MS / 1000)
    samples[0::2] = mic
    return samples.tobytes()


def _link(first: list[float], second: list[float]) -> float:
    """Насколько похоже меняется громкость двух дорожек."""
    count = len(first)
    if count < 2:
        return 0.0
    mean_a, mean_b = sum(first) / count, sum(second) / count
    top = sum((first[i] - mean_a) * (second[i] - mean_b) for i in range(count))
    side_a = math.sqrt(sum((v - mean_a) ** 2 for v in first))
    side_b = math.sqrt(sum((v - mean_b) ** 2 for v in second))
    return top / (side_a * side_b) if side_a and side_b else 0.0


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

    pcm = _duck_bleed(pcm, channels)
    pcm, channels, only = _single_track(pcm, channels)
    pcm = _trim_silence(pcm, channels)
    if not pcm:
        logging.info("В куске записи нет речи, распознавать нечего")
        return ""
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


# Распознавание обучено в том числе на видео с субтитрами, и на тишине или
# шуме оно достраивает концовку такого видео: титры переводчиков. Реального
# отношения к разговору эти строки не имеют, фамилии каждый раз разные.
# Титры переводчиков: «Редактор субтитров А.Семкин Корректор А.Егорова».
# Узнаём их по связке «должность + инициал с точкой + фамилия», иначе
# пострадает живая речь, где слово «корректор» стоит само по себе.
_NAME = r"[А-ЯЁ]\.\s*[А-ЯЁ][а-яё]+"
INVENTED_PHRASE = re.compile(
    r"(?:[Рр]едактор\s+субтитров(?:\s+" + _NAME + r")?"
    r"|[Кк]орректор\s+" + _NAME +
    r"|[Сс]убтитр\w*\s+(?:сделал|создавал|подготовил|делал)[^.!?]*"
    r"|[Пп]родолжение\s+следует\.{2,})")
INVENTED_LIMIT = 12          # столько слов — потолок для такой вставки


def _strip_invented(text: str) -> str:
    """Вырезает титры, приклеившиеся к настоящей реплике."""
    cleaned = INVENTED_PHRASE.sub(" ", text)
    return re.sub(r"\s{2,}", " ", cleaned).strip(" .,")


# Осколки титров, когда распознавание раскрошило их на отдельные слова.
# В живой речи такие куски сами по себе не встречаются: слово «субтитры»,
# одинокая должность или инициал с фамилией без всякого предложения.
_SHARD_SUBTITLE = re.compile(r"субтитр", re.IGNORECASE)
_SHARD_ROLE = re.compile(r"^(редактор|корректор)$", re.IGNORECASE)
_SHARD_NAME = re.compile(r"^[А-ЯЁ]\.\s*[А-ЯЁ][а-яё]+$")


def _shard(text: str) -> bool:
    words = text.replace(",", " ").split()
    if not words or len(words) > 4:
        return False
    if any(_SHARD_SUBTITLE.search(w) for w in words):
        return True
    if len(words) <= 3 and any(_SHARD_ROLE.match(w) or _SHARD_NAME.match(w)
                               for w in words):
        return True
    return False


def _invented(text: str) -> bool:
    """Реплика целиком состоит из выдуманных титров или их осколков."""
    words = text.split()
    if not words or len(words) > INVENTED_LIMIT:
        return False
    return not _strip_invented(text) or _shard(text)


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
    """Убирает то, что просочилось с одной дорожки на другую.

    Речь собеседника из динамиков слышна микрофону, а речь пользователя
    отражается в дорожку системного звука. В расшифровке это выглядит как
    обрывки, приписанные не тому человеку. Из двух совпавших кусков оставляем
    более полный: короткий — почти всегда отражение.
    """
    by_channel: dict[str, list[dict]] = {}
    for u in items:
        by_channel.setdefault(str(u.get("channel") or ""), []).append(u)
    if len(by_channel) < 2:
        return items

    def size(u: dict) -> int:
        return len(_words(u.get("text", "")))

    drop: set[int] = set()
    for channel, chunks in by_channel.items():
        others = [u for key, lst in by_channel.items() if key != channel for u in lst]
        for u in chunks:
            mine = _words(u.get("text", ""))
            if not mine:
                continue
            for o in others:
                if id(o) in drop or not _overlaps(u, o):
                    continue
                theirs = _words(o.get("text", ""))
                if not theirs or size(u) > size(o):
                    continue
                # Чужая фраза целиком содержит нашу, либо они совпадают
                if mine <= theirs or (size(u) <= ECHO_SHORT_WORDS and mine & theirs) \
                        or _similar(u.get("text", ""), o.get("text", "")) >= ECHO_SIMILARITY:
                    drop.add(id(u))
                    break
    if drop:
        logging.info("Убрал отражения между дорожками: %d кусков", len(drop))
    return [u for u in items if id(u) not in drop]


def _name_for(channel: str, speaker: str, others: dict) -> str:
    if channel == MIC_CHANNEL:
        return ME
    return others.get(speaker, OTHER)


def _voices_on_mic(items: list[dict]) -> dict:
    """Имена голосов на дорожке микрофона.

    Когда собеседник говорит по громкой связи или сидит рядом, его голос
    попадает в тот же микрофон. Звать всех «Я» неправильно, поэтому самый
    говорящий остаётся хозяином микрофона, остальные становятся собеседниками.
    """
    totals: dict[str, int] = {}
    for u in items:
        key = str(u.get("speaker") or "")
        totals[key] = totals.get(key, 0) + len(u.get("text") or "")
    if len(totals) < 2:
        return {}
    main = max(totals, key=lambda k: totals[k])
    rest = sorted(k for k in totals if k != main)
    names = {main: ME}
    for index, speaker in enumerate(rest):
        names[speaker] = OTHER if len(rest) == 1 else f"{OTHER} {chr(ord('A') + index)}"
    return names


def _merge(pairs: list[tuple[str, str]]) -> str:
    """Соседние куски одного голоса снова становятся репликой."""
    lines: list[list[str]] = []
    for name, text in pairs:
        text = (text or "").strip()
        if not text:
            continue
        if lines and lines[-1][0] == name:
            lines[-1].append(text)
        else:
            lines.append([name, text])
    out = []
    for parts in lines:
        body = _strip_invented(" ".join(parts[1:]))
        if body:
            out.append(f"**{parts[0]}:** {body}")
    return "\n".join(out)


GROUP_PAUSE_MS = 2000


def _without_invented(items: list[dict]) -> list[dict]:
    """Убирает титры, даже когда они разорваны на отдельные слова.

    Речь приходит мелкими кусками вперемешку с другой дорожкой, поэтому
    «Редактор», «субтитров» и «А.Семкин» поодиночке ни на что не похожи.
    Собираем куски одной дорожки, идущие подряд, и судим по фразе целиком.
    """
    tracks: dict[str, list[dict]] = {}
    for u in items:
        key = str(u.get("channel") or u.get("speaker") or "")
        tracks.setdefault(key, []).append(u)

    drop: set[int] = set()
    for chunks in tracks.values():
        chunks.sort(key=lambda u: u.get("start", 0))
        group: list[dict] = []

        def judge(group: list[dict]) -> None:
            if not group:
                return
            phrase = " ".join((u.get("text") or "").strip() for u in group)
            if _invented(phrase):
                drop.update(id(u) for u in group)

        for u in chunks:
            if group and u.get("start", 0) - group[-1].get("end", 0) <= GROUP_PAUSE_MS:
                group.append(u)
            else:
                judge(group)
                group = [u]
        judge(group)
    if drop:
        logging.info("Убрал выдуманные титры: %d кусков", len(drop))
    return [u for u in items if id(u) not in drop]


def _format(data: dict, only: str | None = None) -> str:
    items = data.get("utterances")
    if not items:
        return (data.get("text") or "").strip()
    items = _without_invented(items)
    if not items:
        return ""
    items = sorted(items, key=lambda u: u.get("start", 0))

    if only:
        # Дорожка одна, и мы знаем, чья она. Но голосов на ней может быть
        # несколько: собеседник на громкой связи звучит в тот же микрофон.
        names = _voices_on_mic(items) if only == ME else {}
        if not names:
            return _merge([(only, u.get("text", "")) for u in items])
        return _merge([(names.get(str(u.get("speaker") or ""), only), u.get("text", ""))
                       for u in items])

    multi = int(data.get("audio_channels", 1) or 1) > 1
    if multi:
        items = _drop_echo(items)

    def split(u: dict) -> tuple[str, str]:
        channel = str(u.get("channel") or "")
        speaker = str(u.get("speaker") or "")
        if not channel and speaker[:1].isdigit():
            channel, speaker = speaker[:1], speaker[1:]
        return channel, speaker

    if not multi:
        return _merge([(f"Спикер {split(u)[1] or '?'}", u.get("text", "")) for u in items])

    voices = {s for c, s in map(split, items) if c != MIC_CHANNEL and s}
    others = {}
    if len(voices) > 1:
        others = {s: f"{OTHER} {s}" for s in sorted(voices)}
    mic_items = [u for u in items if split(u)[0] == MIC_CHANNEL]
    mic_names = _voices_on_mic(mic_items)

    pairs = []
    for u in items:
        channel, speaker = split(u)
        if channel == MIC_CHANNEL and mic_names:
            name = mic_names.get(speaker, ME)
        else:
            name = _name_for(channel, speaker, others)
        pairs.append((name, u.get("text", "")))
    return _merge(pairs)


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
