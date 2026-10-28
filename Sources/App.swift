import ServiceManagement
import SwiftUI

@main
struct LiveTranscriberApp: App {
    @State private var settings: AppSettings
    @State private var history: History
    @State private var dictation: Dictation
    @State private var calls: Calls

    init() {
        Transcriber.checkFromCommandLine()
        TextFormatter.checkFromCommandLine()
        CallCapture.checkFromCommandLine()
        let settings = AppSettings(), history = History()
        Log.info("=== Live Transcriber \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") запущен ===")
        LegacyConfig.importOnce(settings)
        _settings = State(initialValue: settings)
        _history = State(initialValue: history)
        _dictation = State(initialValue: Dictation(settings: settings, history: history))
        let calls = Calls(settings: settings)
        _calls = State(initialValue: calls)
        if settings.startWindowOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { calls.openStart() }
        }
        // Автозапуск включаем один раз; дальше им управляет переключатель в настройках.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(settings: settings, history: history, dictation: dictation, calls: calls)
        } label: {
            Image(systemName: calls.state.symbol ?? (dictation.accessibilityGranted ? dictation.state.symbol : "exclamationmark.triangle"))
        }
        Window("История диктовок", id: "history") {
            HistoryView(history: history, dictation: dictation)
        }
        .defaultSize(width: 560, height: 600)
        .defaultLaunchBehavior(.suppressed)
        Window("История созвонов", id: "call-history") {
            CallHistoryView(calls: calls)
        }
        .defaultSize(width: 820, height: 600)
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
    let calls: Calls
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
        CallMenuItems(calls: calls)
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
        case .formatting: "Оформляю…"
        case .failed(let message): message
        }
    }
}
