import Foundation

/// Распознавание по подписке ChatGPT — тем же адресом, что и диктовка в Codex. Ключ API не нужен:
/// берётся вход из приложения ChatGPT/Codex (`~/.codex/auth.json`), продлевает его сам Codex.
/// Модель выбирает ChatGPT. Очень длинную запись (25 мин) адрес не принимает, 12 мин проходят.
actor ChatGPTSubscription {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    private static let authFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    private static let codexPaths = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    private static let shared = ChatGPTSubscription()

    static func transcribe(_ file: Data, filename: String, language: String, timeout: TimeInterval) async throws -> String {
        var headers = try await shared.headers()
        let form = Transcriber.multipart(language == "auto" ? [] : [("language", language)], file: file, filename: filename)
        var renewed = false
        for attempt in 1...3 {
            var request = URLRequest(url: endpoint, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue(form.type, forHTTPHeaderField: "Content-Type")
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await URLSession.shared.upload(for: request, from: form.body)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard let text = json?["text"] as? String else { throw TranscriptionError("ChatGPT ответил без текста") }
                return text
            case 401 where !renewed:
                renewed = true
                headers = try await shared.headers(rejected: headers["Authorization"])
            case 401:
                throw TranscriptionError("ChatGPT: вход устарел — открой ChatGPT и войди заново")
            case 403 where http?.value(forHTTPHeaderField: "cf-mitigated") == "challenge":
                throw TranscriptionError("ChatGPT не пускает с этой сети: Cloudflare требует проверку браузера. Смени сервер VPN или сеть")
            case 429:
                throw TranscriptionError("ChatGPT временно ограничил распознавание, попробуй позже")
            case let status where status >= 500 && attempt < 3:
                try await Task.sleep(for: .seconds(3))
            case let status:
                throw TranscriptionError("ChatGPT: HTTP \(status)")
            }
        }
        throw TranscriptionError("ChatGPT не ответил")
    }

    /// Заголовки входа. Вход продлевается, если истекает в ближайшую минуту или его только что отвергли.
    private func headers(rejected: String? = nil) throws -> [String: String] {
        var tokens = try Self.loadLogin()
        let token = tokens["access_token"] ?? ""
        if Self.expiry(token) < Date().addingTimeInterval(60) || rejected == "Bearer " + token {
            try Self.refreshLogin()
            tokens = try Self.loadLogin()
        }
        var headers = ["Authorization": "Bearer " + (tokens["access_token"] ?? ""), "Originator": "codex-desktop"]
        if let account = tokens["account_id"], !account.isEmpty { headers["ChatGPT-Account-Id"] = account }
        return headers
    }

    private static func loadLogin() throws -> [String: String] {
        guard let data = try? Data(contentsOf: authFile),
              let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranscriptionError("Нет входа в ChatGPT: установи приложение ChatGPT, открой в нём Codex и войди своим аккаунтом")
        }
        guard auth["auth_mode"] as? String == "chatgpt", let tokens = auth["tokens"] as? [String: Any],
              tokens["access_token"] is String else {
            throw TranscriptionError("В Codex нужен вход через подписку ChatGPT, а не ключ API")
        }
        return tokens.compactMapValues { $0 as? String }
    }

    private static func expiry(_ token: String) -> Date {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return .distantPast }
        var segment = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        segment += String(repeating: "=", count: (4 - segment.count % 4) % 4)
        guard let data = Data(base64Encoded: segment),
              let exp = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["exp"] as? Double else { return .distantPast }
        return Date(timeIntervalSince1970: exp)
    }

    /// Продление и хранение входа целиком на Codex: просим его перечитать аккаунт с обновлением токена.
    private static func refreshLogin() throws {
        guard let codex = codexPaths.first(where: FileManager.default.isExecutableFile) else {
            throw TranscriptionError("Вход в ChatGPT истёк, а продлить нечем: нужно приложение ChatGPT с Codex")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        // Завис — гасим через 30 с, чтение тогда вернёт пустоту
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }

        var buffer = Data()
        func send(_ message: [String: Any]) throws {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["id": id, "method": method, "params": params])
            while true {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          reply["id"] as? Int == id else { continue }
                    guard reply["error"] == nil, let result = reply["result"] as? [String: Any] else {
                        throw TranscriptionError("Codex не продлил вход в ChatGPT — открой ChatGPT и войди заново")
                    }
                    return result
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw TranscriptionError("Codex не ответил при продлении входа в ChatGPT") }
                buffer += chunk
            }
        }
        _ = try request(1, "initialize", ["clientInfo": ["name": "live_transcriber", "version": "1.0.0"]])
        try send(["method": "initialized", "params": [String: Any]()])
        let result = try request(2, "account/read", ["refreshToken": true])
        guard (result["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
            throw TranscriptionError("В Codex нужен вход через подписку ChatGPT")
        }
    }
}
