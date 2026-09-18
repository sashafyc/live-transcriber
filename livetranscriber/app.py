"""Live Transcriber — приложение в строке меню."""

from __future__ import annotations

import logging
import os
import signal
import subprocess
import threading
import time

import rumps

from . import APP_NAME, __version__, audio, config, storage, summarize, telegram, transcribe, windows

ICON_IDLE = "⚪"
ICON_RECORDING = "🔴"
ICON_SILENT = "🔇"
ICON_WORKING = "⏳"

MENU_START = "Начать запись"
MENU_STOP = "Остановить и получить итог"
MENU_HISTORY = "История"
MENU_SOUND = "Проверить звук"
MENU_SETTINGS = "Настройки"
MENU_FOLDER = "Папка с записями"
MENU_QUIT = "Выход"


class LiveTranscriber(rumps.App):
    def __init__(self):
        super().__init__(APP_NAME, title=ICON_IDLE, quit_button=None)
        self.cfg = config.load()
        self.record: storage.Record | None = None
        self.recorder: audio.Recorder | None = None
        self.pipeline: transcribe.ChunkPipeline | None = None
        self.started_at: float | None = None
        self.previous_output: str | None = None
        self.aggregate_id: int | None = None
        self.silent_streak = 0
        self._busy = False
        self._stopping = False
        self._ui_tasks: list = []
        self._ui_lock = threading.Lock()

        self.menu = [
            rumps.MenuItem(MENU_START, callback=self.on_start),
            rumps.MenuItem(MENU_STOP, callback=None),
            None,
            rumps.MenuItem(MENU_HISTORY, callback=self.on_history),
            rumps.MenuItem(MENU_SOUND, callback=self.on_sound_check),
            rumps.MenuItem(MENU_SETTINGS, callback=self.on_settings),
            rumps.MenuItem(MENU_FOLDER, callback=self.on_folder),
            None,
            rumps.MenuItem(f"Версия {__version__}", callback=None),
            rumps.MenuItem(MENU_QUIT, callback=self.on_quit),
        ]

        storage.setup_logging()
        logging.info("=== %s %s запущен ===", APP_NAME, __version__)
        audio.cleanup_stale_aggregates()
        storage.cleanup(self.cfg.get("retention_days", config.RETENTION_DAYS))

        signal.signal(signal.SIGTERM, self._on_signal)
        signal.signal(signal.SIGINT, self._on_signal)
        # Питон получает сигналы только когда у него есть управление,
        # внутри цикла AppKit для этого нужен регулярный тик
        self._ui_timer = rumps.Timer(self._drain_ui, 0.4)
        self._ui_timer.start()
        self._launch_timer = rumps.Timer(self._on_launched, 1.0)
        self._launch_timer.start()

    # ── работа с главным потоком ────────────────────────
    def ui(self, func) -> None:
        """Выполнить в главном потоке: окна нельзя звать из фоновых."""
        with self._ui_lock:
            self._ui_tasks.append(func)

    def _drain_ui(self, _timer) -> None:
        with self._ui_lock:
            tasks, self._ui_tasks = self._ui_tasks, []
        for task in tasks:
            try:
                task()
            except Exception:  # noqa: BLE001
                logging.exception("ошибка в задаче интерфейса")

    def _on_launched(self, timer) -> None:
        timer.stop()
        missing = config.missing_keys(self.cfg)
        if not config.is_configured(self.cfg):
            windows.info(
                "Нужны ключи",
                "Чтобы записывать созвоны, откройте «Настройки» и вставьте свои ключи.\n\n"
                + "\n".join("• " + m for m in missing))
            self.on_settings(None)
            return
        if missing:
            logging.warning("Не заданы: %s", "; ".join(missing))
        if self.cfg.get("show_start_window_on_launch", True):
            self.on_start(None)

    def notify(self, title: str, message: str, subtitle: str = "") -> None:
        try:
            rumps.notification(APP_NAME, subtitle or title, message)
        except Exception:  # noqa: BLE001
            logging.exception("уведомление не показано")

    # ── запуск записи ───────────────────────────────────
    def on_start(self, _sender) -> None:
        if self.recorder and self.recorder.running:
            windows.info("Запись уже идёт", "Сначала остановите текущую запись.")
            return
        if self._busy:
            windows.info("Идёт обработка", "Дождитесь итога прошлой записи.")
            return

        mic = audio.best_mic()
        mic_name = mic[1] if mic else "не найден"
        output_name = audio.current_output() or "не определён"
        blackhole_ok = audio.find_device(audio.BLACKHOLE_NAME) is not None

        def begin(title: str, prompt: str) -> None:
            if not mic:
                windows.info("Микрофон не найден",
                             "Подключите микрофон и проверьте разрешение "
                             "в настройках системы.")
                return
            self._begin_recording(title, prompt, mic[0])

        windows.start_dialog(mic_name, output_name, blackhole_ok,
                             self.cfg.get("prompt", config.DEFAULT_PROMPT),
                             on_start=begin,
                             on_check=lambda: self.on_sound_check(None))

    def _begin_recording(self, title: str, prompt: str, mic_index: str) -> None:
        self.record = storage.Record.create(title, prompt)
        self.record.attach_log()
        logging.info("Начинаю запись «%s» → %s", title, self.record.path)

        # Multi-output: слышим собеседника и одновременно пишем его в BlackHole
        self.previous_output = audio.current_output()
        self.aggregate_id = None
        blackhole_index = None
        if audio.find_device(audio.BLACKHOLE_NAME):
            output_device = next((d for d in audio.devices()
                                  if d["name"] == self.previous_output and d["output"]), None)
            if output_device:
                self.aggregate_id = audio.create_aggregate(output_device["uid"])
            if self.aggregate_id and audio.set_output(audio.AGGREGATE_NAME):
                time.sleep(0.4)
                blackhole_index = audio.av_index(audio.BLACKHOLE_NAME)
            else:
                logging.error("Multi-output не включился: пишем только микрофон")
        if blackhole_index is None:
            self.notify("Пишу только микрофон",
                        "Звук собеседника в запись не попадёт. Проверьте звук в меню.")

        self.pipeline = transcribe.ChunkPipeline(
            self.cfg["assemblyai_key"], self.cfg.get("language", "ru"),
            on_text=self._on_text, on_error=self._on_chunk_error,
            rescue_dir=self.record.path)
        self.recorder = audio.Recorder(on_chunk=self._on_chunk,
                                       on_level=self._on_level,
                                       on_failure=self._on_capture_failure)
        if not self.recorder.start(mic_index, blackhole_index):
            self._restore_audio()
            windows.info("Не удалось начать запись", "Подробности в логе приложения.")
            return

        self.started_at = time.time()
        self.silent_streak = 0
        self._stopping = False
        self.title = ICON_RECORDING
        self.menu[MENU_START].set_callback(None)
        self.menu[MENU_STOP].set_callback(self.on_stop)
        self.notify("Запись идёт", f"«{title}». Остановить — в меню строки состояния.")

    # ── события записи ──────────────────────────────────
    def _on_chunk(self, pcm: bytes, index: int) -> None:
        if self.pipeline:
            self.pipeline.submit(pcm, index)

    def _on_text(self, text: str, index: int) -> None:
        if self.record:
            self.record.append_transcript(text)

    def _on_chunk_error(self, message: str, index: int) -> None:
        if index == 1:
            self.ui(lambda: self.notify("Транскрибация не идёт", message[:180]))

    def _on_level(self, level: float, index: int) -> None:
        # Последний кусок приходит уже после нажатия «Остановить»: значок к тому
        # моменту показывает обработку, и возвращать его в запись нельзя
        if self._stopping or not self.started_at:
            return
        if level < audio.SILENCE_RMS:
            self.silent_streak += 1
            self.ui(lambda: setattr(self, "title", ICON_SILENT))
            if self.silent_streak == 2:
                self.ui(lambda: self.notify(
                    "Две минуты тишины",
                    "Запись идёт, но звука нет. Проверьте микрофон и вывод звука."))
        else:
            self.silent_streak = 0
            self.ui(lambda: setattr(self, "title", ICON_RECORDING))

    def _on_capture_failure(self, message: str) -> None:
        logging.error("Захват сорвался: %s", message)
        self.ui(lambda: self.notify("Захват звука не работает", message))

    # ── остановка и обработка ───────────────────────────
    def on_stop(self, _sender) -> None:
        if not self.recorder:
            return
        self._stopping = True
        self.menu[MENU_STOP].set_callback(None)
        self.title = ICON_WORKING
        self._busy = True
        threading.Thread(target=self._finish, daemon=True).start()

    def _finish(self) -> None:
        record, recorder, pipeline = self.record, self.recorder, self.pipeline
        duration = int(time.time() - (self.started_at or time.time()))
        try:
            recorder.stop()
            self._restore_audio()
            record.write_meta({"duration_sec": duration, "status": "транскрибация"})
            self.ui(lambda: self.notify("Расшифровываю",
                                        "Осталось дождаться последних кусков записи."))
            pipeline.wait()

            transcript = record.transcript()
            body = transcript.split("\n", 1)[1].strip() if "\n" in transcript else ""
            logging.info("Транскрипт: %d символов, чанков %d, ошибок %d, пустых %d",
                         len(body), recorder.chunks, pipeline.failed, pipeline.empty)

            if not body:
                record.write_meta({"status": "пусто"})
                self.ui(lambda: windows.info(
                    "Речи в записи нет",
                    f"Записано {duration // 60} мин, но распознать нечего.\n"
                    "Обычно причина — не тот микрофон или выключенный multi-output.\n"
                    "Проверьте звук через меню."))
                return

            summary = self._make_summary(record, body)
            note = self._send_summary(summary) if summary else ""
            record.write_meta({"status": "готово"})
            if summary:
                self.ui(self._reset_menu)
                self.ui(lambda: self._show_summary(record, summary, note))
        except Exception as e:  # noqa: BLE001
            logging.exception("обработка записи сорвалась")
            self.ui(lambda: windows.info("Обработка не завершилась", str(e)[:300]))
        finally:
            storage.Record.detach_log()
            self.record = None
            self.recorder = None
            self.pipeline = None
            self.started_at = None
            self._busy = False
            self._stopping = False
            self.ui(self._reset_menu)

    def _make_summary(self, record: storage.Record, body: str) -> str:
        try:
            summary = summarize.summarize(body, self.cfg.get("deepseek_key", ""),
                                          record.meta().get("prompt")
                                          or config.DEFAULT_PROMPT)
            record.write_summary(summary)
            logging.info("Итог готов: %d символов", len(summary))
            return summary
        except Exception as e:  # noqa: BLE001
            logging.exception("саммари не получилось")
            self.ui(lambda: windows.info(
                "Итог не составлен",
                f"{e}\n\nТранскрипт сохранён, его можно открыть через «История»."))
            return ""

    def _send_summary(self, summary: str) -> str:
        if not self.cfg.get("send_to_telegram", True):
            return "Отправка в Telegram выключена в настройках"
        try:
            telegram.send(summary, self.cfg.get("telegram_token", ""),
                          self.cfg.get("telegram_chat", ""))
            return "Отправлено в Telegram"
        except Exception as e:  # noqa: BLE001
            logging.exception("в Telegram не ушло")
            return f"В Telegram не ушло: {e}"[:120]

    def _show_summary(self, record: storage.Record, summary: str, note: str) -> None:
        def send_again() -> None:
            self.notify("Отправка", self._send_summary(summary))

        windows.summary_window(
            record.title, summary, record.path, note,
            on_send=send_again,
            on_copy=lambda: self.notify("Скопировано", "Итог в буфере обмена"))

    def _restore_audio(self) -> None:
        if self.previous_output:
            audio.set_output(self.previous_output)
            self.previous_output = None
        if self.aggregate_id:
            audio.destroy_aggregate(self.aggregate_id)
            self.aggregate_id = None

    def _reset_menu(self) -> None:
        self.title = ICON_IDLE
        self.menu[MENU_START].set_callback(self.on_start)
        self.menu[MENU_STOP].set_callback(None)

    # ── прочие пункты меню ──────────────────────────────
    def on_history(self, _sender) -> None:
        windows.history_window(storage.Record.list_all(),
                               self.cfg.get("retention_days", config.RETENTION_DAYS))

    def on_sound_check(self, _sender) -> None:
        self.notify("Проверяю звук", "Займёт несколько секунд")

        def work():
            report = audio.check()
            self.ui(lambda: windows.audio_report_window(report))

        threading.Thread(target=work, daemon=True).start()

    def on_settings(self, _sender) -> None:
        def check(values: dict) -> str:
            lines = []
            ok, message = transcribe.check_key(values.get("assemblyai_key", ""))
            lines.append(f"{'✅' if ok else '❌'} AssemblyAI: {message}")
            ok, message = summarize.check_key(values.get("deepseek_key", ""))
            lines.append(f"{'✅' if ok else '❌'} DeepSeek: {message}")
            ok, message = telegram.check(values.get("telegram_token", ""),
                                         values.get("telegram_chat", ""))
            lines.append(f"{'✅' if ok else '❌'} Telegram: {message}")
            return "\n".join(lines)

        values = windows.settings_window(self.cfg, check)
        if values is None:
            return
        self.cfg.update(values)
        config.save(self.cfg)
        logging.info("Настройки сохранены (ключи: assembly=%s, deepseek=%s, tg=%s)",
                     config.mask(self.cfg.get("assemblyai_key", "")),
                     config.mask(self.cfg.get("deepseek_key", "")),
                     config.mask(self.cfg.get("telegram_token", "")))
        self.notify("Настройки сохранены", "")

    def on_folder(self, _sender) -> None:
        os.makedirs(config.RECORDS_DIR, exist_ok=True)
        subprocess.Popen(["open", config.RECORDS_DIR])

    # ── завершение ──────────────────────────────────────
    def _on_signal(self, signum, _frame) -> None:
        logging.info("Сигнал %d — завершаюсь", signum)
        self.on_quit(None)

    def on_quit(self, _sender) -> None:
        try:
            if self.recorder and self.recorder.running:
                self.recorder.stop()
        except Exception:  # noqa: BLE001
            logging.exception("не удалось остановить запись при выходе")
        finally:
            self._restore_audio()
            audio.cleanup_stale_aggregates()
            logging.info("=== %s остановлен ===", APP_NAME)
            rumps.quit_application()


def main() -> None:
    LiveTranscriber().run()


if __name__ == "__main__":
    main()
