import AppKit
import Observation

struct Hotkey: Identifiable {
    let code: UInt16
    let name: String
    let flag: NSEvent.ModifierFlags
    var id: UInt16 { code }

    static let all = [
        Hotkey(code: 63, name: "Fn 🌐", flag: .function),
        Hotkey(code: 61, name: "Правый Option", flag: .option),
        Hotkey(code: 54, name: "Правый Command", flag: .command),
        Hotkey(code: 62, name: "Правый Control", flag: .control),
    ]
}

/// Настройки без секретов — в UserDefaults, ключи — в связке ключей.
@Observable final class AppSettings {
    var dictation: Recognition { didSet { store(dictation, "dictation") } }
    var hotkeyCode: UInt16 { didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkey") } }
    var customEndpoint: String {
        didSet { UserDefaults.standard.set(customEndpoint, forKey: Transcriber.customEndpointKey) }
    }

    var hotkey: Hotkey { Hotkey.all.first { $0.code == hotkeyCode } ?? Hotkey.all[0] }

    init() {
        let defaults = UserDefaults.standard
        dictation = Self.load("dictation") ?? Recognition(provider: .openai, model: "gpt-4o-transcribe", language: "ru")
        hotkeyCode = UInt16(defaults.object(forKey: "hotkey") as? Int ?? 63)
        customEndpoint = defaults.string(forKey: Transcriber.customEndpointKey) ?? ""
    }

    private func store(_ value: Recognition, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load(_ key: String) -> Recognition? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Recognition.self, from: $0) }
    }
}
