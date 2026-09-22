"""Аудио: устройства CoreAudio, проверка потоков, захват через ffmpeg.

Правило этого модуля: никаких subprocess(text=True). В .app-бандле локаль
US-ASCII, и любое не-ASCII имя устройства («Александр's AirPods Pro») роняет
декодирование. Везде bytes + decode('utf-8', errors='replace').
"""

from __future__ import annotations

import array
import ctypes
import logging
import math
import os
import re
import shutil
import subprocess
import threading
import time

import objc
from Foundation import NSMutableArray, NSMutableDictionary, NSNumber

SAMPLE_RATE = 16000
SAMPLE_WIDTH = 2
CHANNELS = 1
CHUNK_SECONDS = 60
CHUNK_BYTES = SAMPLE_RATE * SAMPLE_WIDTH * CHANNELS * CHUNK_SECONDS
READ_SIZE = 32000  # ~1 секунда

BLACKHOLE_NAME = "BlackHole 2ch"
BLACKHOLE_UID = "BlackHole2ch_UID"
AGGREGATE_NAME = "LT-Auto"
AGGREGATE_UID = "com.livetranscriber.lt-auto"

# Тишиной считаем чанк с уровнем ниже порога. Уровень меряется по каждой
# дорожке отдельно, поэтому порог обычный.
SILENCE_RMS = 15
# Порог, выше которого звук похож на речь, а не на шум комнаты.
# Нужен для отчёта «сколько времени на дорожке реально говорили».
SPEECH_RMS = 150

