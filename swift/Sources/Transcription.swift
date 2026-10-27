import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case openai, assemblyai, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: "OpenAI"
        case .assemblyai: "AssemblyAI"
        case .custom: "Свой адрес (OpenAI-совместимый)"
        }
    }

    /// Подсказки в выпадающем списке; вписать можно любую модель.
    var suggestedModels: [String] {
        switch self {
        case .openai: ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
        // 28.10.2026 пакетный API принимает только эти; universal-3-6-pro пока только в потоковом
        case .assemblyai: ["universal-2", "universal-3-5-pro", "universal-3-pro"]
        case .custom: []
        }
    }
}

/// Что и чем распознавать: своё для диктовки и для созвонов.
struct Recognition: Codable, Equatable {
    var provider: Provider
    var model: String
    var language: String  // "auto" — определять сам
}

struct TranscriptionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Transcriber {
    static let customEndpointKey = "customEndpoint"

    static func transcribe(_ audio: URL, _ setup: Recognition) async throws -> String {
        let file = try Data(contentsOf: audio)
        let text: String
        switch setup.provider {
        case .openai, .custom:
            text = try await openAICompatible(file, setup)["text"] as? String ?? ""
        case .assemblyai:
            text = try await assemblyAI(file, setup)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: OpenAI и всё, что говорит на его языке

    /// Ответ целиком: звонкам кроме текста нужны отрезки с временем (`verbose_json`).
    static func openAICompatible(_ file: Data, _ setup: Recognition, filename: String = "audio.m4a",
                                 format: String = "json", timeout: TimeInterval = 120) async throws -> [String: Any] {
        let custom = setup.provider == .custom
        let endpoint = custom ? UserDefaults.standard.string(forKey: customEndpointKey) ?? ""
                              : "https://api.openai.com/v1/audio/transcriptions"
        let key = Keychain.get(custom ? "custom" : "openai")
        guard !endpoint.isEmpty else { throw TranscriptionError("Не задан адрес — открой настройки") }
        guard custom || !key.isEmpty else { throw TranscriptionError("Нет ключа \(setup.provider.title) — открой настройки") }
        guard let url = URL(string: endpoint) else { throw TranscriptionError("Неверный адрес: \(endpoint)") }
        var fields = [("response_format", format)]
        if !setup.model.isEmpty { fields.append(("model", setup.model)) }
        if setup.language != "auto" { fields.append(("language", setup.language)) }
        let form = multipart(fields, file: file, filename: filename)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(form.type, forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (status, json) = try await call(request, form.body)
        guard status == 200, json["text"] is String else {
            throw TranscriptionError("\(setup.provider.title): \(errorText(status, json))")
        }
        return json
    }

    // MARK: AssemblyAI: загрузка → задание → опрос

    static func assemblyAI(_ file: Data, _ setup: Recognition) async throws -> String {
        try await assemblyAIJob(file, languageJob(setup))["text"] as? String ?? ""
    }

    static func languageJob(_ setup: Recognition) -> [String: Any] {
        var job: [String: Any] = ["speech_models": [setup.model]]
        if setup.language == "auto" { job["language_detection"] = true } else { job["language_code"] = setup.language }
        return job
    }

    /// Звонок заливается дольше диктовки: через медленный канал заливка рвётся
    /// по таймауту (проверено 18.09.2026), поэтому у звонков три попытки и запас времени.
    static func assemblyAIJob(_ file: Data, _ job: [String: Any], uploadAttempts: Int = 1, uploadTimeout: TimeInterval = 120,
                              pollEvery: Double = 1, pollFor: Double = 180) async throws -> [String: Any] {
        let key = Keychain.get("assemblyai")
        guard !key.isEmpty else { throw TranscriptionError("Нет ключа AssemblyAI — открой настройки") }
        let base = "https://api.assemblyai.com/v2"

        var upload = URLRequest(url: URL(string: base + "/upload")!, timeoutInterval: uploadTimeout)
        upload.httpMethod = "POST"
        upload.setValue(key, forHTTPHeaderField: "Authorization")
        var status = 0, json: [String: Any] = [:]
        for attempt in 1...uploadAttempts {
            do {
                (status, json) = try await call(upload, file)
                break
            } catch where attempt < uploadAttempts {
                let pause = [3, 8, 20][min(attempt - 1, 2)]
                Log.info("Заливка не удалась (попытка \(attempt) из \(uploadAttempts)): \(error.localizedDescription). Жду \(pause) с")
                try await Task.sleep(for: .seconds(pause))
            }
        }
        guard status == 200, let audioURL = json["upload_url"] as? String else {
            throw TranscriptionError("AssemblyAI: \(errorText(status, json))")
        }

        var job = job
        job["audio_url"] = audioURL
        var create = URLRequest(url: URL(string: base + "/transcript")!, timeoutInterval: 60)
        create.httpMethod = "POST"
        create.setValue(key, forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        (status, json) = try await call(create, try JSONSerialization.data(withJSONObject: job))
        guard status == 200, let id = json["id"] as? String else {
            throw TranscriptionError("AssemblyAI: \(errorText(status, json))")
        }

        var poll = URLRequest(url: URL(string: base + "/transcript/\(id)")!, timeoutInterval: 60)
        poll.setValue(key, forHTTPHeaderField: "Authorization")
        for _ in 0..<Int(pollFor / pollEvery) {
            try await Task.sleep(for: .seconds(pollEvery))
            (status, json) = try await call(poll)
            switch json["status"] as? String {
            case "completed": return json
            case "error": throw TranscriptionError("AssemblyAI: \(json["error"] as? String ?? "ошибка распознавания")")
            default: continue
            }
        }
        throw TranscriptionError("AssemblyAI не ответил за \(Int(pollFor / 60)) мин")
    }

    // MARK: Общее

    static func call(_ request: URLRequest, _ body: Data? = nil) async throws -> (Int, [String: Any]) {
        let (data, response) = if let body {
            try await URLSession.shared.upload(for: request, from: body)
        } else {
            try await URLSession.shared.data(for: request)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    static func errorText(_ status: Int, _ json: [String: Any]) -> String {
        let detail = (json["error"] as? [String: Any])?["message"] as? String ?? json["error"] as? String ?? ""
        return "HTTP \(status) \(detail)".trimmingCharacters(in: .whitespaces)
    }

    static func multipart(_ fields: [(String, String)], file: Data, filename: String = "audio.m4a") -> (body: Data, type: String) {
        let boundary = "LiveTranscriber-" + UUID().uuidString
        var body = Data()
        for (name, value) in fields {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(filename.hasSuffix(".flac") ? "audio/flac" : "audio/mp4")\r\n\r\n".utf8)
        body += file
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// Проверка провайдера из терминала, ключи берутся из связки: LiveTranscriber --check assemblyai [модель]
    static func checkFromCommandLine() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[1] == "--check", let provider = Provider(rawValue: arguments[2]) else { return }
        let model = arguments.count > 3 ? arguments[3] : provider.suggestedModels.first ?? ""
        let setup = Recognition(provider: provider, model: model, language: "ru")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                print(try await transcribe(try testRecording(), setup))
            } catch {
                print("ОШИБКА: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// Фраза для кнопки «Проверить»: синтез речи macOS → m4a, без микрофона.
    static func testRecording() throws -> URL {
        let temp = FileManager.default.temporaryDirectory
        let aiff = temp.appendingPathComponent("lt-check.aiff"), m4a = temp.appendingPathComponent("lt-check.m4a")
        try? FileManager.default.removeItem(at: m4a)
        for (tool, arguments) in [
            ("/usr/bin/say", ["-v", "Milena", "-o", aiff.path, "Проверка связи"]),
            ("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-r", "16000", "-c", "1", aiff.path, m4a.path]),
        ] {
            let process = try Process.run(URL(fileURLWithPath: tool), arguments: arguments)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw TranscriptionError("Не получилось сделать тестовую запись") }
        }
        return m4a
    }
}
