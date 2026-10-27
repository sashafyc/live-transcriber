import ServiceManagement
import SwiftUI

@main
struct LiveTranscriberApp: App {
    @State private var settings: AppSettings
    @State private var history: History
    @State private var dictation: Dictation

    init() {
        Transcriber.checkFromCommandLine()
        let settings = AppSettings(), history = History()
        _settings = State(initialValue: settings)
        _history = State(initialValue: history)
        _dictation = State(initialValue: Dictation(settings: settings, history: history))
        // Автозапуск включаем один раз; дальше им управляет переключатель в настройках.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(settings: settings, history: history, dictation: dictation)
        } label: {
            Image(systemName: dictation.accessibilityGranted ? dictation.state.symbol : "exclamationmark.triangle")
        }
        Window("История диктовок", id: "history") {
            HistoryView(history: history, dictation: dictation)
        }
        .defaultSize(width: 560, height: 600)
        .defaultLaunchBehavior(.suppressed)
        Settings {
            SettingsView(settings: settings, dictation: dictation)
        }
    }
}

struct MenuContent: View {
    let settings: AppSettings
    let history: History
    let dictation: Dictation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if dictation.accessibilityGranted {
            Text(status)
        } else {
            Text("Fn не работает: нет Универсального доступа")
            Button("Выдать Универсальный доступ…") { openAccessibilitySettings() }
        }
        if let last = history.entries.first(where: { $0.text?.isEmpty == false })?.text {
            Button("Скопировать последнюю диктовку") { copyToClipboard(last) }
        }
        Divider()
        Button("История диктовок…") {
            NSApp.activate()
            openWindow(id: "history")
        }
        Button("Настройки…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Выход") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var status: String {
        switch dictation.state {
        case .idle: "Держи \(settings.hotkey.name) и говори"
        case .recording: "Запись…"
        case .sending: "Распознаю…"
        case .failed(let message): message
        }
    }
}
