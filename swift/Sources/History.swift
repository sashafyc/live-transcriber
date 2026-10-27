import Foundation
import Observation

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Live Transcriber 2")

struct DictationEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    var seconds: Double
    var recognition: Recognition
    var text: String?
    /// Распознанный текст до оформления, если оформление его изменило.
    var raw: String?
    var error: String?
    /// Звук держим, пока текст не получен: «Повторить» без передиктовки.
    var audioName: String?

    var audioURL: URL? { audioName.map { History.audioDir.appendingPathComponent($0) } }
}

/// Диктовки за последние сутки: текст можно скопировать, если вставка ушла не туда.
@Observable final class History {
    static let audioDir = supportDir.appendingPathComponent("dictation")
    private static let file = supportDir.appendingPathComponent("dictation.json")
    private static let keep: TimeInterval = 24 * 3600

    private(set) var entries: [DictationEntry] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.audioDir, withIntermediateDirectories: true)
        entries = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([DictationEntry].self, from: $0) } ?? []
        prune()
    }

    func add(_ entry: DictationEntry) {
        entries.insert(entry, at: 0)
        prune()
    }

    func update(_ id: UUID, _ change: (inout DictationEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        save()
    }

    /// Удаляет записи старше суток вместе со звуком и подбирает звук без записи.
    func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        entries.removeAll { $0.date < cutoff }
        let alive = Set(entries.compactMap(\.audioName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.audioDir.path)) ?? []
        for name in files where !alive.contains(name) {
            try? FileManager.default.removeItem(at: Self.audioDir.appendingPathComponent(name))
        }
        save()
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: Self.file, options: .atomic)
    }
}
