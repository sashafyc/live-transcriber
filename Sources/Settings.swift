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
    var formatting: Formatting { didSet { store(formatting, "formatting") } }
    var hotkeyCode: UInt16 { didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkey") } }
    var customEndpoint: String {
        didSet { UserDefaults.standard.set(customEndpoint, forKey: Transcriber.customEndpointKey) }
    }
    var calls: Recognition { didSet { store(calls, "calls") } }
    var summary: Formatting { didSet { store(summary, "summary") } }
    /// Ссылка на чат или тему: из неё же берётся номер темы.
    var telegramChat: String { didSet { UserDefaults.standard.set(telegramChat, forKey: "telegramChat") } }
    var sendToTelegram: Bool { didSet { UserDefaults.standard.set(sendToTelegram, forKey: "sendToTelegram") } }
    var callPrompt: String { didSet { UserDefaults.standard.set(callPrompt, forKey: "callPrompt") } }
    var startWindowOnLaunch: Bool { didSet { UserDefaults.standard.set(startWindowOnLaunch, forKey: "startWindowOnLaunch") } }

    var hotkey: Hotkey { Hotkey.all.first { $0.code == hotkeyCode } ?? Hotkey.all[0] }

    init() {
        let defaults = UserDefaults.standard
        dictation = Self.load("dictation") ?? Recognition(provider: .openai, model: "gpt-4o-transcribe", language: "ru")
        var formatting: Formatting = Self.load("formatting") ?? Formatting(formatter: .off, model: "")
        // Старое имя DeepSeek уже отвечает моделью V4.1 Flash и пропало из документации
        if formatting.model == "deepseek-chat" { formatting.model = "deepseek-flash" }
        self.formatting = formatting
        hotkeyCode = UInt16(defaults.object(forKey: "hotkey") as? Int ?? 63)
        customEndpoint = defaults.string(forKey: Transcriber.customEndpointKey) ?? ""
        // Русский пакетно точно знает universal-2: на нём версии 1.x писали все звонки
        calls = Self.load("calls") ?? Recognition(provider: .assemblyai, model: "universal-2", language: "ru")
        summary = Self.load("summary") ?? Formatting(formatter: .deepseek, model: "deepseek-flash")
        telegramChat = defaults.string(forKey: "telegramChat") ?? ""
        sendToTelegram = defaults.object(forKey: "sendToTelegram") as? Bool ?? true
        callPrompt = defaults.string(forKey: "callPrompt") ?? Summary.defaultPrompt
        startWindowOnLaunch = defaults.bool(forKey: "startWindowOnLaunch")
    }

    private func store<Value: Encodable>(_ value: Value, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<Value: Decodable>(_ key: String) -> Value? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }
}
