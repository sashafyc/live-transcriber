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

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let dictation: Dictation
    @State private var openaiKey = Keychain.get("openai")
    @State private var assemblyaiKey = Keychain.get("assemblyai")
    @State private var customKey = Keychain.get("custom")
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var check = ""
    @State private var checking = false

    var body: some View {
        Form {
            Section("Диктовка") {
                Picker("Провайдер", selection: $settings.dictation.provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.dictation.provider) { _, provider in
                    settings.dictation.model = provider.suggestedModels.first ?? ""
                }
                ModelField(model: $settings.dictation.model, suggestions: settings.dictation.provider.suggestedModels)
                Picker("Язык", selection: $settings.dictation.language) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                    Text("Определять сам").tag("auto")
                }
                Picker("Держать для записи", selection: $settings.hotkeyCode) {
                    ForEach(Hotkey.all) { Text($0.name).tag($0.code) }
                }
                if settings.hotkeyCode == 63 {
                    Text("В Системных настройках → Клавиатура для клавиши 🌐 поставь «Ничего не делать», иначе она откроет эмодзи.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(checking ? "Проверяю…" : "Проверить") { runCheck() }.disabled(checking)
                    Text(check).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }

            Section("Ключи") {
                SecureField("OpenAI", text: $openaiKey)
                    .onChange(of: openaiKey) { _, key in Keychain.set("openai", key) }
                SecureField("AssemblyAI", text: $assemblyaiKey)
                    .onChange(of: assemblyaiKey) { _, key in Keychain.set("assemblyai", key) }
                TextField("Свой адрес", text: $settings.customEndpoint, prompt: Text("http://127.0.0.1:8767/v1/audio/transcriptions"))
                SecureField("Ключ своего адреса", text: $customKey, prompt: Text("если нужен"))
                    .onChange(of: customKey) { _, key in Keychain.set("custom", key) }
                Text("Ключи хранятся в связке ключей macOS. OpenAI из России работает только с VPN.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Система") {
                Toggle("Запускать при входе в macOS", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
                LabeledContent("Микрофон", value: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "есть" : "нет")
                LabeledContent("Универсальный доступ") {
                    if dictation.accessibilityGranted {
                        Text("есть")
                    } else {
                        Button("Выдать") { openAccessibilitySettings() }
                    }
                }
                if !dictation.accessibilityGranted {
                    Text("Если Live Transcriber 2 в списке уже включён — это запись от прошлой сборки. Удали её кнопкой «−» и добавь приложение заново.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
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

/// Модель вписывается руками или выбирается из подсказок провайдера.
struct ModelField: View {
    @Binding var model: String
    let suggestions: [String]

    var body: some View {
        LabeledContent("Модель") {
            HStack {
                TextField("Модель", text: $model, prompt: Text("по умолчанию сервиса"))
                    .labelsHidden()
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { name in Button(name) { model = name } }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}
