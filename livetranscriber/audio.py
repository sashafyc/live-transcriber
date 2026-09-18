"""Аудио: устройства CoreAudio, проверка потоков, захват через ffmpeg.

Правило этого модуля: никаких subprocess(text=True). В .app-бандле локаль
US-ASCII, и любое не-ASCII имя устройства («Александр's AirPods Pro») роняет
декодирование. Везде bytes + decode('utf-8', errors='replace').
"""

from __future__ import annotations

import array
import ctypes
import logging
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

# Тишиной считаем чанк с RMS ниже порога. amix делит громкость пополам,
# поэтому порог низкий.
SILENCE_RMS = 15

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
    """Громкость куска PCM s16le. Шаг 4 сэмпла — точности достаточно."""
    if not pcm:
        return 0.0
    samples = array.array("h")
    samples.frombytes(pcm[:len(pcm) // 2 * 2])
    if not samples:
        return 0.0
    step = 4 if len(samples) > 4000 else 1
    chosen = samples[::step]
    return (sum(s * s for s in chosen) / len(chosen)) ** 0.5


# ── CoreAudio ───────────────────────────────────────────
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
    candidates = [(idx, name) for idx, name in av_inputs()
                  if BLACKHOLE_NAME not in name
                  and AGGREGATE_NAME not in name
                  and not is_continuity_mic(name)]
    if not candidates:
        return None
    for idx, name in candidates:
        if "MacBook" not in name and "Built" not in name:
            return idx, name
    return candidates[0]


def capture_command(mic_index: str, blackhole_index: str | None) -> list[str]:
    """ffmpeg: микрофон (+ системный звук) → mono PCM 16 кГц в stdout."""
    tool = which("ffmpeg") or "ffmpeg"
    cmd = [tool, "-y", "-nostats", "-loglevel", "warning",
           "-f", "avfoundation", "-i", f":{mic_index}"]
    if blackhole_index is not None:
        cmd += ["-f", "avfoundation", "-i", f":{blackhole_index}",
                "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest[out]",
                "-map", "[out]"]
    cmd += ["-f", "s16le", "-acodec", "pcm_s16le",
            "-ar", str(SAMPLE_RATE), "-ac", str(CHANNELS), "pipe:1"]
    return cmd


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

    # Системный звук: включаем multi-output, играем тон, слушаем BlackHole
    add("")
    previous = current_output()
    aggregate_id = None
    try:
        out_dev = next((d for d in devs if d["name"] == previous and d["output"]), None)
        if out_dev:
            aggregate_id = create_aggregate(out_dev["uid"])
        if aggregate_id and set_output(AGGREGATE_NAME):
            time.sleep(0.4)
            bh_index = av_index(BLACKHOLE_NAME)
            tone = play_tone(2.5)
            level = probe(bh_index, 2.0) if bh_index else -1.0
            if tone:
                tone.terminate()
            if level < 0:
                add("❌ Системный звук: BlackHole не отдаёт данные")
                report["problems"].append("BlackHole не отдаёт звук")
                report["ok"] = False
            elif level < SILENCE_RMS:
                add(f"⚠️ Системный звук не доходит до BlackHole (уровень {level:.0f})")
                report["problems"].append(
                    "звук собеседника не пишется: multi-output не работает")
                report["ok"] = False
            else:
                add(f"✅ Системный звук идёт в запись (уровень {level:.0f})")
        else:
            add("❌ Не удалось включить multi-output (LT-Auto)")
            report["problems"].append("не создаётся multi-output: звук собеседника не пишется")
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
        self.on_chunk = on_chunk          # (bytes, index) → отправка в транскрибацию
        self.on_level = on_level          # (rms, index) → индикатор тишины
        self.on_failure = on_failure      # (текст) → авария захвата
        self.proc: subprocess.Popen | None = None
        self.chunks = 0
        self.total_bytes = 0
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._buffer = bytearray()

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self, mic_index: str, blackhole_index: str | None) -> bool:
        cmd = capture_command(mic_index, blackhole_index)
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
        stream = self.proc.stdout
        first_data = False
        started = time.time()
        while not self._stop.is_set():
            data = stream.read(READ_SIZE)
            if not data:
                break
            if not first_data:
                first_data = True
                logging.info("Первые данные с микрофона через %.1f с", time.time() - started)
            self.total_bytes += len(data)
            with self._lock:
                self._buffer.extend(data)
                ready = len(self._buffer) >= CHUNK_BYTES
                chunk = None
                if ready:
                    chunk = bytes(self._buffer[:CHUNK_BYTES])
                    del self._buffer[:CHUNK_BYTES]
            if chunk:
                self._emit(chunk)
        if not first_data and not self._stop.is_set():
            logging.error("Захват не дал ни байта — вероятно завис coreaudiod")
            if self.on_failure:
                self.on_failure("Захват звука не запустился. "
                                "Помогает: sudo killall coreaudiod")

    def _read_errors(self) -> None:
        for raw in iter(self.proc.stderr.readline, b""):
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                logging.warning("ffmpeg: %s", line)

    def _emit(self, chunk: bytes) -> None:
        self.chunks += 1
        level = rms(chunk)
        logging.info("Чанк %d: %.0f секунд, уровень %.0f",
                     self.chunks, len(chunk) / (SAMPLE_RATE * SAMPLE_WIDTH), level)
        if self.on_level:
            self.on_level(level, self.chunks)
        self.on_chunk(chunk, self.chunks)

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
        if len(tail) > SAMPLE_RATE * SAMPLE_WIDTH:
            self._emit(tail)

    @property
    def duration_sec(self) -> int:
        return int(self.total_bytes / (SAMPLE_RATE * SAMPLE_WIDTH * CHANNELS))
