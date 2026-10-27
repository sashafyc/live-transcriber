import AVFoundation

/// Обработка звука созвона до отправки: всё на 16 кГц, 16 бит, дорожки чередуются.
enum CallAudio {
    static let rate = CallCapture.rate
    /// Ниже — тишина; уровень меряется по каждой дорожке отдельно, поэтому порог обычный.
    static let silence = 15.0
    /// Выше — похоже на речь, а не на шум комнаты.
    static let speech = 150.0

    /// Громкость каждой дорожки: [микрофон, собеседник]. Без разделения тихий
    /// собеседник тонет в громком микрофоне, и половина разговора теряется незаметно.
    static func levels(_ pcm: [Int16], channels: Int, from: Int = 0, to: Int? = nil) -> [Double] {
        let end = to ?? pcm.count
        var sums = [Double](repeating: 0, count: channels)
        var index = from
        while index + channels <= end {
            for channel in 0..<channels {
                let value = Double(pcm[index + channel])
                sums[channel] += value * value
            }
            index += channels
        }
        let frames = Double((end - from) / channels)
        return sums.map { frames > 0 ? ($0 / frames).squareRoot() : 0 }
    }

    /// Какая доля записи на дорожке — звук, а не тишина: шум даёт почти единицу, разговор заметно меньше.
    static func speechShare(_ pcm: [Int16], channels: Int, channel: Int) -> Double {
        let step = rate * channels
        var loud = 0, total = 0, start = 0
        while start + step < pcm.count {
            if levels(pcm, channels: channels, from: start, to: start + step)[channel] >= speech { loud += 1 }
            total += 1
            start += step
        }
        return total > 0 ? Double(loud) / Double(total) : 0
    }

    // MARK: Вырезание пауз

    /// Распознавание не умеет молчать: на участке без речи оно достраивает то, что чаще
    /// всего стояло рядом с тишиной в обучающих данных — титры переводчиков. Чем меньше
    /// тишины уходит, тем меньше выдумок, и пауза не стоит денег. Дорожки режутся
    /// одновременно, иначе речь на них разъедется во времени.
    static func trimSilence(_ pcm: [Int16], channels: Int) -> [Int16] {
        let step = rate / 10 * channels  // окно 100 мс
        guard pcm.count >= step * 2 else { return pcm }
        let windows = (pcm.count - step) / step + 1
        let loud = (0..<windows).map { levels(pcm, channels: channels, from: $0 * step, to: $0 * step + step).max()! >= silence }
        let edge = 4  // 0.4 с тишины по краям речи
        let gap = 30  // пауза длиннее 3 с вырезается
        var keep = [Bool](repeating: false, count: windows)
        for (index, isLoud) in loud.enumerated() where isLoud {
            for near in max(0, index - edge)..<min(windows, index + edge + 1) { keep[near] = true }
        }
        // Короткие паузы внутри речи оставляем: без них слова слипаются
        var start: Int?
        for index in 0...windows {
            let quiet = index < windows && !keep[index]
            if quiet, start == nil {
                start = index
            } else if !quiet, let from = start {
                if index - from <= gap { for near in from..<index { keep[near] = true } }
                start = nil
            }
        }
        if !keep.contains(false) { return pcm }
        var trimmed: [Int16] = []
        for (index, ok) in keep.enumerated() where ok { trimmed += pcm[index * step..<index * step + step] }
        if trimmed.count >= rate * channels {
            Log.info("Вырезал пауз: \((pcm.count - trimmed.count) / channels / rate) из \(pcm.count / channels / rate) с")
        }
        return trimmed
    }

    // MARK: Собеседник из колонок в микрофоне

