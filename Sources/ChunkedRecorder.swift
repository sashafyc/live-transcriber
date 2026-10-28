import AVFoundation

/// Нарезка речи на куски по паузам: длинная диктовка распознаётся, пока человек ещё говорит,
/// и после отпускания клавиши остаётся дождаться только последнего куска.
struct Segmenter {
    struct Chunk {
        let samples: [Int16]
        /// Сколько секунд в куске звучала речь — по ней сверяем, не потерял ли распознаватель слова.
        let speech: Double
    }

    static let rate = 16_000.0
    static let window = 800  // 50 мс
    /// Режем в паузе не раньше этой длины; если пауз нет — принудительно на максимуме, в самом тихом месте.
    static let minChunk = 5.0, maxChunk = 25.0
    /// Сколько окон тишины считать паузой. Сначала ждём конца предложения (400 мс): незаконченную
    /// фразу в конце куска gpt-4o-transcribe иногда выкидывает. Если кусок затянулся — хватит паузы покороче.
    private static func pauseWindows(_ seconds: Double) -> Int { seconds >= 18 ? 4 : seconds >= 12 ? 6 : 8 }
    /// Меньше стольких букв на секунду речи — распознаватель явно выкинул часть куска.
    static let minLettersPerSecond = 8.0

    private(set) var samples: [Int16] = []
    private var chunkStart = 0, analyzed = 0
    /// Уровень шума плывёт вверх на 1 дБ/с и тут же падает до любого более тихого окна.
    private var floor: Float = 0
    private var silentRun = 0, speechWindows = 0
    private var recent: [(end: Int, db: Float)] = []

    /// Добавляет звук; возвращает громкость новых окон для плашки и куски, готовые к отправке.
    mutating func append(_ new: [Int16]) -> (levels: [Float], chunks: [Chunk]) {
        samples += new
        var levels: [Float] = [], chunks: [Chunk] = []
        while analyzed + Self.window <= samples.count {
            let db = Self.decibels(samples[analyzed..<analyzed + Self.window])
            analyzed += Self.window
            levels.append(db)
            // Цифровая тишина на старте микрофона не должна утопить порог: в паузах живой речи остаётся эхо
            floor = max(-55, min(floor + 0.05, db))
            let silent = db < floor + 10
            silentRun = silent ? silentRun + 1 : 0
            if !silent { speechWindows += 1 }
            recent.append((analyzed, db))
            if recent.count > 40 { recent.removeFirst() }
            let length = Double(analyzed - chunkStart) / Self.rate
            if length >= Self.minChunk, silentRun >= Self.pauseWindows(length) {
                chunks += cut(at: analyzed - silentRun / 2 * Self.window)
            } else if length >= Self.maxChunk, let quietest = recent.min(by: { $0.db < $1.db }) {
                chunks += cut(at: quietest.end - Self.window / 2)
            }
        }
        return (levels, chunks)
    }

    /// Остаток после последнего куска — его распознаём уже после отпускания клавиши.
    mutating func finish() -> Chunk? {
        cut(at: samples.count).first
    }

    /// Кусок без речи не отправляем: на тишине распознавание сочиняет фразы.
    private mutating func cut(at end: Int) -> [Chunk] {
        defer {
            chunkStart = end
            speechWindows = 0
            silentRun = 0
            recent.removeAll()
        }
        guard speechWindows >= 3, end > chunkStart else { return [] }
        return [Chunk(samples: Array(samples[chunkStart..<end]), speech: Double(speechWindows * Self.window) / Self.rate)]
    }

    static func decibels(_ slice: ArraySlice<Int16>) -> Float {
        let power = slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(slice.count, 1))
        return power > 0 ? Float(10 * log10(power / (32768.0 * 32768.0))) : -160
    }

    /// 16-битный моно WAV: распознаётся всеми провайдерами без перекодирования.
    static func wav(_ samples: [Int16]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data += Data("RIFF".utf8); put(36 + bytes); data += Data("WAVEfmt ".utf8)
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data += Data("data".utf8); put(bytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!

    static func convert(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter) -> [Int16] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }
}

