import AppKit
import SwiftUI

/// Окна, которые появляются сами (старт при запуске, итог после обработки): их открывает
/// не меню, поэтому они на AppKit, а не сценами SwiftUI. Все немодальные — пока открыто
/// модальное окно, меню в строке состояния не отвечает.
enum Windows {
    private static var open: [String: NSWindow] = [:]

    static func show(_ id: String, _ title: String, _ view: some View, floating: Bool = true) {
        open[id]?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        if floating { window.level = .floating }  // окно появляется само и не должно уйти за другие
        window.center()
        open[id] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    static func close(_ id: String) {
        open.removeValue(forKey: id)?.close()
    }

    static func info(_ title: String, _ message: String) {
        let id = "info-\(UUID().uuidString)"
        show(id, title, VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(Markup.attributed(message)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Закрыть") { close(id) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440))
    }
}

struct StartCallView: View {
    let mic: String
    let output: String
    let onStart: (String, String, Bool) -> Void
    let onCheck: () -> Void
    @State private var title = "Созвон"
    @State private var prompt: String
    @State private var external = false

    init(mic: String, output: String, prompt: String, onStart: @escaping (String, String, Bool) -> Void, onCheck: @escaping () -> Void) {
        self.mic = mic
        self.output = output
        self.onStart = onStart
        self.onCheck = onCheck
        _prompt = State(initialValue: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Название", text: $title)
            Text("Что сделать с записью:")
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            Toggle("Внешний созвон — писать только микрофон", isOn: $external)
            VStack(alignment: .leading, spacing: 2) {
                Text("Микрофон: \(mic)")
                // Разговор идёт мимо компьютера: пустая вторая дорожка родила бы выдуманные титры
                Text(external ? "Собеседник слышен через микрофон, системный звук не пишется"
                    : "Выход: \(output) · собеседник пишется, выход не переключается")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Начать запись") {
                    let name = title.trimmingCharacters(in: .whitespaces)
                    let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    onStart(name.isEmpty ? "Созвон" : name, task.isEmpty ? Summary.defaultPrompt : task, external)
                }
                .keyboardShortcut(.defaultAction)
                Button("Проверить звук", action: onCheck)
                Spacer()
                Button("Отмена") { Windows.close("start") }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct SummaryView: View {
    let summary: String
    let note: String
    let folder: URL
    let onSend: () async -> String
    @State private var status = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                Text(Markup.attributed(summary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.background)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Button("Скопировать") {
                    copyToClipboard(Markup.normalize(summary))
                    status = "Скопировано"
                }
                .keyboardShortcut(.defaultAction)
                Button(sending ? "Отправляю…" : "Отправить в Telegram") {
                    sending = true
                    Task {
                        status = await onSend()
                        sending = false
                    }
                }
                .disabled(sending)
                Button("Показать файлы") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Text(status).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 540)
    }
}

/// Записи за 30 дней: итог или расшифровка, «Расшифровать заново», пока жив звук.
struct CallHistoryView: View {
    let calls: Calls
    @State private var records: [CallRecord] = []
    @State private var selection: CallRecord.ID?
    @State private var showTranscript = false

    private var current: CallRecord? { records.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            List(records, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).lineLimit(1)
                    Text(record.label + (FileManager.default.fileExists(atPath: record.summaryURL.path) ? "" : " · без итога"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
            VStack(alignment: .leading, spacing: 10) {
                if let record = current {
                    let text = showTranscript ? record.transcript() : record.summary()
                    Picker("", selection: $showTranscript) {
                        Text("Итог").tag(false)
                        Text("Расшифровка").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ScrollView {
                        Text(Markup.attributed(text.isEmpty ? (showTranscript ? "Расшифровка пустая" : "Итог не сохранился") : text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    HStack {
                        Button("Скопировать") { copyToClipboard(Markup.normalize(text)) }
                        Button("Показать файлы") { NSWorkspace.shared.activateFileViewerSelecting([record.url]) }
                        Button("Расшифровать заново") { calls.redo(record) }
                            .disabled(!record.hasAudio || calls.state != .idle)
                            .help(record.hasAudio ? "Запись уйдёт целиком, одним куском" : "Звук хранится неделю и уже удалён")
                    }
                } else {
                    ContentUnavailableView("Пока пусто", systemImage: "phone",
                                           description: Text("Записи хранятся \(Int(CallRecord.keepDays)) дней"))
                }
            }
            .padding(12)
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear {
            records = CallRecord.all()
            selection = selection ?? records.first?.id
        }
        .onChange(of: calls.state) { _, state in
            if state == .idle { records = CallRecord.all() }
        }
    }
}

struct SoundReportView: View {
    let report: SoundReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !report.problems.isEmpty { Text(report.problems.joined(separator: "; ")).bold() }
            Text(report.lines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
    }
}

/// Пункты звонков в меню строки состояния.
struct CallMenuItems: View {
    let calls: Calls
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch calls.state {
        case .idle:
            Button("Начать запись созвона…") { calls.openStart() }
        case .recording, .silent:
            Text(calls.state == .silent ? "«\(calls.title)»: микрофон молчит" : "Идёт запись «\(calls.title)»")
            Button("Остановить и получить итог") { calls.stop() }
        case .processing:
            Text("Обрабатываю «\(calls.title)»…")
        }
        Button("История созвонов…") {
            NSApp.activate()
            openWindow(id: "call-history")
        }
        Button("Проверить звук") { calls.checkSound() }
            .disabled(calls.state != .idle)
        Button("Папка с записями") {
            try? FileManager.default.createDirectory(at: CallRecord.dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(CallRecord.dir)
        }
    }
}

/// Своё распознавание для звонков: дорожки и голоса делит только AssemblyAI.
struct CallSettings: View {
    @Bindable var settings: AppSettings
    @State private var telegramToken = Keychain.get("telegram")
    @State private var check = ""
    @State private var checking = false

    var body: some View {
        Form {
            Section("Распознавание") {
                Picker("Провайдер", selection: $settings.calls.provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.calls.provider) { _, provider in
                    settings.calls.model = provider.suggestedModels.first ?? ""
                }
                ModelField(model: $settings.calls.model, suggestions: settings.calls.provider.suggestedModels, hints: Provider.hints)
                Picker("Язык", selection: $settings.calls.language) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                    Text("Определять сам").tag("auto")
                }
                if settings.calls.provider != .assemblyai {
                    Text("Голоса на одной дорожке делит только AssemblyAI. Здесь дорожки «Я» и «Собеседник» расшифруются по отдельности.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Итог") {
                Picker("Делать через", selection: $settings.summary.formatter) {
                    ForEach(Formatter.allCases.filter { $0 != .off }) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.summary.formatter) { _, formatter in
                    settings.summary.model = formatter.suggestedModels.first ?? ""
                }
                ModelField(model: $settings.summary.model, suggestions: settings.summary.formatter.suggestedModels,
                           hints: Formatter.summaryHints)
                LabeledContent("Задание для итога") {
                    TextEditor(text: $settings.callPrompt).font(.system(size: 11)).frame(height: 90)
                }
            }
            Section("Telegram") {
                Toggle("Отправлять итог в Telegram", isOn: $settings.sendToTelegram)
                SecureField("Токен бота", text: $telegramToken)
                    .onChange(of: telegramToken) { _, key in Keychain.set("telegram", key) }
                TextField("Чат", text: $settings.telegramChat, prompt: Text("ссылка на сообщение в чате или теме"))
            }
            Section {
                HStack {
                    Button(checking ? "Проверяю…" : "Проверить ключи") { runCheck() }.disabled(checking)
                    Text(check).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func runCheck() {
        checking = true
        check = ""
        let chat = settings.telegramChat, summary = settings.summary
        Task {
            var lines: [String] = []
            do {
                let (status, _) = try await Transcriber.call({
                    var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!, timeoutInterval: 15)
                    request.setValue(Keychain.get("assemblyai"), forHTTPHeaderField: "Authorization")
                    return request
                }())
                lines.append(status == 200 ? "✅ AssemblyAI: ключ рабочий" : "❌ AssemblyAI: HTTP \(status)")
            } catch {
                lines.append("❌ AssemblyAI: \(error.localizedDescription)")
            }
            lines.append(await Summary.checkKey(summary))
            lines.append(await Telegram.check(chat: chat))
            check = lines.joined(separator: "\n")
            checking = false
        }
    }
}
