import AVFoundation
import SwiftUI

/// Первый запуск: разрешения и ключи по шагам — что нажать, где взять, куда вставить.
enum Welcome {
    private static let doneKey = "welcomeDone"

    /// Показываем сами только тому, у кого ещё нет ни одного ключа: старых пользователей не дёргаем.
    static var needed: Bool {
        !UserDefaults.standard.bool(forKey: doneKey) && ["openai", "assemblyai", "deepseek"].allSatisfy { Keychain.get($0).isEmpty }
    }

    static func show(_ settings: AppSettings, _ dictation: Dictation) {
        Windows.show("welcome", "Live Transcriber — первая настройка", WelcomeView(settings: settings, dictation: dictation) {
            settings.adjustToKeys(firstRun: !UserDefaults.standard.bool(forKey: doneKey))
            UserDefaults.standard.set(true, forKey: doneKey)
            Windows.close("welcome")
        }, floating: false)  // человек будет ходить в Системные настройки — окно не должно их закрывать
    }
}

struct WelcomeView: View {
    let settings: AppSettings
    let dictation: Dictation
    let done: () -> Void
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section {
                Text("Диктовка по клавише Fn и запись созвонов с расшифровкой и итогом. Распознают сервисы по твоим ключам: платишь им напрямую, копейки за минуту. Три шага — и можно говорить.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("1. Разрешения") {
                LabeledContent("Микрофон") {
                    if microphone == .authorized {
                        Text("✅ есть")
                    } else {
                        Button("Разрешить") { askMicrophone() }
                    }
                }
                LabeledContent("Универсальный доступ") {
                    if dictation.accessibilityGranted {
                        Text("✅ есть")
                    } else {
                        Button("Открыть настройки") { openAccessibilitySettings() }
                    }
                }
                if !dictation.accessibilityGranted {
                    Text("Нужен, чтобы ловить клавишу Fn и вставлять текст. В открывшемся списке включи Live Transcriber. Если его нет — нажми «+» и выбери его в Программах.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Запись звука собеседника macOS спросит сама, при первом созвоне.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("2. Ключ OpenAI — главный") {
                KeyStep(account: "openai", title: "Ключ OpenAI", steps: [
                    ("Зайди на platform.openai.com и войди или зарегистрируйся.", nil),
                    ("Пополни баланс: хватит $5 на месяцы диктовки.", "https://platform.openai.com/settings/organization/billing/overview"),
                    ("Создай ключ: Create new secret key → скопируй его и вставь ниже.", "https://platform.openai.com/api-keys"),
                ], note: "Одного этого ключа хватает на всё: диктовку, оформление текста, созвоны и итоги. Из России OpenAI работает только с VPN.") {
                    try await Transcriber.transcribe(try Transcriber.testRecording(),
                                                     Recognition(provider: .openai, model: "gpt-4o-transcribe", language: "ru"))
                }
            }

            Section("3. По желанию") {
                KeyStep(account: "deepseek", title: "Ключ DeepSeek", steps: [
                    ("Пополни баланс от $2 на platform.deepseek.com.", "https://platform.deepseek.com/top_up"),
                    ("Создай ключ: Create new API key → вставь ниже.", "https://platform.deepseek.com/api_keys"),
                ], note: "Оформляет диктовку быстрее и дешевле OpenAI и работает без VPN. Если OpenAI не ответит, итог созвона сделает DeepSeek.") {
                    let (status, json) = try await Formatter.deepseek.chat("deepseek-flash", [["role": "user", "content": "ответь словом ок"]],
                                                                           temperature: 0, maxTokens: 16, timeout: 30)
                    guard status == 200 else { throw TranscriptionError("DeepSeek: \(Transcriber.errorText(status, json))") }
                    return ""
                }
                KeyStep(account: "assemblyai", title: "Ключ AssemblyAI", steps: [
                    ("Зарегистрируйся на assemblyai.com: новым аккаунтам дают бесплатные минуты.", "https://www.assemblyai.com/dashboard/signup"),
                    ("Скопируй ключ из API Keys → вставь ниже.", "https://www.assemblyai.com/dashboard/api-keys"),
                ], note: "Различает голоса на созвоне: в расшифровке будет видно, кто что сказал.") {
                    try await Transcriber.transcribe(try Transcriber.testRecording(),
                                                     Recognition(provider: .assemblyai, model: "universal-2", language: "ru"))
                }
            }

            Section("Готово") {
                Text("Держи Fn 🌐 и говори — отпустишь, и текст вставится туда, где стоит курсор. Чтобы Fn не открывал эмодзи, в Системных настройках → Клавиатура поставь для 🌐 «Ничего не делать».")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Созвоны — в меню под значком волны в строке меню вверху экрана. Модели, Telegram для итогов и всё остальное — в Настройках.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Настройки клавиатуры") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    Spacer()
                    Button("Готово", action: done).keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 760)
    }

    private func askMicrophone() {
        guard microphone == .notDetermined else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { microphone = AVCaptureDevice.authorizationStatus(for: .audio) }
        }
    }
}

/// Шаг с ключом: где взять (со ссылками), поле и проверка.
private struct KeyStep: View {
    let account: String
    let title: String
    let steps: [(String, String?)]
    let note: String
    let check: () async throws -> String
    @State private var key = ""
    @State private var result = ""
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1). \(step.0)").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let link = step.1 {
                        Link("Открыть", destination: URL(string: link)!)
                    }
                }
            }
            HStack {
                SecureField(title, text: $key, prompt: Text("вставь ключ"))
                    .onChange(of: key) { _, value in Keychain.set(account, value.trimmingCharacters(in: .whitespacesAndNewlines)) }
                Button(checking ? "Проверяю…" : "Проверить") { runCheck() }.disabled(checking || key.isEmpty)
            }
            if !result.isEmpty {
                Text(result).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .onAppear { key = Keychain.get(account) }
    }

    private func runCheck() {
        checking = true
        result = ""
        Task {
            do {
                _ = try await check()
                result = "✅ Ключ работает"
            } catch {
                result = "❌ \(error.localizedDescription)"
            }
            checking = false
        }
    }
}
