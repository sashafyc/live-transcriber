import Foundation

/// Время записей — московское, как у Python-версии: папки и шапки расшифровок совпадают.
private let msk = TimeZone(secondsFromGMT: 3 * 3600)!

private func formatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = msk
    formatter.dateFormat = format
    return formatter
}

/// Папка одной записи: transcript.md, summary.md, session.log, meta.json, audio.flac.
/// Папка общая с Python-версией: история не обрывается при переезде, и старые записи
/// можно расшифровать заново отсюда.
struct CallRecord: Identifiable, Hashable {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Live Transcriber/records")
    static let keepDays = 30.0
    /// Звук занимает в сотни раз больше текста и живёт неделю: этого хватает, чтобы переделать свежую расшифровку
    static let keepAudioDays = 7.0

    let url: URL
    var id: String { url.lastPathComponent }
    var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    var summaryURL: URL { url.appendingPathComponent("summary.md") }
    var rawURL: URL { url.appendingPathComponent("audio.raw") }
    var audioURL: URL { url.appendingPathComponent("audio.flac") }
    var logURL: URL { url.appendingPathComponent("session.log") }

    static func create(title: String, prompt: String) throws -> CallRecord {
        let now = Date()
        let slug = String(title.replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || "_-.".contains($0) }.prefix(60))
        let name = formatter("yyyy-MM-dd-HHmm").string(from: now) + "-" + (slug.isEmpty ? "call" : slug)
        var url = dir.appendingPathComponent(name), suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name)-\(suffix)")
            suffix += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let record = CallRecord(url: url)
        record.writeMeta(["title": title, "prompt": prompt, "started_at": iso.string(from: now),
                          "duration_sec": 0, "status": "recording"])
        record.appendTranscript("# Транскрипт — \(formatter("dd.MM.yyyy HH:mm").string(from: now)) — \(title)\n")
        return record
    }

    static func all() -> [CallRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted(by: >).map { CallRecord(url: dir.appendingPathComponent($0)) }
            .filter { (try? $0.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = msk
        return formatter
    }()

    // MARK: Файлы

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func transcript() -> String { read(transcriptURL) }
    func summary() -> String { read(summaryURL) }
    var hasAudio: Bool { FileManager.default.fileExists(atPath: audioURL.path) }

    /// Расшифровка без шапки.
    var transcriptBody: String {
        let text = transcript()
        guard let newline = text.firstIndex(of: "\n") else { return "" }
        return text[newline...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func appendTranscript(_ text: String) {
        let line = Data((text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n").utf8)
        if let handle = try? FileHandle(forWritingTo: transcriptURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: transcriptURL)
        }
    }

    /// Переписывает расшифровку целиком, прежнюю сохраняет рядом.
    func replaceTranscript(_ text: String) {
        let old = transcript()
        if !old.isEmpty { try? old.write(to: url.appendingPathComponent("transcript-прежний.md"), atomically: true, encoding: .utf8) }
        let started = startedAt.map { formatter("dd.MM.yyyy HH:mm").string(from: $0) } ?? ""
        try? "# Транскрипт — \(started) — \(title)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    func writeSummary(_ text: String) {
        try? (text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    // MARK: Метаданные

    func meta() -> [String: Any] {
        (try? Data(contentsOf: url.appendingPathComponent("meta.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func writeMeta(_ changes: [String: Any]) {
        let meta = meta().merging(changes) { $1 }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    var title: String { meta()["title"] as? String ?? id }
    var prompt: String { meta()["prompt"] as? String ?? Summary.defaultPrompt }
    var startedAt: Date? { (meta()["started_at"] as? String).flatMap { Self.iso.date(from: $0) } }
    var duration: Int { meta()["duration_sec"] as? Int ?? 0 }

    var label: String {
        let when = startedAt.map { formatter("dd.MM HH:mm").string(from: $0) } ?? String(id.prefix(16))
        return "\(when) · \(duration / 60):\(String(format: "%02d", duration % 60))"
    }

    /// Удаляет записи старше 30 дней и звук старше недели.
    static func cleanup() {
        var removed = 0
        for record in all() {
            let modified = (try? record.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let age = Date().timeIntervalSince(record.startedAt ?? modified ?? Date()) / 86400
            if age > keepDays {
                try? FileManager.default.removeItem(at: record.url)
                removed += 1
            } else if age > keepAudioDays {
                for leftover in [record.audioURL, record.rawURL] where (try? FileManager.default.removeItem(at: leftover)) != nil {
                    removed += 1
                }
            }
        }
        if removed > 0 { Log.info("Хранение \(Int(keepDays)) дней: удалено объектов — \(removed)") }
    }
}

/// Общий лог приложения и отдельный лог текущей записи. Ключей и адресов с токенами здесь не бывает.
enum Log {
    static let dir = supportDir.appendingPathComponent("logs")
    private static let file = dir.appendingPathComponent("app.log")
    private static let queue = DispatchQueue(label: "log")
    private static let stamp = formatter("yyyy-MM-dd HH:mm:ss")
    private static var session: URL?

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    static func attach(_ record: CallRecord?) { queue.async { session = record?.logURL } }

    private static func write(_ level: String, _ message: String) {
        let date = Date()
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
                let old = dir.appendingPathComponent("app.log.1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: file, to: old)
            }
            let line = Data("\(stamp.string(from: date)) \(level) \(message)\n".utf8)
            for url in [file, session].compactMap({ $0 }) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                    try? handle.close()
                } else {
                    try? line.write(to: url)
                }
            }
        }
    }
}

/// Ключи и настройки Python-версии переезжают один раз, при первом запуске.
enum LegacyConfig {
    static func importOnce(_ settings: AppSettings) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "legacyImported") else { return }
        defaults.set(true, forKey: "legacyImported")
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Live Transcriber/config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var moved: [String] = []
        for (old, account) in [("assemblyai_key", "assemblyai"), ("deepseek_key", "deepseek"), ("telegram_token", "telegram")] {
            if let value = config[old] as? String, !value.isEmpty, Keychain.get(account).isEmpty {
                Keychain.set(account, value)
                moved.append(account)
            }
        }
        if let chat = config["telegram_chat"] as? String, settings.telegramChat.isEmpty { settings.telegramChat = chat }
        if let send = config["send_to_telegram"] as? Bool { settings.sendToTelegram = send }
        if let prompt = config["prompt"] as? String, !prompt.isEmpty { settings.callPrompt = prompt }
        Log.info("Перенёс настройки старой версии, ключи: \(moved.joined(separator: ", "))")
    }
}
