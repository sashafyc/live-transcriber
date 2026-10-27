import AppKit
import AVFoundation
import Observation

/// Держишь клавишу — пишет микрофон, отпустил — текст распознаётся и вставляется туда, где курсор.
@Observable final class Dictation {
    enum State: Equatable {
        case idle, recording, sending
        case failed(String)

        var symbol: String {
            switch self {
            case .idle: "waveform"
            case .recording: "mic.fill"
            case .sending: "ellipsis.circle"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    private(set) var state = State.idle
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private let settings: AppSettings
    private let history: History
    private var recorder: AVAudioRecorder?
    private var recordingID = UUID()
    private var recordStarted = Date()

    init(settings: AppSettings, history: History) {
        self.settings = settings
        self.history = history
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
        let format: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
        ]
        do {
            let recorder = try AVAudioRecorder(url: audioURL(recordingID), settings: format)
            guard recorder.record() else { throw TranscriptionError("Микрофон не отдаёт звук") }
            self.recorder = recorder
            recordStarted = Date()
            state = .recording
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func cancel() {
        recorder?.stop()
        recorder = nil
        try? FileManager.default.removeItem(at: audioURL(recordingID))
        state = .idle
    }

    private func stop() {
        guard let recorder else { return }
        let seconds = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        guard seconds >= 0.4 else { return cancel() }  // случайное нажатие
        history.add(DictationEntry(id: recordingID, date: recordStarted, seconds: seconds,
                                   recognition: settings.dictation, audioName: "\(recordingID).m4a"))
        send(recordingID, paste: true)
    }

    /// Распознать запись из истории. После повтора текст не вставляется: курсор уже где-то ещё.
    func send(_ id: UUID, paste shouldPaste: Bool) {
        guard let entry = history.entries.first(where: { $0.id == id }), let audio = entry.audioURL else { return }
        let setup = shouldPaste ? entry.recognition : settings.dictation
        state = .sending
        Task { @MainActor in
            do {
                let text = try await Transcriber.transcribe(audio, setup)
                try? FileManager.default.removeItem(at: audio)
                history.update(id) {
                    $0.text = text
                    $0.error = nil
                    $0.audioName = nil
                    $0.recognition = setup
                }
                state = .idle
                if shouldPaste, !text.isEmpty { paste(text) }
            } catch {
                history.update(id) { $0.error = error.localizedDescription }
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        NSSound(named: "Basso")?.play()
        state = .failed(message)
    }

    private func audioURL(_ id: UUID) -> URL { History.audioDir.appendingPathComponent("\(id).m4a") }
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

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
