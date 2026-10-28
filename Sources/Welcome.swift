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
        // Новый человек — тот, у кого при открытии окна не было ни одного ключа: настроенное не трогаем
        let fresh = needed
        Windows.show("welcome", "Live Transcriber — первая настройка", WelcomeView(settings: settings, dictation: dictation) {
            settings.adjustToKeys(firstRun: fresh)
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
                Text("Диктовка по клавише Fn и запись созвонов с расшифровкой и итогом. Распознают сервисы по твоим ключам: платишь им напрямую, копейки за минуту. Нужны два ключа — три шага, и можно говорить.")
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

            Section("2. Ключ AssemblyAI — распознавание") {
                KeyStep(account: "assemblyai", title: "Ключ AssemblyAI", steps: [
                    ("Зарегистрируйся на assemblyai.com.", "https://www.assemblyai.com/dashboard/signup"),
                    ("Скопируй ключ из API Keys и вставь ниже.", "https://www.assemblyai.com/dashboard/api-keys"),
                ], note: "Переводит речь в текст — и диктовку, и созвоны, а на созвоне различает, кто что сказал. При регистрации дают бесплатный баланс на сотни часов. Работает без VPN.") {
                    try await Transcriber.transcribe(try Transcriber.testRecording(),
                                                     Recognition(provider: .assemblyai, model: "universal-2", language: "ru"))
                }
            }

            Section("3. Один ключ на выбор — оформление и итоги") {
                Text("Нейросеть расставит в диктовке абзацы и пунктуацию, уберёт «ну» и «короче» и сделает итог созвона. Хватит одного ключа: DeepSeek дешевле и работает без VPN, OpenAI ещё и распознаёт диктовку быстрее.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                KeyStep(account: "deepseek", title: "Ключ DeepSeek", steps: [
                    ("Пополни баланс на platform.deepseek.com: $2–5 хватит на месяцы.", "https://platform.deepseek.com/top_up"),
                    ("Создай ключ: Create new API key → вставь ниже.", "https://platform.deepseek.com/api_keys"),
                ], note: "Дешевле всех и без VPN.") {
                    let (status, json) = try await Formatter.deepseek.chat("deepseek-flash", [["role": "user", "content": "ответь словом ок"]],
                                                                           temperature: 0, maxTokens: 16, timeout: 30)
                    guard status == 200 else { throw TranscriptionError("DeepSeek: \(Transcriber.errorText(status, json))") }
                    return ""
                }
                KeyStep(account: "openai", title: "Ключ OpenAI", steps: [
                    ("Пополни баланс на platform.openai.com: $5 хватит на месяцы.", "https://platform.openai.com/settings/organization/billing/overview"),
                    ("Создай ключ: Create new secret key → вставь ниже.", "https://platform.openai.com/api-keys"),
                ], note: "Аккуратнее всех с итогами созвонов, а диктовку можно переключить на распознавание через OpenAI: ждать 1–2 секунды вместо 3–5. Из России — только с VPN.") {
                    try await Transcriber.transcribe(try Transcriber.testRecording(),
                                                     Recognition(provider: .openai, model: "gpt-4o-transcribe", language: "ru"))
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
