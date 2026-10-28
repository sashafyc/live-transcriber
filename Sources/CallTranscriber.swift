import Foundation

/// Кусок речи одного голоса: дорожка («1» — микрофон, «2» — собеседник), метка голоса, время в мс.
struct Utterance {
    var channel: String
    var speaker: String
    var start: Int
    var end: Int
    var text: String
}

/// Расшифровка созвона: кусок звука → текст с именами говорящих.
enum CallTranscriber {
    static let me = "Я"
    static let other = "Собеседник"
    static let micChannel = "1"

    /// `solo` — чья дорожка, когда пишется одна: на внешнем созвоне хозяин микрофона известен заранее.
    static func transcribe(_ pcm: [Int16], channels: Int, setup: Recognition, solo: String?,
                           wholeRecording: Bool = false) async throws -> String {
        var (pcm, channels, only) = CallAudio.singleTrack(CallAudio.duckBleed(pcm, channels: channels), channels: channels)
        if only == nil, channels == 1 { only = solo }
        pcm = CallAudio.trimSilence(pcm, channels: channels)
        guard !pcm.isEmpty else {
            Log.info("В куске записи нет речи, распознавать нечего")
            return ""
        }
        let timeout: Double = wholeRecording ? 3600 : 600
        switch setup.provider {
        case .assemblyai:
            let data = try await assemblyAI(pcm, channels: channels, setup: setup, timeout: timeout)
            guard let raw = data["utterances"] as? [[String: Any]], !raw.isEmpty else {
                return (data["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return format(raw.map(utterance), only: only, multi: (data["audio_channels"] as? Int ?? 1) > 1)
        case .openai, .custom:
            let items = try await openAI(pcm, channels: channels, setup: setup, timeout: timeout)
            return format(items, only: only, multi: channels > 1)
        }
    }

    private static func assemblyAI(_ pcm: [Int16], channels: Int, setup: Recognition, timeout: Double) async throws -> [String: Any] {
        let file = try CallAudio.flac(pcm, channels: channels)
        Log.info("Отправляю FLAC, \(String(format: "%.1f", Double(file.count) / 1e6)) МБ")
        var job = Transcriber.languageJob(setup)
        // Каждая дорожка расшифровывается отдельно, и метки не путаются между кусками записи
        if channels > 1 { job["multichannel"] = true }
        job["speaker_labels"] = true
        // Границы считаются для каждой дорожки отдельно, поэтому потолок низкий
        job["speaker_options"] = ["min_speakers_expected": 1, "max_speakers_expected": channels > 1 ? 2 : 4]
        let data = try await Transcriber.assemblyAIJob(file, job, uploadAttempts: 3, uploadTimeout: 300,
                                                       pollEvery: 3, pollFor: timeout)
        Log.info("Модель: \(data["speech_model_used"] as? String ?? "не указана")")
        return data
    }

    /// У OpenAI нет ни дорожек, ни голосов: каждая дорожка уходит отдельным запросом,
    /// а куски с временем (у whisper и совместимых) склеиваются в разговор по времени.
    private static func openAI(_ pcm: [Int16], channels: Int, setup: Recognition, timeout: Double) async throws -> [Utterance] {
        var items: [Utterance] = []
        let tracks = channels == 2 ? [CallAudio.track(pcm, 0), CallAudio.track(pcm, 1)] : [pcm]
        for (index, track) in tracks.enumerated() where CallAudio.levels(track, channels: 1)[0] >= CallAudio.silence {
            let file = try CallAudio.flac(track, channels: 1)
            let channel = channels == 2 ? "\(index + 1)" : ""
            let timed = setup.provider == .custom || setup.model.hasPrefix("whisper")
            var data: [String: Any]
            do {
                data = try await Transcriber.openAICompatible(file, setup, filename: "audio.flac",
                                                              format: timed ? "verbose_json" : "json", timeout: timeout)
            } catch where timed {
                data = try await Transcriber.openAICompatible(file, setup, filename: "audio.flac", timeout: timeout)
            }
            if let segments = data["segments"] as? [[String: Any]], !segments.isEmpty {
                items += segments.map {
                    Utterance(channel: channel, speaker: "", start: Int(($0["start"] as? Double ?? 0) * 1000),
                              end: Int(($0["end"] as? Double ?? 0) * 1000), text: $0["text"] as? String ?? "")
                }
            } else {
                items.append(Utterance(channel: channel, speaker: "", start: 0, end: track.count * 1000 / CallAudio.rate,
                                       text: data["text"] as? String ?? ""))
            }
        }
        return items
    }

    private static func utterance(_ raw: [String: Any]) -> Utterance {
        func string(_ key: String) -> String { raw[key].map { "\($0)" } ?? "" }
        var channel = string("channel"), speaker = string("speaker")
        if channel.isEmpty, speaker.first?.isNumber == true {
            channel = String(speaker.prefix(1))
            speaker = String(speaker.dropFirst())
        }
        return Utterance(channel: channel, speaker: speaker, start: raw["start"] as? Int ?? 0,
                         end: raw["end"] as? Int ?? 0, text: raw["text"] as? String ?? "")
    }

    // MARK: Имена и порядок

    static func format(_ items: [Utterance], only: String?, multi: Bool) -> String {
        var items = withoutInvented(items).sorted { $0.start < $1.start }
        guard !items.isEmpty else { return "" }

        if let only {
            // Дорожка одна, и мы знаем чья. Но голосов на ней может быть несколько:
            // собеседник на громкой связи звучит в тот же микрофон
            let names = only == me ? voicesOnMic(items) : [:]
            return merge(items.map { (names[$0.speaker] ?? only, $0.text) })
        }
        guard multi else { return merge(items.map { ("Спикер \($0.speaker.isEmpty ? "?" : $0.speaker)", $0.text) }) }

        items = dropEcho(items)
        let voices = Set(items.filter { $0.channel != micChannel && !$0.speaker.isEmpty }.map(\.speaker))
        let others = voices.count > 1 ? Dictionary(uniqueKeysWithValues: voices.map { ($0, "\(other) \($0)") }) : [:]
        let micNames = voicesOnMic(items.filter { $0.channel == micChannel })
        return merge(items.map { item in
            if item.channel == micChannel { return (micNames[item.speaker] ?? me, item.text) }
            return (others[item.speaker] ?? other, item.text)
        })
    }

    /// Самый говорящий голос на микрофоне — его хозяин, остальные — собеседники рядом или на громкой связи.
    static func voicesOnMic(_ items: [Utterance]) -> [String: String] {
        var totals: [String: Int] = [:], order: [String] = []
        for item in items {
            if totals[item.speaker] == nil { order.append(item.speaker) }
            totals[item.speaker, default: 0] += item.text.count
        }
        guard totals.count >= 2 else { return [:] }
        let main = order.max { totals[$0]! < totals[$1]! }!
        let rest = totals.keys.filter { $0 != main }.sorted()
        var names = [main: me]
        for (index, speaker) in rest.enumerated() {
            names[speaker] = rest.count == 1 ? other : "\(other) \(Character(UnicodeScalar(65 + index)!))"
        }
        return names
    }

    /// Соседние куски одного голоса снова становятся репликой.
    static func merge(_ pairs: [(String, String)]) -> String {
        var lines: [(String, [String])] = []
        for (name, text) in pairs {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if lines.last?.0 == name { lines[lines.count - 1].1.append(text) } else { lines.append((name, [text])) }
        }
        return lines.compactMap { name, parts in
            let body = stripInvented(parts.joined(separator: " "))
            return body.isEmpty ? nil : "**\(name):** \(body)"
        }.joined(separator: "\n")
    }

    // MARK: Отражения между дорожками

    /// Речь собеседника из динамиков слышна микрофону, а речь пользователя отражается
    /// в системный звук. Из двух совпавших кусков оставляем более полный: короткий — почти всегда отражение.
    static func dropEcho(_ items: [Utterance]) -> [Utterance] {
        guard Set(items.map(\.channel)).count >= 2 else { return items }
        let words = items.map { self.words($0.text) }
        var drop = Set<Int>()
        for (index, item) in items.enumerated() where !words[index].isEmpty {
            for (otherIndex, candidate) in items.enumerated() where candidate.channel != item.channel {
                guard !drop.contains(otherIndex), item.end >= candidate.start, item.start <= candidate.end else { continue }
                let mine = words[index], theirs = words[otherIndex]
                guard !theirs.isEmpty, mine.count <= theirs.count else { continue }
                if mine.isSubset(of: theirs) || (mine.count <= 3 && !mine.isDisjoint(with: theirs))
                    || similar(item.text, candidate.text) >= 0.5 {
                    drop.insert(index)
                    break
                }
            }
        }
        if !drop.isEmpty { Log.info("Убрал отражения между дорожками: \(drop.count) кусков") }
        return items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// Пунктуация и «ё» на двух дорожках расставлены по-разному: сравниваем только слова.
    static func words(_ text: String) -> Set<String> {
        let lower = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        return Set(matches(wordPattern, lower))
    }

    /// Одно слово дорожки слышат с разными окончаниями («бюджета» и «бюджеты»): сравниваем по началу.
    private static func similar(_ first: String, _ second: String) -> Double {
        let a = Set(words(first).map { String($0.prefix(5)) }), b = Set(words(second).map { String($0.prefix(5)) })
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    // MARK: Выдуманные титры

    // Распознавание обучено и на видео с субтитрами, и на тишине или шуме достраивает
    // их концовку: «Редактор субтитров А.Семкин Корректор А.Егорова». Узнаём по связке
    // «должность + инициал с точкой + фамилия», иначе пострадает живое слово «корректор».
    private static let name = #"[А-ЯЁ]\.\s*[А-ЯЁ][а-яё]+"#
    private static let inventedPhrase = try! NSRegularExpression(pattern:
        #"(?:[Рр]едактор\s+субтитров(?:\s+"# + name + #")?|[Кк]орректор\s+"# + name
            + #"|[Сс]убтитр\w*\s+(?:сделал|создавал|подготовил|делал)[^.!?]*|[Пп]родолжение\s+следует\.{2,})"#)
    private static let wordPattern = try! NSRegularExpression(pattern: #"\w+"#)
    private static let shardRole = try! NSRegularExpression(pattern: "^(редактор|корректор)$", options: .caseInsensitive)
    private static let shardName = try! NSRegularExpression(pattern: "^" + name + "$")

    /// Вырезает титры, приклеившиеся к настоящей реплике.
    static func stripInvented(_ text: String) -> String {
        let cleaned = replace(inventedPhrase, text, " ")
        return replace(try! NSRegularExpression(pattern: #"\s{2,}"#), cleaned, " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
    }

    /// Осколки титров: слово «субтитры», одинокая должность или инициал с фамилией без предложения.
    private static func shard(_ text: String) -> Bool {
        let words = text.replacingOccurrences(of: ",", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }
        if words.contains(where: { $0.lowercased().contains("субтитр") }) { return true }
        return words.count <= 3 && words.contains { !matches(shardRole, $0).isEmpty || !matches(shardName, $0).isEmpty }
    }

    private static func invented(_ text: String) -> Bool {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return count > 0 && count <= 12 && (stripInvented(text).isEmpty || shard(text))
    }

    /// Титры бывают разорваны на отдельные слова вперемешку с другой дорожкой. Собираем
    /// куски одной дорожки, идущие подряд (паузы до 2 с), и судим по фразе целиком.
    static func withoutInvented(_ items: [Utterance]) -> [Utterance] {
        var tracks: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            tracks[item.channel.isEmpty ? item.speaker : item.channel, default: []].append(index)
        }
        var drop = Set<Int>()
        func judge(_ group: [Int]) {
            let phrase = group.map { items[$0].text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            if !group.isEmpty, invented(phrase) { drop.formUnion(group) }
        }
        for indices in tracks.values {
            var group: [Int] = []
            for index in indices.sorted(by: { items[$0].start < items[$1].start }) {
                if let last = group.last, items[index].start - items[last].end <= 2000 {
                    group.append(index)
                } else {
                    judge(group)
                    group = [index]
                }
            }
            judge(group)
        }
        if !drop.isEmpty { Log.info("Убрал выдуманные титры: \(drop.count) кусков") }
        return items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func replace(_ regex: NSRegularExpression, _ text: String, _ template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Очередь кусков: расшифровываются параллельно, в файл пишутся строго по порядку.
final class CallPipeline {
    private let setup: Recognition
    private let solo: String?
    /// Куда сложить звук, который не удалось расшифровать: лучше файл на диске, чем молча потерянный разговор
    private let rescueDir: URL
    private let onText: (String) -> Void
    private let onError: (String, Int) -> Void
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var results: [Int: String] = [:]
    private var next = 1
    private(set) var failed = 0
    private(set) var empty = 0

    init(setup: Recognition, solo: String?, rescueDir: URL, onText: @escaping (String) -> Void,
         onError: @escaping (String, Int) -> Void) {
        self.setup = setup
        self.solo = solo
        self.rescueDir = rescueDir
        self.onText = onText
        self.onError = onError
    }

    func submit(_ pcm: [Int16], index: Int, channels: Int) {
        group.enter()
        Task.detached { [self] in
            var text = ""
            do {
                text = try await CallTranscriber.transcribe(pcm, channels: channels, setup: setup, solo: solo)
                Log.info(text.isEmpty ? "Кусок \(index): речь не распознана" : "Кусок \(index): \(text.count) символов")
                if text.isEmpty { lock.withLock { empty += 1 } }
            } catch {
                Log.error("Кусок \(index) не расшифрован: \(error.localizedDescription)")
                lock.withLock { failed += 1 }
                rescue(pcm, index: index, channels: channels)
                onError(error.localizedDescription, index)
            }
            store(index, text)
            group.leave()
        }
    }

    private func rescue(_ pcm: [Int16], index: Int, channels: Int) {
        let url = rescueDir.appendingPathComponent(String(format: "нерасшифровано-%03d.flac", index))
        do {
            try CallAudio.flac(pcm, channels: channels).write(to: url)
            Log.info("Звук куска \(index) сохранён: \(url.lastPathComponent)")
        } catch {
            Log.error("Звук куска \(index) не сохранился: \(error.localizedDescription)")
        }
    }

    private func store(_ index: Int, _ text: String) {
        lock.withLock {
            results[index] = text
            while let ready = results.removeValue(forKey: next) {
                if !ready.isEmpty { onText(ready) }
                next += 1
            }
        }
    }

    /// Ждёт все куски; дырки в нумерации не задерживают выдачу остального.
    func wait() async {
        await withCheckedContinuation { done in group.notify(queue: .global()) { done.resume() } }
        lock.withLock {
            for index in results.keys.sorted() where !results[index]!.isEmpty { onText(results[index]!) }
            results = [:]
        }
    }
}
