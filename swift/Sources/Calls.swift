import AppKit
import Observation
import UserNotifications

/// Запись созвона целиком: старт, захват, расшифровка кусками, итог, Telegram.
@Observable final class Calls {
    enum State: Equatable {
        case idle, recording, silent, processing

        var symbol: String? {
            switch self {
            case .idle: nil
            case .recording: "record.circle.fill"
            case .silent: "mic.slash"
            case .processing: "hourglass"
            }
        }
    }

    private(set) var state = State.idle
    private(set) var title = ""
    private let settings: AppSettings
    @ObservationIgnored private var capture: CallCapture?
    @ObservationIgnored private var pipeline: CallPipeline?
    @ObservationIgnored private var record: CallRecord?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var silentStreak = 0
    @ObservationIgnored private var quietOther = 0

    init(settings: AppSettings) {
        self.settings = settings
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            // Сырой звук останется на диске, ответвление уберётся вместе с процессом
            self?.capture?.stop()
        }
        CallRecord.cleanup()
    }

    // MARK: Старт

    func openStart() {
        guard state == .idle else {
            return Windows.info("Запись уже идёт", state == .processing ? "Дождитесь итога прошлой записи." : "Сначала остановите текущую запись.")
        }
        let output = AudioDevices.defaultOutput()?.name ?? "не определён"
        Windows.show("start", "Новая запись", StartCallView(
            mic: AudioDevices.bestMic()?.name ?? "не найден", output: output, prompt: settings.callPrompt,
            onStart: { [weak self] title, prompt, external in
                Windows.close("start")
                self?.begin(title: title, prompt: prompt, external: external)
            },
            onCheck: { [weak self] in
                Windows.close("start")
                self?.checkSound()
            }))
    }

    private func begin(title: String, prompt: String, external: Bool) {
        // Набор устройств мог измениться, пока было открыто окно: микрофон ищем прямо перед запуском
        guard let mic = AudioDevices.bestMic() else {
            return Windows.info("Микрофон не найден", "Подключите микрофон и проверьте разрешение в настройках системы.")
        }
        do {
            let record = try CallRecord.create(title: title, prompt: prompt)
            Log.attach(record)
            Log.info("Начинаю запись «\(title)» → \(record.id)\(external ? " (внешний созвон, только микрофон)" : "")")
            Log.info("Распознавание: \(settings.calls.provider.title) \(settings.calls.model) \(settings.calls.language)")
            let capture = try CallCapture(mic: mic, external: external, raw: record.rawURL)
            let pipeline = CallPipeline(
                setup: settings.calls, solo: external ? CallTranscriber.me : nil, rescueDir: record.url,
                onText: { record.appendTranscript($0) },
                onError: { [weak self] message, index in
                    if index == 1 { DispatchQueue.main.async { self?.notify("Расшифровка не идёт", String(message.prefix(180))) } }
                })
            capture.onChunk = { pipeline.submit($0, index: $1, channels: capture.channels) }
            capture.onLevels = { [weak self] levels, _ in DispatchQueue.main.async { self?.levels(levels) } }
            capture.onFailure = { [weak self] message in
                Log.error("Захват сорвался: \(message)")
                DispatchQueue.main.async { self?.notify("Захват звука не работает", message) }
            }
            try capture.start()
            if capture.systemMissing, !external {
                notify("Пишу только микрофон", "Звук собеседника в запись не попадёт. Проверьте звук в меню.")
            }
            self.record = record
            self.capture = capture
            self.pipeline = pipeline
            self.title = title
            started = Date()
            silentStreak = 0
            quietOther = 0
            state = .recording
            notify("Запись идёт", "«\(title)». Остановить — в меню строки состояния.")
        } catch {
            Log.error("Запись не началась: \(error.localizedDescription)")
            Log.attach(nil)
            Windows.info("Не удалось начать запись", error.localizedDescription)
        }
    }

    private func levels(_ levels: [Double]) {
        guard state == .recording || state == .silent else { return }  // последний кусок приходит уже после «Остановить»
        if levels[0] < CallAudio.silence {
            silentStreak += 1
            state = .silent
            if silentStreak == 2 { notify("Две минуты тишины", "Запись идёт, но микрофон молчит. Проверьте вход звука.") }
        } else {
            silentStreak = 0
            state = .recording
        }
        // Отказ в разрешении на звук системы выглядит как обычная тишина: ошибки нет, просто пустая дорожка
        guard levels.count > 1 else { return }
        quietOther = levels[1] < CallAudio.silence ? quietOther + 1 : 0
        if quietOther == 2 {
            notify("Собеседника не слышно", "Разрешите запись звука системы: Конфиденциальность и безопасность → Запись экрана и звука системы.")
        }
    }

    // MARK: Остановка и итог

    func stop() {
        guard let capture, let pipeline, let record else { return }
        state = .processing
        let duration = Int(Date().timeIntervalSince(started))
        Task { @MainActor in
            await Task.detached { capture.stop() }.value
            record.writeMeta(["duration_sec": duration, "status": "транскрибация"])
            let channels = capture.channels
            Task.detached { Self.keepAudio(record, channels: channels) }
            notify("Расшифровываю", "Осталось дождаться последних кусков записи.")
            await pipeline.wait()
            let body = record.transcriptBody
            Log.info("Транскрипт: \(body.count) символов, кусков \(capture.chunks), ошибок \(pipeline.failed), пустых \(pipeline.empty)")
            if body.isEmpty {
                record.writeMeta(["status": "пусто"])
                Windows.info("Речи в записи нет", "Записано \(duration / 60) мин, но распознать нечего.\nПроверьте звук через меню.")
            } else if let summary = await summarize(record, body) {
                var note = await deliver(summary)
                // За минуту разговора набирается несколько сотен символов: меньше — расшифровка неполная
                if Double(body.count) / max(1, Double(duration) / 60) < 200 {
                    Log.error("Расшифровка редкая: \(body.count) символов за \(duration / 60) мин")
                    note += "\nРасшифровка вышла неполной. Через «Историю созвонов» её можно переделать целиком из сохранённой записи."
                }
                record.writeMeta(["status": "готово"])
                showSummary(record, summary, note)
            }
            finish()
        }
    }

    private func finish() {
        Log.attach(nil)
        capture = nil
        pipeline = nil
        record = nil
        title = ""
        state = .idle
    }

    /// Звук записи — для разбора жалоб и «Расшифровать заново».
    private static func keepAudio(_ record: CallRecord, channels: Int) {
        if let handle = try? FileHandle(forReadingFrom: record.rawURL),
           let data = try? handle.read(upToCount: CallAudio.rate * channels * 2 * 600) {
            let sample = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            for channel in 0..<channels {
                Log.info("Звука на дорожке «\(channel == 0 ? "микрофон" : "собеседник")»: "
                    + "\(Int(100 * CallAudio.speechShare(sample, channels: channels, channel: channel)))% времени")
            }
            try? handle.close()
        }
        do {
            try CallAudio.compress(raw: record.rawURL, to: record.audioURL, channels: channels)
            Log.info("Звук записи сохранён: audio.flac")
        } catch {
            Log.error("Сжатие звука не удалось, остался audio.raw: \(error.localizedDescription)")
        }
    }

    private func summarize(_ record: CallRecord, _ body: String) async -> String? {
        do {
            let summary = try await Summary.make(body, prompt: record.prompt)
            record.writeSummary(summary)
            Log.info("Итог готов: \(summary.count) символов")
            return summary
        } catch {
            Log.error("Итог не получился: \(error.localizedDescription)")
            Windows.info("Итог не составлен", "\(error.localizedDescription)\n\nРасшифровка сохранена, её можно открыть в «Истории созвонов».")
            return nil
        }
    }

    func deliver(_ summary: String) async -> String {
        guard settings.sendToTelegram else { return "Отправка в Telegram выключена в настройках" }
        do {
            try await Telegram.send(summary, chat: settings.telegramChat)
            return "Отправлено в Telegram"
        } catch {
            Log.error("В Telegram не ушло: \(error.localizedDescription)")
            return String("В Telegram не ушло: \(error.localizedDescription)".prefix(160))
        }
    }

    func showSummary(_ record: CallRecord, _ summary: String, _ note: String) {
        Windows.show("summary-\(record.id)", "Итог — \(record.title)", SummaryView(
            summary: summary, note: note, folder: record.url,
            onSend: { [weak self] in
                guard let self else { return "" }
                do {
                    try await Telegram.send(summary, chat: settings.telegramChat)
                    return "Отправлено в Telegram"
                } catch {
                    return error.localizedDescription
                }
            }))
    }

    // MARK: Заново, звук

    /// Запись уходит одним куском, а не минутными отрезками: голоса разбираются по всей записи сразу.
    func redo(_ record: CallRecord) {
        guard state == .idle else { return Windows.info("Идёт обработка", "Дождитесь конца текущей работы.") }
        state = .processing
        title = record.title
        notify("Расшифровываю заново", "Запись уходит целиком, это дольше обычного.")
        let setup = settings.calls
        Task { @MainActor in
            do {
                let (pcm, channels) = try await Task.detached { try CallAudio.read(record.audioURL) }.value
                // Моно — это дорожка микрофона: так пишется внешний созвон
                let text = try await CallTranscriber.transcribe(pcm, channels: channels, setup: setup,
                                                                solo: channels == 1 ? CallTranscriber.me : nil, wholeRecording: true)
                if text.isEmpty {
                    Windows.info("Речи не нашлось", "Повторная расшифровка ничего не дала.")
                } else {
                    record.replaceTranscript(text)
                    Log.info("Запись \(record.id) расшифрована заново: \(text.count) символов")
                    if let summary = await summarize(record, text) {
                        record.writeMeta(["status": "готово"])
                        showSummary(record, summary, "Расшифровано заново, одним куском")
                    }
                }
            } catch {
                Log.error("Переделать расшифровку не вышло: \(error.localizedDescription)")
                Windows.info("Не получилось", error.localizedDescription)
            }
            title = ""
            state = .idle
        }
    }

    func checkSound() {
        notify("Проверяю звук", "Займёт несколько секунд")
        Task { @MainActor in
            let report = await Task.detached { CallCapture.soundCheck() }.value
            Windows.show("sound", report.ok ? "Звук в порядке" : "Со звуком есть проблемы", SoundReportView(report: report))
        }
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Без делегата macOS не показывает уведомления, пока приложение активно.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