    /// Глушит в микрофоне то, что он услышал из колонок. Дорожки распознаются порознь,
    /// и одна речь возвращается дважды разными словами — отсев по тексту бессилен,
    /// поэтому режем по звуку: кадры, где микрофон лишь повторяет собеседника тише него.
    /// Своя речь громче просочившейся втрое и остаётся.
    static func duckBleed(_ pcm: [Int16], channels: Int) -> [Int16] {
        guard channels == 2, !pcm.isEmpty else { return pcm }
        let size = rate / 50  // кадр 20 мс
        let spread = 5  // ±100 мс: столько звук идёт от колонок до микрофона
        let margin = 3.0
        let minLink = 0.25
        let frames = pcm.count / 2
        guard frames >= size * 2 else { return pcm }
        let count = (frames - size) / size + 1
        func envelope(_ channel: Int) -> [Double] {
            (0..<count).map { frame in
                var sum = 0.0
                for index in frame * size..<frame * size + size {
                    let value = Double(pcm[index * 2 + channel])
                    sum += value * value
                }
                return (sum / Double(size)).squareRoot()
            }
        }
        let heard = envelope(0), played = envelope(1)
        // Громкость собеседника с запасом по времени: до микрофона звук доходит с задержкой
        let near = (0..<count).map { played[max(0, $0 - spread)..<min(count, $0 + spread + 1)].max()! }
        guard link(heard, near) >= minLink else { return pcm }  // наушники: микрофон живёт сам по себе

        let ratios = (0..<count).filter { near[$0] >= speech }.map { heard[$0] / near[$0] }.sorted()
        guard !ratios.isEmpty else { return pcm }
        let gain = ratios[ratios.count / 2]
        var out = pcm, muted = 0
        for frame in 0..<count where near[frame] >= speech && heard[frame] < near[frame] * gain * margin {
            for index in frame * size..<frame * size + size { out[index * 2] = 0 }
            muted += 1
        }
        guard muted > 0 else { return pcm }
        Log.info("Микрофон слышит колонки (в \(String(format: "%.2f", gain)) от собеседника), заглушил \(muted / 50) из \(count / 50) с")
        return out
    }

    /// Насколько похоже меняется громкость двух дорожек.
    private static func link(_ first: [Double], _ second: [Double]) -> Double {
        let count = Double(first.count)
        guard count >= 2 else { return 0 }
        let meanA = first.reduce(0, +) / count, meanB = second.reduce(0, +) / count
        var top = 0.0, sideA = 0.0, sideB = 0.0
        for index in first.indices {
            let a = first[index] - meanA, b = second[index] - meanB
            top += a * b
            sideA += a * a
            sideB += b * b
        }
        return sideA > 0 && sideB > 0 ? top / (sideA.squareRoot() * sideB.squareRoot()) : 0
    }

    /// Пустую дорожку не отправляем: на ней распознавание выдумывает титры,
    /// а чья речь осталась, мы и так знаем по номеру дорожки.
    static func singleTrack(_ pcm: [Int16], channels: Int) -> ([Int16], Int, String?) {
        guard channels == 2, !pcm.isEmpty else { return (pcm, channels, nil) }
        let level = levels(pcm, channels: 2)
        let keep: Int, name: String
        if level[1] < silence, silence <= level[0] {
            (keep, name) = (0, CallTranscriber.me)
        } else if level[0] < silence, silence <= level[1] {
            (keep, name) = (1, CallTranscriber.other)
        } else {
            return (pcm, channels, nil)
        }
        Log.info("Вторая дорожка пустая, отправляю только «\(name)»")
        return (track(pcm, keep), 1, name)
    }

    static func track(_ pcm: [Int16], _ channel: Int) -> [Int16] {
        stride(from: channel, to: pcm.count, by: 2).map { pcm[$0] }
    }

    // MARK: FLAC

    /// FLAC сжимает без потерь примерно вдвое. Сжатие с потерями вредно: оно съедает
    /// оттенки голоса, по которым речь делится на говорящих.
    static func flac(_ pcm: [Int16], channels: Int) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lt-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFLAC(url, channels: channels) { try $0(pcm) }
        return try Data(contentsOf: url)
    }

    /// Пишет FLAC кусками: `feed` отдаёт их через переданную функцию.
    static func writeFLAC(_ url: URL, channels: Int, feed: (([Int16]) throws -> Void) throws -> Void) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate),
                                   channels: AVAudioChannelCount(channels), interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16],
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        try feed { samples in
            let frames = samples.count / channels
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: frames * channels) }
            try file.write(from: buffer)
        }
    }

    /// Сырая запись → audio.flac рядом. Тот же звук, места втрое меньше.
    static func compress(raw: URL, to url: URL, channels: Int) throws {
        let handle = try FileHandle(forReadingFrom: raw)
        defer { try? handle.close() }
        try writeFLAC(url, channels: channels) { write in
            while let data = try handle.read(upToCount: rate * channels * 2 * 10), !data.isEmpty {
                try write(data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) })
            }
        }
        try FileManager.default.removeItem(at: raw)
    }

    /// Сохранённый звук записи → отсчёты и число дорожек.
    static func read(_ url: URL) throws -> ([Int16], Int) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let channels = Int(file.processingFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranscriptionError("Звук записи не читается")
        }
        try file.read(into: buffer)
        return (Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * channels)), channels)
    }
}
