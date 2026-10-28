import AVFoundation
import CoreAudio

/// Запись созвона: микрофон левой дорожкой, системный звук правой, режется на куски по минуте.
/// Дорожки, а не смесь: расшифровка получает `multichannel` и не гадает, кто говорит.
/// Все колбэки приходят в собственной очереди записи.
final class CallCapture {
    static let rate = 16000
    static let chunkSeconds = 60

    let channels: Int
    var onChunk: ([Int16], Int) -> Void = { _, _ in }
    var onLevels: ([Double], Int) -> Void = { _, _ in }
    var onFailure: (String) -> Void = { _ in }
    private(set) var chunks = 0
    private(set) var frames = 0
    let micName: String

    private let queue = DispatchQueue(label: "call-capture")
    private let micUID: String
    private var mic: DeviceStream?
    private var system: DeviceStream?
    private var tap: SystemTap?
    private var micTrack = Track()
    private var systemTrack = Track()
    /// Общая шкала времени дорожек: момент старта записи по часам Core Audio.
    private var origin: UInt64 = 0
    private var checkFrom = Date()
    private var micPeak: Float = 0
    private var micSamples = 0
    private var checked = false
    private var retried = false
    private var chunk: [Int16] = []
    private var raw: FileHandle?
    private var timer: DispatchSourceTimer?

    /// Дорожка на шкале времени. Устройства стартуют вразнобой, а ответвление отдаёт звук,
    /// только пока что-то играет: каждый кусок кладётся туда, где он прозвучал, по метке
    /// времени, а пропуски заполняются тишиной. Так дорожки не разъезжаются, и глушение
    /// собеседника в микрофоне попадает в те же кадры.
    private struct Track {
        var pending: [Int16] = []
        var end = 0  // позиция конца дорожки в отсчётах от начала записи

        mutating func place(_ samples: [Int16], at position: Int) {
            var samples = samples
            if position > end + CallCapture.rate / 100 {
                pad(to: position)  // пропуск больше 10 мс
            } else if position < end - CallCapture.rate / 10, end - position < samples.count {
                samples.removeFirst(end - position)  // кусок наложился на уже дописанную тишину
            }
            pending += samples
            end += samples.count
        }

        mutating func pad(to position: Int) {
            guard position > end else { return }
            pending += [Int16](repeating: 0, count: position - end)
            end = position
        }
    }

    /// `external` — внешний созвон: разговор идёт мимо компьютера, пишем только микрофон.
    /// На пустой второй дорожке распознавание сочиняет титры переводчиков.
    init(mic device: AudioDevice, external: Bool, raw rawURL: URL) throws {
        micName = device.name
        micUID = device.uid
        if !external {
            do {
                tap = try SystemTap()
            } catch {
                Log.error("Собеседник писаться не будет: \(error.localizedDescription)")
            }
        }
        channels = tap == nil ? 1 : 2
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        raw = try? FileHandle(forWritingTo: rawURL)
        mic = try micStream(device.id)
        if let tap {
            system = try DeviceStream(device: tap.deviceID, take: .lastBufferMix, queue: queue) { [weak self] samples, nanos, _ in
                guard let self else { return }
                systemTrack.place(samples, at: position(nanos))
            }
        }
    }

    var systemMissing: Bool { channels == 1 }

    private func micStream(_ device: AudioObjectID) throws -> DeviceStream {
        try DeviceStream(device: device, take: .firstChannel, queue: queue) { [weak self] samples, nanos, peak in
            guard let self else { return }
            if micSamples == 0 { Log.info(String(format: "Микрофон пошёл через %.1f с", Double(Int64(nanos) - Int64(origin)) / 1e9)) }
            micTrack.place(samples, at: position(nanos))
            micSamples += samples.count
            micPeak = max(micPeak, peak)
        }
    }

    private func position(_ nanos: UInt64) -> Int {
        Int(Double(Int64(nanos) - Int64(origin)) / 1e9 * Double(Self.rate))
    }