/// Микрофон в память, 16 кГц моно.
final class ChunkedRecorder {
    private let engine = AVAudioEngine()
    private var segmenter = Segmenter()
    private let onLevel: (Float) -> Void
    private let onChunk: (Segmenter.Chunk) -> Void

    init(onLevel: @escaping (Float) -> Void, onChunk: @escaping (Segmenter.Chunk) -> Void) {
        self.onLevel = onLevel
        self.onChunk = onChunk
    }

    var seconds: Double { Double(segmenter.samples.count) / Segmenter.rate }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: Segmenter.format) else {
            throw TranscriptionError("Микрофон не отдаёт звук")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let samples = Segmenter.convert(buffer, converter)
            DispatchQueue.main.async { self?.append(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    private func append(_ samples: [Int16]) {
        let (levels, chunks) = segmenter.append(samples)
        levels.forEach(onLevel)
        chunks.forEach(onChunk)
    }

    /// Пишет ещё чуть-чуть: клавишу отпускают сразу после последнего слова. Звук, уже стоящий
    /// в очереди, успевает добавиться — `done` получает всю запись и хвост после последнего куска.
    func stop(_ done: @escaping (_ all: [Int16], _ tail: Segmenter.Chunk?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            DispatchQueue.main.async { [self] in done(segmenter.samples, segmenter.finish()) }
        }
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Замер из терминала: LiveTranscriber --chunk-test <аудио> [провайдер] [модель].
    /// Файл проигрывается в реальном времени, как будто его диктуют; сравнивается ожидание
    /// после отпускания клавиши — целиком и кусками.
    static func checkFromCommandLine() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[1] == "--chunk-test" else { return }
        let provider = arguments.count > 3 ? Provider(rawValue: arguments[3]) ?? .openai : .openai
        let model = arguments.count > 4 ? arguments[4] : provider.suggestedModels.first ?? ""
        let setup = Recognition(provider: provider, model: model, language: "ru")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2]))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      let converter = AVAudioConverter(from: file.processingFormat, to: Segmenter.format) else { return }
                try file.read(into: buffer)
                let audio = Segmenter.convert(buffer, converter)
                print(String(format: "Звук: %.1f с, %@ %@", Double(audio.count) / Segmenter.rate, provider.title, model))

                var started = Date()
                let whole = try await Transcriber.transcribe(Segmenter.wav(audio), filename: "dictation.wav", setup)
                print(String(format: "\nЦеликом: ждать после отпускания %.1f с\n%@", Date().timeIntervalSince(started), whole))

                var segmenter = Segmenter(), parts: [Task<String, Error>] = []
                func send(_ chunk: Segmenter.Chunk) {
                    let sent = Date(), number = parts.count + 1
                    parts.append(Task {
                        let text = try await Transcriber.transcribe(chunk, setup)
                        print(String(format: "  кусок %d: %.1f с звука (речи %.1f с, %.0f букв/с), распознан за %.1f с: %@", number,
                                     Double(chunk.samples.count) / Segmenter.rate, chunk.speech, Double(text.count) / chunk.speech,
                                     Date().timeIntervalSince(sent), text))
                        return text
                    })
                }
                let step = Int(Segmenter.rate / 10)
                for start in stride(from: 0, to: audio.count, by: step) {
                    segmenter.append(Array(audio[start..<min(start + step, audio.count)])).chunks.forEach(send)
                    try await Task.sleep(for: .milliseconds(100))
                }
                started = Date()
                segmenter.finish().map(send)
                var texts: [String] = []
                for part in parts { texts.append(try await part.value) }
                print(String(format: "\nКусками (%d): ждать после отпускания %.1f с\n%@", parts.count,
                             Date().timeIntervalSince(started), texts.joined(separator: " ")))
            } catch {
                print("ОШИБКА: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