_ca = ctypes.cdll.LoadLibrary(
    "/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
_cf = ctypes.cdll.LoadLibrary(
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                   ctypes.c_long, ctypes.c_uint32]
_cf.CFStringGetCString.restype = ctypes.c_bool


class _Addr(ctypes.Structure):
    _fields_ = [("sel", ctypes.c_uint32), ("scope", ctypes.c_uint32),
                ("elem", ctypes.c_uint32)]


_SCOPE_GLOBAL = int.from_bytes(b"glob", "big")
_SCOPE_INPUT = int.from_bytes(b"inpt", "big")
_SCOPE_OUTPUT = int.from_bytes(b"outp", "big")
_SEL_DEVICES = int.from_bytes(b"dev#", "big")
_SEL_NAME = int.from_bytes(b"lnam", "big")
_SEL_UID = int.from_bytes(b"uid ", "big")
_SEL_VOLUME = int.from_bytes(b"volm", "big")
_SEL_STREAMS = int.from_bytes(b"stm#", "big")


# ── утилиты ─────────────────────────────────────────────
def which(name: str) -> str | None:
    """ffmpeg и SwitchAudioSource ставятся brew-ом; в .app PATH урезан."""
    found = shutil.which(name)
    if found:
        return found
    for base in ("/opt/homebrew/bin", "/usr/local/bin"):
        candidate = os.path.join(base, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def run(cmd: list[str], timeout: float = 5) -> tuple[int, str, str]:
    """subprocess без text=True, с явным utf-8 декодированием."""
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return (r.returncode,
                r.stdout.decode("utf-8", errors="replace"),
                r.stderr.decode("utf-8", errors="replace"))
    except FileNotFoundError:
        return 127, "", f"не найдено: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"таймаут: {' '.join(cmd[:2])}"
    except Exception as e:  # noqa: BLE001
        logging.exception("команда упала: %s", cmd[:2])
        return 1, "", str(e)


def rms(pcm: bytes) -> float:
    """Громкость куска PCM. audioop из Python 3.13 удалён, считаем сами."""
    if not pcm:
        return 0.0
    samples = array.array("h")
    samples.frombytes(pcm[:len(pcm) // 2 * 2])
    if not samples:
        return 0.0
    total = sum(float(v) * v for v in samples)
    return math.sqrt(total / len(samples))


def compress_raw(raw_path: str, out_path: str, channels: int) -> bool:
    """Сырая дорожка → FLAC. Тот же звук, места втрое меньше."""
    tool = which("ffmpeg")
    if not tool or not os.path.exists(raw_path):
        return False
    cmd = [tool, "-y", "-nostats", "-loglevel", "error",
           "-f", "s16le", "-ar", str(SAMPLE_RATE), "-ac", str(channels),
           "-i", raw_path, "-codec:a", "flac", "-compression_level", "8", out_path]
    try:
        done = subprocess.run(cmd, capture_output=True, timeout=600)
        if done.returncode == 0 and os.path.exists(out_path):
            os.remove(raw_path)
            logging.info("Звук записи сохранён: %s (%.0f МБ)",
                         out_path, os.path.getsize(out_path) / 1e6)
            return True
        logging.error("Сжатие звука не удалось: %s",
                      done.stderr.decode("utf-8", errors="replace")[:200])
    except Exception:  # noqa: BLE001
        logging.exception("сжатие звука сорвалось")
    return False


def decode_audio(path: str, channels: int = 2) -> bytes:
    """Сохранённый звук записи → сырые отсчёты для повторной расшифровки."""
    tool = which("ffmpeg")
    if not tool or not os.path.exists(path):
        return b""
    cmd = [tool, "-nostats", "-loglevel", "error", "-i", path,
           "-f", "s16le", "-acodec", "pcm_s16le",
           "-ar", str(SAMPLE_RATE), "-ac", str(channels), "pipe:1"]
    try:
        done = subprocess.run(cmd, capture_output=True, timeout=600)
        if done.returncode == 0:
            return done.stdout
        logging.error("Не прочитать звук записи: %s",
                      done.stderr.decode("utf-8", errors="replace")[:200])
    except Exception:  # noqa: BLE001
        logging.exception("чтение звука записи сорвалось")
    return b""


def audio_channels(path: str) -> int:
    """Сколько дорожек в сохранённом звуке."""
    tool = which("ffprobe") or which("ffmpeg")
    if not tool or not os.path.exists(path):
        return 2
    if tool.endswith("ffprobe"):
        done = run([tool, "-v", "error", "-select_streams", "a:0",
                    "-show_entries", "stream=channels", "-of", "csv=p=0", path], timeout=20)
        digits = "".join(c for c in done[1] if c.isdigit())
        return int(digits) if digits else 2
    return 2


def speech_share(pcm: bytes, channels: int, channel: int = 0) -> float:
    """Какая доля записи на дорожке — звук, а не тишина.

    Отличает «собеседник говорил мало» от «писался громкий шум»: у шума
    доля близка к единице при любом уровне, у разговора — заметно меньше.
    """
    if not pcm:
        return 0.0
    step = SAMPLE_RATE * SAMPLE_WIDTH * channels  # секунда
    loud = total = 0
    for start in range(0, len(pcm) - step, step):
        part = pcm[start:start + step]
        if levels(part, channels)[channel] >= SPEECH_RMS:
            loud += 1
        total += 1
    return loud / total if total else 0.0


def levels(pcm: bytes, channels: int) -> list[float]:
    """Громкость каждой дорожки отдельно: [микрофон, собеседник].

    Без разделения тихий собеседник тонет в громком микрофоне, и приложение
    показывает «звук есть», когда половина разговора не пишется.
    """
    if channels <= 1:
        return [rms(pcm)]
    samples = array.array("h")
    samples.frombytes(pcm[:len(pcm) // (2 * channels) * 2 * channels])
    out = []
    for ch in range(channels):
        part = samples[ch::channels]
        if not part:
            out.append(0.0)
            continue
        out.append(math.sqrt(sum(float(v) * v for v in part) / len(part)))
    return out


def _cf_string(device_id: int, selector: int) -> str:
    prop = _Addr(selector, _SCOPE_GLOBAL, 0)
    size = ctypes.c_uint32(8)
    ref = ctypes.c_void_p()
    ok = _ca.AudioObjectGetPropertyData(device_id, ctypes.byref(prop), 0, None,
                                        ctypes.byref(size), ctypes.byref(ref))
    if ok == 0 and ref.value:
        buf = ctypes.create_string_buffer(512)
        _cf.CFStringGetCString(ref.value, buf, 512, 0x08000100)
        return buf.value.decode("utf-8", errors="replace")
    return ""


def _has_streams(device_id: int, scope: int) -> bool:
    prop = _Addr(_SEL_STREAMS, scope, 0)
    size = ctypes.c_uint32(0)
    _ca.AudioObjectGetPropertyDataSize(device_id, ctypes.byref(prop), 0, None,
                                       ctypes.byref(size))
    return size.value > 0


def devices() -> list[dict]:
    """Все аудио-устройства системы с направлением."""
    prop = _Addr(_SEL_DEVICES, _SCOPE_GLOBAL, 0)
    size = ctypes.c_uint32(0)
    _ca.AudioObjectGetPropertyDataSize(1, ctypes.byref(prop), 0, None,
                                       ctypes.byref(size))
    count = size.value // 4
    ids = (ctypes.c_uint32 * count)()
    _ca.AudioObjectGetPropertyData(1, ctypes.byref(prop), 0, None,
                                   ctypes.byref(size), ids)
    out = []
    for did in ids:
        out.append({
            "id": did,
            "name": _cf_string(did, _SEL_NAME),
            "uid": _cf_string(did, _SEL_UID),
            "input": _has_streams(did, _SCOPE_INPUT),
            "output": _has_streams(did, _SCOPE_OUTPUT),
        })
    return out


def find_device(name_part: str) -> dict | None:
    for dev in devices():
        if name_part in dev["name"]:
            return dev
    return None


def get_volume(device_id: int) -> float:
    prop = _Addr(_SEL_VOLUME, _SCOPE_OUTPUT, 0)
    vol = ctypes.c_float(0)
    size = ctypes.c_uint32(4)
    if _ca.AudioObjectGetPropertyData(device_id, ctypes.byref(prop), 0, None,
                                      ctypes.byref(size), ctypes.byref(vol)) == 0:
        return vol.value
    return 0.5


def set_volume(device_id: int, value: float) -> None:
    prop = _Addr(_SEL_VOLUME, _SCOPE_OUTPUT, 0)
    vol = ctypes.c_float(max(0.0, min(1.0, value)))
    _ca.AudioObjectSetPropertyData(device_id, ctypes.byref(prop), 0, None, 4,
                                   ctypes.byref(vol))


def wait_for_device(name: str, timeout: float = 3.0) -> bool:
    """Созданное устройство появляется в системе не мгновенно."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if find_device(name):
            return True
        time.sleep(0.15)
    return False


def create_aggregate(output_uid: str) -> int | None:
    """Multi-output: BlackHole + текущий выход, чтобы слышать и записывать."""
    _ca.AudioHardwareCreateAggregateDevice.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    _ca.AudioHardwareCreateAggregateDevice.restype = ctypes.c_int32

    subs = NSMutableArray.alloc().init()
    for uid in (BLACKHOLE_UID, output_uid):
        item = NSMutableDictionary.alloc().init()
        item.setObject_forKey_(uid, "uid")
        subs.addObject_(item)

    desc = NSMutableDictionary.alloc().init()
    desc.setObject_forKey_(AGGREGATE_NAME, "name")
    desc.setObject_forKey_(AGGREGATE_UID, "uid")
    desc.setObject_forKey_(NSNumber.numberWithBool_(False), "private")
    desc.setObject_forKey_(NSNumber.numberWithBool_(True), "stacked")
    # Ключ именно "subdevices" (kAudioAggregateDeviceSubDeviceListKey).
    # С "sub" macOS 27 создаёт устройство без выходных потоков: оно есть,
    # но звук в него не идёт и SwitchAudioSource его не видит.
    desc.setObject_forKey_(subs, "subdevices")

    new_id = ctypes.c_uint32(0)
    err = _ca.AudioHardwareCreateAggregateDevice(objc.pyobjc_id(desc),
                                                 ctypes.byref(new_id))
    if err == 0:
        # Без ожидания SwitchAudioSource не находит устройство по имени
        wait_for_device(AGGREGATE_NAME)
        logging.info("Aggregate LT-Auto создан (id=%d, выход=%s)", new_id.value, output_uid)
        return new_id.value
    logging.error("Не удалось создать aggregate: код %d, выход %s", err, output_uid)
    return None


# ── звук собеседника без переключения выхода ────────────
TAP_DEVICE_NAME = "LT-System"
TAP_DEVICE_UID = "com.livetranscriber.lt-system"


def _output_uid() -> str | None:
    """UID устройства, на которое macOS сейчас выводит звук."""
    current = current_output()
    for dev in devices():
        if dev["name"] == current and dev["output"]:
            return dev["uid"]
    return None


def tap_supported() -> bool:
    """Умеет ли система ответвлять звук: нужна macOS 14.4 или новее."""
    try:
        objc.lookUpClass("CATapDescription")
        return True
    except Exception:  # noqa: BLE001
        return False


def create_system_tap() -> tuple[int, int] | None:
    """Ответвление системного звука: слушаем то же, что слышит пользователь.

    Раньше для записи собеседника приходилось переключать выход на составное
    устройство — у пользователя пропадал звук, и его приходилось возвращать
    руками прямо на созвоне. Ответвление (process tap) ничего не переключает:
    выход остаётся тем же, а мы получаем копию звука.

    Требует macOS 14.4 и разрешения «Запись звука системы».
    Возвращает (id ответвления, id устройства) или None.
    """
    try:
        CATapDescription = objc.lookUpClass("CATapDescription")
    except Exception:  # noqa: BLE001
        logging.info("Ответвление звука недоступно: нужна macOS 14.4 или новее")
        return None

    output_uid = _output_uid()
    if not output_uid:
        logging.error("Не понял, куда идёт звук: ответвление не создать")
        return None

    desc = CATapDescription.alloc().initStereoGlobalTapButExcludeProcesses_(
        NSMutableArray.alloc().init())
    desc.setName_(TAP_DEVICE_NAME)
    desc.setPrivate_(False)      # иначе устройство видно только нам, но не ffmpeg
    desc.setMuteBehavior_(0)     # 0 — пользователь продолжает слышать звук
    tap_uid = str(desc.UUID().UUIDString())   # обязательно в верхнем регистре

    _ca.AudioHardwareCreateProcessTap.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    _ca.AudioHardwareCreateProcessTap.restype = ctypes.c_int32
    tap_id = ctypes.c_uint32(0)
    err = _ca.AudioHardwareCreateProcessTap(objc.pyobjc_id(desc), ctypes.byref(tap_id))
    if err != 0:
        logging.error("Ответвление звука не создано: код %d", err)
        return None

    sub = NSMutableDictionary.alloc().init()
    sub.setObject_forKey_(output_uid, "uid")
    subs = NSMutableArray.alloc().init()
    subs.addObject_(sub)

    tap_item = NSMutableDictionary.alloc().init()
    tap_item.setObject_forKey_(tap_uid, "uid")
    tap_item.setObject_forKey_(NSNumber.numberWithBool_(True), "drift")
    taps = NSMutableArray.alloc().init()
    taps.addObject_(tap_item)

    desc_dict = NSMutableDictionary.alloc().init()
    desc_dict.setObject_forKey_(TAP_DEVICE_NAME, "name")
    desc_dict.setObject_forKey_(TAP_DEVICE_UID, "uid")
    desc_dict.setObject_forKey_(output_uid, "master")
    desc_dict.setObject_forKey_(NSNumber.numberWithBool_(False), "private")
    desc_dict.setObject_forKey_(NSNumber.numberWithBool_(False), "stacked")
    desc_dict.setObject_forKey_(NSNumber.numberWithBool_(True), "tapautostart")
    desc_dict.setObject_forKey_(subs, "subdevices")
    desc_dict.setObject_forKey_(taps, "taps")

    _ca.AudioHardwareCreateAggregateDevice.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    _ca.AudioHardwareCreateAggregateDevice.restype = ctypes.c_int32
    dev_id = ctypes.c_uint32(0)
    err = _ca.AudioHardwareCreateAggregateDevice(objc.pyobjc_id(desc_dict),
                                                 ctypes.byref(dev_id))
    if err != 0:
        logging.error("Устройство с ответвлением не создано: код %d", err)
        destroy_system_tap(tap_id.value, None)
        return None

    wait_for_device(TAP_DEVICE_NAME)
    logging.info("Ответвление звука готово (тап %d, устройство %d, выход %s)",
                 tap_id.value, dev_id.value, output_uid)
    return tap_id.value, dev_id.value


def destroy_system_tap(tap_id: int | None, device_id: int | None) -> None:
    """Порядок важен: сначала устройство, потом само ответвление."""
    if device_id:
        destroy_aggregate(device_id)
    if tap_id:
        _ca.AudioHardwareDestroyProcessTap.argtypes = [ctypes.c_uint32]
        _ca.AudioHardwareDestroyProcessTap.restype = ctypes.c_int32
        err = _ca.AudioHardwareDestroyProcessTap(ctypes.c_uint32(tap_id))
        logging.info("Ответвление звука убрано (id=%d, код %d)", tap_id, err)


def cleanup_stale_taps() -> None:
    """Подчищаем устройство ответвления от прошлого аварийного завершения."""
    for dev in devices():
        if dev["uid"] == TAP_DEVICE_UID or dev["name"] == TAP_DEVICE_NAME:
            destroy_aggregate(dev["id"])


def destroy_aggregate(device_id: int) -> None:
    _ca.AudioHardwareDestroyAggregateDevice.argtypes = [ctypes.c_uint32]
    _ca.AudioHardwareDestroyAggregateDevice.restype = ctypes.c_int32
    err = _ca.AudioHardwareDestroyAggregateDevice(device_id)
    logging.info("Aggregate удалён (id=%d, код %d)", device_id, err)


def cleanup_stale_aggregates() -> None:
    """Подчищаем LT-Auto от прошлого аварийного завершения."""
    for dev in devices():
        if dev["uid"] == AGGREGATE_UID or dev["name"] == AGGREGATE_NAME:
            destroy_aggregate(dev["id"])


# ── переключение выхода ─────────────────────────────────
def current_output() -> str | None:
    tool = which("SwitchAudioSource")
    if not tool:
        return None
    code, out, _ = run([tool, "-c", "-t", "output"], timeout=3)
    name = out.strip()
    return name or None


def set_output(name: str) -> bool:
    tool = which("SwitchAudioSource")
    if not tool:
        logging.error("SwitchAudioSource не найден: brew install switchaudio-osx")
        return False
    code, _, err = run([tool, "-s", name, "-t", "output"], timeout=3)
    if code != 0:
        logging.error("Не удалось переключить выход на %r: %s", name, err.strip())
    return code == 0


# ── avfoundation ────────────────────────────────────────
def av_inputs() -> list[tuple[str, str]]:
    """Входы, как их видит ffmpeg: [(индекс, имя)]. Индексы плавают."""
    tool = which("ffmpeg")
    if not tool:
        return []
    _, _, err = run([tool, "-f", "avfoundation", "-list_devices", "true", "-i", ""],
                    timeout=10)
    result, in_audio = [], False
    for line in err.split("\n"):
        if "AVFoundation audio devices:" in line:
            in_audio = True
            continue
        if in_audio:
            m = re.search(r"\]\s*\[(\d+)\]\s*(.+)", line)
            if m:
                result.append((m.group(1), m.group(2).strip()))
            elif "AVFoundation" in line:
                break
    return result


def av_spec(name: str) -> str | None:
    """Как назвать устройство для ffmpeg: именем, а не номером.

    Номера входов живут ровно до следующего изменения набора устройств.
    22.09.2026 из-за этого пропала запись целого созвона: между выбором
    микрофона и запуском записи подключился микрофон телефона, номера
    сдвинулись, и вместо микрофона писалась пустая виртуальная звуковая карта.
    Имя устройства так не подводит.
    """
    if not name:
        return None
    if ":" in name:                      # двоеточие разделяет видео и звук
        return av_index(name)
    if any(n == name for _, n in av_inputs()):
        return name
    return av_index(name)


def av_index(name_part: str) -> str | None:
    for idx, name in av_inputs():
        if name_part in name:
            return idx
    return None


def is_continuity_mic(name: str) -> bool:
    """Микрофон айфона рядом с маком: пишет не то, что нужно."""
    return name.startswith("@") and name.endswith("Microphone")


def best_mic() -> tuple[str, str] | None:
    """Лучший микрофон: внешний или BT впереди встроенного."""
    # Свои служебные устройства в микрофоны не годятся: ответвление системного
    # звука тоже выглядит как вход, и запись ушла бы сама в себя
    own = (BLACKHOLE_NAME, AGGREGATE_NAME, TAP_DEVICE_NAME)
    candidates = [(idx, name) for idx, name in av_inputs()
                  if all(mark not in name for mark in own)
                  and not is_continuity_mic(name)]
    if not candidates:
        return None
    for idx, name in candidates:
        if "MacBook" not in name and "Built" not in name:
            return idx, name
    return candidates[0]


def capture_command(mic: str, system: str | None) -> tuple[list[str], int]:
    """ffmpeg: микрофон и звук собеседника → PCM 16 кГц в stdout.

    Когда звук собеседника есть, дорожки НЕ смешиваются: микрофон идёт левым
    каналом, собеседник правым. Так расшифровка сама знает, кто говорит, и не
    гадает по голосу — это главный источник путаницы со спикерами.
    Возвращает команду и число каналов в потоке.
    """
    tool = which("ffmpeg") or "ffmpeg"
    cmd = [tool, "-y", "-nostats", "-loglevel", "warning",
           "-f", "avfoundation", "-i", f":{mic}"]
    if system is None:
        cmd += ["-ac", "1"]
        channels = 1
    else:
        # Каждый вход сначала сводим в моно, иначе стереовход даст лишние
        # каналы и дорожки перестанут соответствовать «микрофон / собеседник»
        cmd += ["-f", "avfoundation", "-i", f":{system}",
                "-filter_complex",
                "[0:a]pan=mono|c0=c0[mic];"
                "[1:a]pan=mono|c0=0.5*c0+0.5*c1[sys];"
                # join, а не amerge: он явно кладёт микрофон в левый канал,
                # а собеседника в правый, не гадая по раскладке входов
                "[mic][sys]join=inputs=2:channel_layout=stereo[out]",
                "-map", "[out]"]
        channels = 2
    cmd += ["-f", "s16le", "-acodec", "pcm_s16le", "-ar", str(SAMPLE_RATE), "pipe:1"]
    return cmd, channels


def probe(device_index: str, seconds: float = 2.0) -> float:
    """Пишем несколько секунд с одного входа и меряем громкость."""
    tool = which("ffmpeg")
    if not tool:
        return -1.0
    cmd = [tool, "-y", "-nostats", "-loglevel", "error",
           "-f", "avfoundation", "-i", f":{device_index}",
           "-t", str(seconds), "-f", "s16le", "-acodec", "pcm_s16le",
           "-ar", str(SAMPLE_RATE), "-ac", str(CHANNELS), "pipe:1"]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # Таймаут вдвое больше длительности: зависший coreaudiod не должен
        # вешать приложение (было 18.09.2026 — ffmpeg не отдавал ни байта)
        out, err = proc.communicate(timeout=seconds * 2 + 8)
    except subprocess.TimeoutExpired:
        proc.kill()
        logging.error("Проба входа %s зависла — вероятно завис coreaudiod", device_index)
        return -1.0
    if not out:
        logging.error("Проба входа %s: пусто. ffmpeg: %s", device_index,
                      err.decode("utf-8", errors="replace").strip()[:200])
        return -1.0
    return rms(out)


def play_tone(seconds: float = 2.0) -> subprocess.Popen | None:
    """Тон в текущий выход — чтобы проверить, доходит ли звук до BlackHole."""
    tool = which("ffmpeg")
    if not tool:
        return None
    cmd = [tool, "-y", "-nostats", "-loglevel", "error",
           "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
           "-f", "audiotoolbox", "-"]
    try:
        return subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
    except Exception:  # noqa: BLE001
        logging.exception("не удалось проиграть тон")
        return None


def check() -> dict:
    """Полная проверка звука: инструменты, устройства, оба потока.

    Возвращает словарь с человекочитаемыми строками и флагом ok.
    """
    report: dict = {"ok": True, "problems": [], "lines": []}
    add = report["lines"].append

    for tool, hint in (("ffmpeg", "brew install ffmpeg"),
                       ("SwitchAudioSource", "brew install switchaudio-osx")):
        path = which(tool)
        if path:
            add(f"✅ {tool}: {path}")
        else:
            add(f"❌ {tool} не найден — {hint}")
            report["problems"].append(f"не установлен {tool}")
            report["ok"] = False

    devs = devices()
    outs = [d["name"] for d in devs if d["output"]]
    ins = [d["name"] for d in devs if d["input"]]
    add("")
    add(f"Выходы: {', '.join(outs) or 'нет'}")
    add(f"Входы: {', '.join(ins) or 'нет'}")
    add(f"Текущий выход: {current_output() or 'не определён'}")

    blackhole = find_device(BLACKHOLE_NAME)
    if not blackhole:
        add("❌ BlackHole 2ch не установлен — brew install blackhole-2ch")
        report["problems"].append("нет BlackHole: звук собеседника писаться не будет")
        report["ok"] = False

    mic = best_mic()
    add("")
    if not mic:
        add("❌ Микрофон не найден")
        report["problems"].append("нет микрофона")
        report["ok"] = False
        return report

    mic_index, mic_name = mic
    add(f"Микрофон: {mic_name}")
    level = probe(mic_index, 2.0)
    if level < 0:
        add("❌ Микрофон не отдаёт звук (ffmpeg не получил данные)")
        report["problems"].append("микрофон не отдаёт звук: проверь разрешение и устройство")
        report["ok"] = False
    elif level < SILENCE_RMS:
        add(f"⚠️ Микрофон молчит (уровень {level:.0f})")
        report["problems"].append("микрофон молчит: проверь, не выключен ли он")
        report["ok"] = False
    else:
        add(f"✅ Микрофон слышит (уровень {level:.0f})")

    if not blackhole:
        return report

    # Звук собеседника: ответвляем системный звук и слушаем, идёт ли по нему тон
    add("")
    tap = create_system_tap()
    previous = None
    aggregate_id = None
    try:
        if tap:
            tap_id, tap_dev = tap
            try:
                time.sleep(0.4)
                index = av_spec(TAP_DEVICE_NAME)
                tone = play_tone(2.5)
                level = probe(index, 2.0) if index else -1.0
                if tone:
                    tone.terminate()
                if level < 0:
                    add("❌ Звук собеседника: устройство записи не отдаёт данные")
                    report["problems"].append("ответвление звука не отдаёт данные")
                    report["ok"] = False
                elif level < SILENCE_RMS:
                    add("❌ Звук собеседника не пишется")
                    add("   Разрешите запись звука системы: Системные настройки →")
                    add("   Конфиденциальность и безопасность → Запись экрана и звука системы")
                    report["problems"].append(
                        "нет разрешения на запись звука системы")
                    report["ok"] = False
                else:
                    add(f"✅ Звук собеседника пишется (уровень {level:.0f})")
                    add("   Выход звука при этом не переключается")
            finally:
                destroy_system_tap(tap_id, tap_dev)
        else:
            # Запасной путь для macOS старее 14.4
            previous = current_output()
            out_dev = next((d for d in devs if d["name"] == previous and d["output"]), None)
            if out_dev:
                aggregate_id = create_aggregate(out_dev["uid"])
            if aggregate_id and set_output(AGGREGATE_NAME):
                time.sleep(0.4)
                bh_index = av_spec(BLACKHOLE_NAME)
                tone = play_tone(2.5)
                level = probe(bh_index, 2.0) if bh_index else -1.0
                if tone:
                    tone.terminate()
                if level < SILENCE_RMS:
                    add("❌ Звук собеседника не пишется через BlackHole")
                    report["problems"].append("звук собеседника не пишется")
                    report["ok"] = False
                else:
                    add(f"✅ Звук собеседника пишется через BlackHole (уровень {level:.0f})")
                    add("   На время записи выход звука переключается на LT-Auto")
            else:
                add("❌ Записать собеседника нечем: нужна macOS 14.4 или BlackHole")
                report["problems"].append("нет способа записать звук собеседника")
                report["ok"] = False
    finally:
        if previous:
            set_output(previous)
        if aggregate_id:
            destroy_aggregate(aggregate_id)
    return report


# ── захват ──────────────────────────────────────────────
class Recorder:
    """ffmpeg пишет PCM в stdout, мы режем поток на чанки по 60 секунд."""

    def __init__(self, on_chunk, on_level=None, on_failure=None):
        self.on_chunk = on_chunk          # (bytes, index, channels) → в транскрибацию
        self.on_level = on_level          # ([уровни дорожек], index) → индикатор
        self.on_failure = on_failure      # (текст) → авария захвата
        self.proc: subprocess.Popen | None = None
        self.chunks = 0
        self.total_bytes = 0
        self.channels = CHANNELS
        self.chunk_bytes = CHUNK_BYTES
        self._mic = ""
        self._system: str | None = None
        self._retried = False
        # Без сохранённого звука разбирать жалобы на плохую расшифровку нечем,
        # и переделать её тоже нельзя
        self._raw = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._buffer = bytearray()

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self, mic: str, system: str | None, raw_path: str | None = None) -> bool:
        self._mic, self._system = mic, system
        if raw_path and self._raw is None:
            try:
                self._raw = open(raw_path, "wb")
                logging.info("Пишу звук в файл: %s", raw_path)
            except Exception:  # noqa: BLE001
                logging.exception("не удалось открыть файл для звука")
        cmd, self.channels = capture_command(mic, system)
        self.chunk_bytes = SAMPLE_RATE * SAMPLE_WIDTH * self.channels * CHUNK_SECONDS
        logging.info("Запускаю захват: %s", " ".join(cmd))
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE)
        except Exception as e:  # noqa: BLE001
            logging.exception("ffmpeg не запустился")
            if self.on_failure:
                self.on_failure(f"ffmpeg не запустился: {e}")
            return False
        self._stop.clear()
        threading.Thread(target=self._read_audio, daemon=True).start()
        threading.Thread(target=self._read_errors, daemon=True).start()
        return True

    def _read_audio(self) -> None:
        # Мёртвый микрофон однажды стоил целого созвона, поэтому первые
        # секунды проверяются отдельно и захват можно перезапустить
        while True:
            silent_mic = self._pump()
            if not silent_mic or self._stop.is_set():
                break
            if self._retried:
                logging.error("Микрофон «%s» молчит и после перезапуска", self._mic)
                if self.on_failure:
                    self.on_failure(
                        f"Микрофон «{self._mic}» не пишется. Запись идёт, но "
                        "ваши слова в неё не попадают. Проверьте вход звука.")
                break
            self._retried = True
            logging.error("Микрофон «%s» не отдаёт звук, перезапускаю захват",
                          self._mic)
            if not self._restart():
                break

    def _restart(self) -> bool:
        """Заново ищем устройства: их набор мог измениться после старта."""
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        with self._lock:
            self._buffer.clear()
        mic = av_spec(self._mic) or self._mic
        system = None
        if self._system:
            system = av_spec(TAP_DEVICE_NAME) or av_spec(BLACKHOLE_NAME)
        cmd, self.channels = capture_command(mic, system)
        self.chunk_bytes = SAMPLE_RATE * SAMPLE_WIDTH * self.channels * CHUNK_SECONDS
        logging.info("Перезапуск захвата: микрофон «%s», собеседник «%s»", mic, system)
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE)
        except Exception:  # noqa: BLE001
            logging.exception("перезапуск захвата не удался")
            return False
        threading.Thread(target=self._read_errors, daemon=True).start()
        return True

    def _pump(self) -> bool:
        """Читает поток до конца. Возвращает True, если микрофон молчал."""
        stream = self.proc.stdout
        first_data = False
        started = time.time()
        checked = False
        probe = bytearray()
        while not self._stop.is_set():
            data = stream.read(READ_SIZE)
            if not data:
                break
            if not first_data:
                first_data = True
                logging.info("Первые данные со звука через %.1f с", time.time() - started)
            self.total_bytes += len(data)
            if self._raw:
                try:
                    self._raw.write(data)
                except Exception:  # noqa: BLE001
                    logging.exception("запись звука в файл сорвалась")
                    self._raw = None
            if not checked:
                probe.extend(data)
                # Ровный ноль — это не тишина в комнате, а неработающее
                # устройство: живой микрофон всегда даёт хотя бы шум
                if len(probe) >= SAMPLE_RATE * SAMPLE_WIDTH * self.channels * 5:
                    checked = True
                    if levels(bytes(probe), self.channels)[0] <= 0.0:
                        return True
            with self._lock:
                self._buffer.extend(data)
                ready = len(self._buffer) >= self.chunk_bytes
                chunk = None
                if ready:
                    chunk = bytes(self._buffer[:self.chunk_bytes])
                    del self._buffer[:self.chunk_bytes]
            if chunk:
                self._emit(chunk)
        if not first_data and not self._stop.is_set():
            logging.error("Захват не дал ни байта — вероятно завис coreaudiod")
            if self.on_failure:
                self.on_failure("Захват звука не запустился. "
                                "Помогает: sudo killall coreaudiod")
        return False

    def _read_errors(self) -> None:
        for raw in iter(self.proc.stderr.readline, b""):
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                logging.warning("ffmpeg: %s", line)

    def _emit(self, chunk: bytes) -> None:
        self.chunks += 1
        parts = levels(chunk, self.channels)
        seconds = len(chunk) / (SAMPLE_RATE * SAMPLE_WIDTH * self.channels)
        if self.channels > 1:
            logging.info("Чанк %d: %.0f секунд, микрофон %.0f, собеседник %.0f",
                         self.chunks, seconds, parts[0], parts[1])
        else:
            logging.info("Чанк %d: %.0f секунд, уровень %.0f",
                         self.chunks, seconds, parts[0])
        if self.on_level:
            self.on_level(parts, self.chunks)
        self.on_chunk(chunk, self.chunks, self.channels)

    def stop(self) -> None:
        """Останавливаем ffmpeg и отдаём остаток буфера последним чанком."""
        self._stop.set()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        with self._lock:
            tail = bytes(self._buffer)
            self._buffer.clear()
        # Меньше секунды — смысла отправлять нет
        if len(tail) > SAMPLE_RATE * SAMPLE_WIDTH * self.channels:
            self._emit(tail)
        if self._raw:
            try:
                self._raw.close()
            except Exception:  # noqa: BLE001
                pass
            self._raw = None

    @property
    def duration_sec(self) -> int:
        return int(self.total_bytes / (SAMPLE_RATE * SAMPLE_WIDTH * self.channels))
