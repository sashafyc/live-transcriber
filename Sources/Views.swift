import AVFoundation
import ServiceManagement
import SwiftUI

struct HistoryView: View {
    let history: History
    let dictation: Dictation

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("Пока пусто", systemImage: "waveform",
                                       description: Text("Здесь будут диктовки за последние сутки"))
            } else {
                List(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.date, format: .dateTime.hour().minute())
                            Text("\(Int(entry.seconds.rounded())) с")
                            Text(entry.recognition.model.isEmpty ? entry.recognition.provider.title : entry.recognition.model)
                            Spacer()
                            if let raw = entry.raw {
                                Button("Исходный") { copyToClipboard(raw) }
                                    .help("Скопировать текст до оформления")
                            }
                            if let text = entry.text {
                                Button("Скопировать") { copyToClipboard(text) }
                            } else if entry.audioName != nil, entry.error != nil {
                                Button("Повторить") { dictation.send(entry.id, paste: false) }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let text = entry.text {
                            Text(text.isEmpty ? "(тишина)" : text).textSelection(.enabled)
                        } else if let error = entry.error {
                            Text(error).foregroundStyle(.red)
                        } else {
                            Text("Распознаю…").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }
}

/// Разделы настроек — список слева, как в Системных настройках.
enum SettingsPane: String, CaseIterable, Identifiable {
    case start, dictation, calls, keys, general

    var id: Self { self }

    var title: String {
        switch self {
        case .start: "Первая настройка"
        case .dictation: "Диктовка"
        case .calls: "Созвоны"
        case .keys: "Ключи"
        case .general: "Основные"
        }
    }

    var symbol: String {
        switch self {
        case .start: "hand.wave"
        case .dictation: "mic"
        case .calls: "phone"
        case .keys: "key"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let dictation: Dictation
    @State private var pane: SettingsPane?
    @State private var fresh = Welcome.needed

    /// Окно открывается и из меню, и само при запуске без ключей — сцена Settings так не умеет.
    /// Не поверх всех: из первой настройки человек ходит в Системные настройки.
    static func show(_ settings: AppSettings, _ dictation: Dictation, pane: SettingsPane? = nil) {
        Windows.show("settings", "Настройки", SettingsView(settings: settings, dictation: dictation,
                                                           pane: pane ?? (Welcome.needed ? .start : .dictation)), floating: false)
    }

    init(settings: AppSettings, dictation: Dictation, pane: SettingsPane) {
        self.settings = settings
        self.dictation = dictation
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { Label($0.title, systemImage: $0.symbol) }
                .navigationSplitViewColumnWidth(170)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane ?? .dictation {
                case .start:
                    WelcomeView(settings: settings, dictation: dictation) {
                        Welcome.finish(settings, fresh: fresh)
                        fresh = false
                        pane = .dictation
                    }
                case .dictation: DictationSettings(settings: settings)
                case .calls: CallSettings(settings: settings)
                case .keys: KeySettings(settings: settings)
                case .general: GeneralSettings(settings: settings, dictation: dictation)
                }
            }
            .formStyle(.grouped)
            .navigationTitle((pane ?? .dictation).title)
        }
        .frame(width: 720, height: 620)
    }
}

struct DictationSettings: View {
    @Bindable var settings: AppSettings
    @State private var check = ""
    @State private var checking = false

    var body: some View {
        Form {
            Section("Распознавание") {
                Picker("Провайдер", selection: $settings.dictation.provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.dictation.provider) { _, provider in
                    settings.dictation.model = provider.suggestedModels.first ?? ""
                }
                ModelField(model: $settings.dictation.model, suggestions: settings.dictation.provider.suggestedModels, hints: Provider.hints)
                Picker("Язык", selection: $settings.dictation.language) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                    Text("Определять сам").tag("auto")
                }
                HStack {
                    Button(checking ? "Проверяю…" : "Проверить") { runCheck() }.disabled(checking)
                    Text(check).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }

            Section("Оформление текста") {
                Picker("Оформлять через", selection: $settings.formatting.formatter) {
                    ForEach(Formatter.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.formatting.formatter) { _, formatter in
                    settings.formatting.model = formatter.suggestedModels.first ?? ""
                }
                if settings.formatting.formatter != .off {
                    ModelField(model: $settings.formatting.model, suggestions: settings.formatting.formatter.suggestedModels,
                               hints: Formatter.formattingHints)
                }
                Text("Абзацы, пунктуация, без паразитов и оговорок, смысл не меняется. Фразы короче \(TextFormatter.minWords) слов вставляются сразу. Если оформление не ответило или переписало текст — вставится распознанный как есть, исходник всегда есть в истории.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Клавиша") {
                Picker("Держать для записи", selection: $settings.hotkeyCode) {
                    ForEach(Hotkey.all) { Text($0.name).tag($0.code) }
                }
                if settings.hotkeyCode == 63 {
                    Text("В Системных настройках → Клавиатура для клавиши 🌐 поставь «Ничего не делать», иначе она откроет эмодзи.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runCheck() {
        checking = true
        check = ""
        let setup = settings.dictation
        Task {
            do {
                let text = try await Transcriber.transcribe(try Transcriber.testRecording(), setup)
                check = "Работает: «\(text)»"
            } catch {
                check = error.localizedDescription
            }
            checking = false
        }
    }
}

struct KeySettings: View {
    @Bindable var settings: AppSettings
    @State private var openaiKey = Keychain.get("openai")
    @State private var assemblyaiKey = Keychain.get("assemblyai")
    @State private var customKey = Keychain.get("custom")
    @State private var deepseekKey = Keychain.get("deepseek")

    var body: some View {
        Form {
            Section {
                SecureField("OpenAI", text: $openaiKey)
                    .onChange(of: openaiKey) { _, key in Keychain.set("openai", key) }
                SecureField("AssemblyAI", text: $assemblyaiKey)
                    .onChange(of: assemblyaiKey) { _, key in Keychain.set("assemblyai", key) }
                SecureField("DeepSeek", text: $deepseekKey)
                    .onChange(of: deepseekKey) { _, key in Keychain.set("deepseek", key) }
            } footer: {
                Text("Ключи хранятся в связке ключей macOS. OpenAI из России работает только с VPN.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Свой адрес распознавания") {
                TextField("Адрес", text: $settings.customEndpoint, prompt: Text("http://127.0.0.1:8767/v1/audio/transcriptions"))
                SecureField("Ключ", text: $customKey, prompt: Text("если нужен"))
                    .onChange(of: customKey) { _, key in Keychain.set("custom", key) }
            }
        }
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let dictation: Dictation
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Запуск") {
                Toggle("Запускать при входе в macOS", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
                Toggle("Показывать окно записи созвона при запуске", isOn: $settings.startWindowOnLaunch)
            }
            Section("Разрешения") {
                LabeledContent("Микрофон", value: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "есть" : "нет")
                LabeledContent("Универсальный доступ") {
                    if dictation.accessibilityGranted {
                        Text("есть")
                    } else {
                        Button("Выдать") { openAccessibilitySettings() }
                    }
                }
                if !dictation.accessibilityGranted {
                    Text("Если Live Transcriber в списке уже включён — это запись от прошлой сборки. Удали её кнопкой «−» и добавь приложение заново.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
    }
}

/// Модель вписывается руками или выбирается из подсказок провайдера.
struct ModelField: View {
    @Binding var model: String
    let suggestions: [String]
    var hints: [String: String] = [:]

    /// Подписи к моделям, у которых по имени в API не видно версии.
    private static let notes = ["deepseek-flash": "V4.1 Flash, быстрая", "deepseek-v4-pro": "V4 Pro, в 4 раза дороже"]

    var body: some View {
        LabeledContent("Модель") {
            HStack {
                TextField("Модель", text: $model, prompt: Text("по умолчанию сервиса"))
                    .labelsHidden()
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { name in
                            Button(Self.notes[name].map { "\(name) — \($0)" } ?? name) { model = name }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)  // иначе рядом со своей стрелкой рисуется вторая
                    .fixedSize()
                }
            }
        }
        if let hint = hints[model] {
            Text(hint).font(.callout).foregroundStyle(.secondary)
        }
    }
}