    private var now: UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }

    func start() throws {
        queue.sync { origin = now }
        do {
            try mic?.start()
            try system?.start()
        } catch {
            release()
            throw error
        }
        Log.info("Пишу микрофон «\(micName)»\(channels == 2 ? " и собеседника через ответвление" : ", без собеседника")")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Останавливает захват и отдаёт остаток последним куском.
    func stop() {
        queue.sync {
            timer?.cancel()
            release()
            tick(final: true)
            if chunk.count > Self.rate * channels { send(chunk) }  // меньше секунды отправлять незачем
            chunk = []
            try? raw?.close()
            raw = nil
        }
    }

    private func release() {
        mic?.stop()
        system?.stop()
        tap?.destroy()
        mic = nil
        system = nil
        tap = nil
    }

    private func tick(final: Bool = false) {
        if !final, !checked, Date().timeIntervalSince(checkFrom) >= 5 { checkMic() }
        // Что не пришло за секунду, уже не придёт: молчащее ответвление или заглохший микрофон
        // дописываются тишиной, иначе одна дорожка остановит всю запись
        let settled = final ? max(micTrack.end, systemTrack.end) : position(now) - Self.rate
        micTrack.pad(to: settled)
        guard channels == 2 else {
            emit(micTrack.pending)
            micTrack.pending = []
            return
        }
        systemTrack.pad(to: settled)
        let count = min(micTrack.pending.count, systemTrack.pending.count)
        guard count > 0 else { return }
        var stereo = [Int16](repeating: 0, count: count * 2)
        for index in 0..<count {
            stereo[index * 2] = micTrack.pending[index]
            stereo[index * 2 + 1] = systemTrack.pending[index]
        }
        micTrack.pending.removeFirst(count)
        systemTrack.pending.removeFirst(count)
        emit(stereo)
    }

    /// Ровный ноль — поломка, а не тишина: живой микрофон всегда даёт хотя бы шум.
    /// Один раз перезапускаем микрофон, заново найдя его по UID: набор устройств мог измениться.
    private func checkMic() {
        checked = true
        guard micSamples == 0 || micPeak == 0 else { return }
        if retried {
            Log.error("Микрофон «\(micName)» молчит и после перезапуска")
            onFailure(micSamples == 0 ? "Захват звука не запустился. Помогает: sudo killall coreaudiod"
                : "Микрофон «\(micName)» не пишется. Запись идёт, но ваши слова в неё не попадают. Проверьте вход звука.")
            return
        }
        retried = true
        Log.error("Микрофон «\(micName)» не отдаёт звук (\(micSamples) отсчётов), перезапускаю")
        mic?.stop()
        let devices = AudioDevices.all()
        guard let device = devices.first(where: { $0.uid == micUID && $0.isMic }) ?? AudioDevices.bestMic() else {
            return onFailure("Микрофон пропал. Подключите его и начните запись заново.")
        }
        do {
            mic = try micStream(device.id)
            try mic?.start()
            Log.info("Микрофон перезапущен: «\(device.name)»")
        } catch {
            Log.error("Перезапуск микрофона не удался: \(error.localizedDescription)")
        }
        micPeak = 0
        micSamples = 0
        checked = false
        checkFrom = Date()
    }

    private func emit(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        frames += samples.count / channels
        // Без сохранённого звука жалобы на расшифровку разбирать нечем, и переделать её нельзя
        samples.withUnsafeBytes { try? raw?.write(contentsOf: Data($0)) }
        chunk += samples
        let size = Self.rate * Self.chunkSeconds * channels
        while chunk.count >= size {
            send(Array(chunk[..<size]))
            chunk.removeFirst(size)
        }
    }

    private func send(_ part: [Int16]) {
        chunks += 1
        let levels = CallAudio.levels(part, channels: channels)
        let seconds = part.count / channels / Self.rate
        Log.info("Кусок \(chunks): \(seconds) с, " + (channels == 2
            ? "микрофон \(Int(levels[0])), собеседник \(Int(levels[1]))" : "уровень \(Int(levels[0]))"))
        onLevels(levels, chunks)
        onChunk(part, chunks)
    }

    var seconds: Int { frames / Self.rate }
}

/// «Проверить звук»: слышит ли микрофон и доходит ли звук собеседника.
struct SoundReport {
    var ok = true
    var problems: [String] = []
    var lines: [String] = []
}

extension CallCapture {
    static func soundCheck() -> SoundReport {
        var report = SoundReport()
        let devices = AudioDevices.all()
        report.lines.append("Входы: " + devices.filter(\.hasInput).map(\.name).joined(separator: ", "))
        report.lines.append("Выход: \(AudioDevices.defaultOutput()?.name ?? "не определён")")
        report.lines.append("")
        guard let mic = AudioDevices.bestMic() else {
            report.ok = false
            report.problems.append("нет микрофона")
            report.lines.append("❌ Микрофон не найден")
            return report
        }
        report.lines.append("Микрофон: \(mic.name)")
        let level = listen(mic.id, .firstChannel)
        if level < 0 {
            report.ok = false
            report.problems.append("микрофон не отдаёт звук: проверь разрешение и устройство")
            report.lines.append("❌ Микрофон не отдаёт звук")
        } else if level < CallAudio.deadMic {
            report.ok = false
            report.problems.append("микрофон молчит: проверь, не выключен ли он")
            report.lines.append("⚠️ Микрофон молчит (уровень \(Int(level)))")
        } else {
            report.lines.append("✅ Микрофон слышит (уровень \(Int(level)))")
        }

        report.lines.append("")
        do {
            let tap = try SystemTap()
            defer { tap.destroy() }
            let tone = playTone()
            let level = listen(tap.deviceID, .lastBufferMix)
            tone?.stop()
            if level < 0 {
                report.ok = false
                report.problems.append("ответвление звука не отдаёт данные")
                report.lines.append("❌ Звук собеседника: устройство записи не отдаёт данные")
            } else if level < CallAudio.silence {
                report.ok = false
                report.problems.append("нет разрешения на запись звука системы")
                report.lines += ["❌ Звук собеседника не пишется",
                                 "   Разрешите запись звука системы: Системные настройки →",
                                 "   Конфиденциальность и безопасность → Запись экрана и звука системы"]
            } else {
                report.lines += ["✅ Звук собеседника пишется (уровень \(Int(level)))",
                                 "   Выход звука при этом не переключается"]
            }
        } catch {
            report.ok = false
            report.problems.append("ответвление звука не создано")
            report.lines.append("❌ \(error.localizedDescription)")
        }
        return report
    }

