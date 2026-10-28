import AppKit
import AVFoundation
import Observation

/// Держишь клавишу — пишет микрофон, отпустил — текст распознаётся и вставляется туда, где курсор.
@Observable final class Dictation {
    enum State: Equatable {
        case idle, recording, sending, formatting
        case failed(String)

        var symbol: String {
            switch self {
            case .idle: "waveform"
            case .recording: "mic.fill"
            case .sending, .formatting: "ellipsis.circle"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    private(set) var state = State.idle {
        didSet { hud.update(for: state) }
    }
    /// Громкость последних мгновений записи, 0…1 — для волны на плашке.
    private(set) var levels = [Float](repeating: 0, count: 20)
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private let settings: AppSettings
    private let history: History
    private var recorder: ChunkedRecorder?
    /// Куски текущей диктовки, распознаваемые на лету.
    private var parts: [Task<String, Error>] = []
    private var recordingID = UUID()
    private var recordStarted = Date()
    @ObservationIgnored private var hud: RecordingHUD!

    init(settings: AppSettings, history: History) {
        self.settings = settings
        self.history = history
        hud = RecordingHUD(dictation: self)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        waitForAccessibility()
    }

    /// Глобальные события клавиатуры приходят только с Универсальным доступом: ждём его без перезапуска.
    private func waitForAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.waitForAccessibility() }
            return
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] in self?.handle($0) }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] in
            self?.handle($0)
            return $0
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if recorder != nil { cancel() }  // клавиша-модификатор с буквой — это сочетание, а не диктовка
            return
        }
        let hotkey = settings.hotkey
        guard event.keyCode == hotkey.code else { return }
        if event.modifierFlags.contains(hotkey.flag) { start() } else { stop() }
    }

    private func start() {
        guard recorder == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return fail("Нет доступа к микрофону")
        }
        recordingID = UUID()
        parts = []
        let recorder = ChunkedRecorder(onLevel: { [weak self] decibels in
            // речь обычно −45…−10 дБ
            self?.levels.removeFirst()
            self?.levels.append(max(0, min(1, (decibels + 50) / 40)))
        }, onChunk: { [weak self] chunk in self?.sendPart(chunk) })
        do {
            try recorder.start()
            self.recorder = recorder
            recordStarted = Date()
            levels = levels.map { _ in 0 }
            state = .recording
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func sendPart(_ chunk: Segmenter.Chunk) {
        let setup = settings.dictation, number = parts.count + 1, sent = Date()
        parts.append(Task {
            let text = try await Transcriber.transcribe(chunk, setup)
            Log.info(String(format: "Диктовка: кусок %d, %.1f с звука, распознан за %.1f с", number,
                            Double(chunk.samples.count) / Segmenter.rate, Date().timeIntervalSince(sent)))
            return text
        })
    }

    private func cancel() {
        recorder?.cancel()
        recorder = nil
        parts.forEach { $0.cancel() }
        parts = []
        state = .idle
    }

    private func stop() {
        guard let recorder else { return }
        guard recorder.seconds >= 0.4 else { return cancel() }  // случайное нажатие
        self.recorder = nil
        let id = recordingID, date = recordStarted, setup = settings.dictation
        recorder.stop { [self] all, tail in
            tail.map(sendPart)
            let parts = self.parts
            self.parts = []
            do {
                try Segmenter.wav(all).write(to: audioURL(id))
            } catch {
                return fail("Не записался звук: \(error.localizedDescription)")
            }
            history.add(DictationEntry(id: id, date: date, seconds: Double(all.count) / Segmenter.rate,
                                       recognition: setup, audioName: audioURL(id).lastPathComponent))
            collect(id, parts, setup)
        }
    }

    /// Собирает куски по порядку. Если какой-то не распознался — распознаём запись целиком.
    private func collect(_ id: UUID, _ parts: [Task<String, Error>], _ setup: Recognition) {
        state = .sending
        let released = Date()
        Task { @MainActor in
            var texts: [String] = []
            do {
                for part in parts { texts.append(try await part.value) }
            } catch {
                Log.error("Диктовка: кусок не распознался (\(error.localizedDescription)), распознаю запись целиком")
                return send(id, paste: true)
            }
            Log.info(String(format: "Диктовка: %d кусков, после отпускания ждали %.1f с", parts.count,
                            Date().timeIntervalSince(released)))
            await deliver(id, texts.filter { !$0.isEmpty }.joined(separator: " "), setup, paste: true)
        }
    }

    /// Распознать запись из истории. После повтора текст не вставляется: курсор уже где-то ещё.
    func send(_ id: UUID, paste shouldPaste: Bool) {
        guard let entry = history.entries.first(where: { $0.id == id }), let audio = entry.audioURL else { return }
        let setup = shouldPaste ? entry.recognition : settings.dictation
        state = .sending
        Task { @MainActor in
            do {
                await deliver(id, try await Transcriber.transcribe(audio, setup), setup, paste: shouldPaste)
            } catch {
                history.update(id) { $0.error = error.localizedDescription }
                fail(error.localizedDescription)
            }
        }
    }

    /// Текст распознан: оформить, записать в историю, вставить.
    @MainActor private func deliver(_ id: UUID, _ raw: String, _ setup: Recognition, paste shouldPaste: Bool) async {
        let text = await format(raw)
        history.update(id) {
            if let audio = $0.audioURL { try? FileManager.default.removeItem(at: audio) }
            $0.text = text
            $0.raw = text == raw ? nil : raw
            $0.error = nil
            $0.audioName = nil
            $0.recognition = setup
        }
        state = .idle
        if shouldPaste, !text.isEmpty { paste(text) }
    }

    /// Оформление — необязательный шаг: при любой его ошибке вставляется распознанный текст как есть.
    @MainActor private func format(_ raw: String) async -> String {
        let setup = settings.formatting
        guard setup.formatter != .off, raw.split(whereSeparator: \.isWhitespace).count >= TextFormatter.minWords else { return raw }
        state = .formatting
        return (try? await TextFormatter.format(raw, setup)) ?? raw
    }

    private func fail(_ message: String) {
        NSSound(named: "Basso")?.play()
        state = .failed(message)
    }

    private func audioURL(_ id: UUID) -> URL { History.audioDir.appendingPathComponent("\(id).wav") }
}

/// Вставка через буфер обмена и Cmd+V; прежнее содержимое буфера возвращается.
func paste(_ text: String) {
    let board = NSPasteboard.general
    let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }
    board.clearContents()
    board.setString(text, forType: .string)
    let source = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)  // 9 = V
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        board.clearContents()
        board.writeObjects(saved)
    }
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