    /// Две секунды с устройства → громкость; −1, если не пришло ни отсчёта.
    private static func listen(_ device: AudioObjectID, _ take: DeviceStream.Take) -> Double {
        let queue = DispatchQueue(label: "sound-check")
        var samples: [Int16] = []
        guard let stream = try? DeviceStream(device: device, take: take, queue: queue, onSamples: { part, _, _ in samples += part }),
              (try? stream.start()) != nil else { return -1 }
        Thread.sleep(forTimeInterval: 0.4)
        queue.sync { samples = [] }  // начало бывает пустым, пока устройство просыпается
        Thread.sleep(forTimeInterval: 2)
        stream.stop()
        return queue.sync { samples.isEmpty ? -1 : CallAudio.levels(samples, channels: 1)[0] }
    }

    /// Тон 440 Гц в текущий выход — по нему видно, доходит ли звук до ответвления.
    private static func playTone() -> AVAudioPlayer? {
        let rate = 44100, count = rate * 3
        var wav = Data("RIFF".utf8)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { wav += $0 } }
        append(UInt32(36 + count * 2)); wav += Data("WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16)); wav += Data("data".utf8); append(UInt32(count * 2))
        for index in 0..<count { append(Int16(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 6000).littleEndian) }
        let player = try? AVAudioPlayer(data: wav)
        player?.play()
        return player
    }
}

extension CallCapture {
    /// Проверки без окон. Запускать через `open -n`, иначе разрешение на звук системы спросят у терминала:
    /// `--sound-check <отчёт>`, `--record-test <секунды> <папка>`, `--transcribe <audio.flac> <вывод>`,
    /// `--summarize <transcript.md> <вывод>`, `--check-keys <вывод>` (Telegram только getMe, в чат не пишет).
    static func checkFromCommandLine() {
        let arguments = CommandLine.arguments
        let modes = ["--sound-check", "--record-test", "--transcribe", "--summarize", "--check-keys"]
        guard arguments.count >= 3, modes.contains(arguments[1]) else { return }
        let out = URL(fileURLWithPath: arguments.last!)
        var lines: [String] = []
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            switch arguments[1] {
            case "--sound-check":
                let report = soundCheck()
                lines = report.problems + report.lines
            case "--record-test":
                let seconds = Double(arguments[2]) ?? 10
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                do {
                    guard let mic = AudioDevices.bestMic() else { throw TranscriptionError("нет микрофона") }
                    let capture = try CallCapture(mic: mic, external: false, raw: out.appendingPathComponent("audio.raw"))
                    capture.onLevels = { levels, index in lines.append("кусок \(index): \(levels.map { Int($0) })") }
                    try capture.start()
                    try? await Task.sleep(for: .seconds(seconds))
                    capture.stop()
                    try CallAudio.compress(raw: out.appendingPathComponent("audio.raw"), to: out.appendingPathComponent("audio.flac"),
                                           channels: capture.channels)
                    lines.append("дорожек \(capture.channels), секунд \(capture.seconds)")
                } catch {
                    lines.append("ОШИБКА: \(error.localizedDescription)")
                }
                lines.append(contentsOf: ["", "смотри: " + out.appendingPathComponent("audio.flac").path])
            case "--summarize":
                do {
                    let text = try String(contentsOfFile: arguments[2], encoding: .utf8)
                    lines.append(try await Summary.make(text, prompt: AppSettings().callPrompt))
                } catch {
                    lines.append("ОШИБКА: \(error.localizedDescription)")
                }
            case "--check-keys":
                lines.append(await Summary.checkKey())
                lines.append(await Telegram.check(chat: AppSettings().telegramChat))
            default:
                do {
                    let (pcm, channels) = try CallAudio.read(URL(fileURLWithPath: arguments[2]))
                    let setup = AppSettings().calls
                    lines.append(try await CallTranscriber.transcribe(pcm, channels: channels, setup: setup,
                                                                      solo: channels == 1 ? CallTranscriber.me : nil, wholeRecording: true))
                } catch {
                    lines.append("ОШИБКА: \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
        let text = lines.joined(separator: "\n") + "\n"
        if arguments[1] == "--record-test" {
            try? text.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        } else {
            try? text.write(to: out, atomically: true, encoding: .utf8)
        }
        exit(0)
    }
}
