import Foundation

/// Итог созвона нейросетью из настроек. Длинные разговоры сводятся по частям.
enum Summary {
    static let defaultPrompt = """
        Итог созвона. Формат:
        1. Ключевые мысли и идеи — по спикерам
        2. Важные детали, факты, цифры — ничего не упускать
        3. Договорённости и планы — реестр: кто, что, когда
        4. Личное / эмоциональное — эмоции спикеров, на что обратить внимание
        Не определяй рабочий или не рабочий созвон. Просто дай итог.
        """
    private static let system = """
        Ты помощник, который делает итоги рабочих и личных разговоров на русском языке. \
        Пиши по делу, без воды и канцелярита. Ничего не выдумывай: если чего-то в транскрипте нет, не пиши об этом.
        Итог читают в Telegram, поэтому оформляй так: подзаголовок раздела — отдельной строкой жирным через \
        **двойные звёздочки**, пункты — с дефиса. Не используй таблицы и решётки для заголовков: в Telegram они \
        не работают. Договорённости оформляй пунктами вида «кто — что — срок».
        """
    // Часовой разговор — около 40 тысяч символов, влезает целиком; длиннее режем, иначе упрёмся в контекст
    private static let maxDirect = 120_000
    private static let part = 90_000

    static func make(_ transcript: String, prompt: String, with setup: Formatting) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError("Транскрипт пустой, сводить нечего") }
        guard text.count > maxDirect else {
            Log.info("Итог: один запрос, \(text.count) символов")
            return try await ask(prompt, text, setup)
        }
        let parts = stride(from: 0, to: text.count, by: part).map {
            String(text.dropFirst($0).prefix(part))
        }
        Log.info("Итог: длинный разговор, \(text.count) символов → \(parts.count) частей")
        var digests: [String] = []
        for (index, piece) in parts.enumerated() {
            let digest = try await ask("Это часть \(index + 1) из \(parts.count) длинного разговора. Выпиши подробно всё важное: "
                + "мысли, факты, цифры, договорённости. Без вступления и выводов.", piece, setup, maxTokens: 3000)
            digests.append("--- Часть \(index + 1) ---\n\(digest)")
        }
        return try await ask(prompt + "\n\nНиже — конспекты частей разговора по порядку.", digests.joined(separator: "\n\n"), setup)
    }

    private static func ask(_ prompt: String, _ text: String, _ setup: Formatting, maxTokens: Int = 4000) async throws -> String {
        let (status, json) = try await setup.formatter.chat(setup.model, [
            ["role": "system", "content": system],
            ["role": "user", "content": "\(prompt)\n\nТранскрипт:\n\n\(text)"],
        ], temperature: 0.3, maxTokens: maxTokens, timeout: 300)
        guard status == 200, let content = Formatter.reply(json) else {
            throw TranscriptionError("\(setup.formatter.title): \(Transcriber.errorText(status, json))")
        }
        return content
    }

    static func checkKey(_ setup: Formatting) async -> String {
        let name = "\(setup.formatter.title) \(setup.model)"
        do {
            let (status, json) = try await setup.formatter.chat(setup.model, [["role": "user", "content": "ответь словом ок"]],
                                                                temperature: 0, maxTokens: 16, timeout: 30)
            switch status {
            case 200: return "✅ \(name): ключ и модель рабочие"
            case 402: return "❌ \(name): на балансе нет средств"
            default: return "❌ \(name): \(Transcriber.errorText(status, json))"
            }
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }
}

/// Отправка итога в чат или тему группы через бота.
enum Telegram {
    private static let maxMessage = 4000  // лимит 4096, запас на разметку

    /// Чат из ссылки: `https://t.me/c/123/42` → (-100123, тема 42), `@канал`, `-100123/42`.
    static func parseChat(_ value: String) -> (chat: String, thread: Int?) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = value.firstMatch(of: #/t\.me\/c\/(\d+)(?:\/(\d+))?/#) {
            return ("-100" + match.1, match.2.flatMap { Int($0) })
        }
        if let match = value.firstMatch(of: #/t\.me\/(?:s\/)?([A-Za-z][\w_]{3,})/#) { return ("@" + match.1, nil) }
        if let match = value.wholeMatch(of: #/(-?\d+)(?:\/(\d+))?/#) { return (String(match.1), match.2.flatMap { Int($0) }) }
        return (value, nil)
    }

    static func send(_ text: String, chat link: String) async throws {
        let token = Keychain.get("telegram")
        let (chat, thread) = parseChat(link)
        guard !token.isEmpty, !chat.isEmpty else { throw TranscriptionError("Не заданы токен бота или чат") }
        var sent = 0
        for part in split(Markup.telegramHTML(text)) {
            var payload: [String: Any] = ["chat_id": chat, "text": part, "disable_web_page_preview": true]
            if let thread { payload["message_thread_id"] = thread }
            // HTML ломается только на незакрытых тегах; если сломался — шлём тот же текст без разметки
            var (status, json) = try await call("sendMessage", payload.merging(["parse_mode": "HTML"]) { $1 })
            if status != 200 {
                Log.error("Telegram отверг разметку (\(status)), шлю простым текстом")
                payload["text"] = Markup.plain(part)
                (status, json) = try await call("sendMessage", payload)
            }
            guard status == 200 else { throw TranscriptionError("Telegram: \(json["description"] as? String ?? "HTTP \(status)")") }
            sent += 1
        }
        Log.info("Итог отправлен в Telegram: \(sent) сообщений")
    }

    static func check(chat link: String) async -> String {
        guard !Keychain.get("telegram").isEmpty else { return "❌ Telegram: токен не задан" }
        guard let (status, json) = try? await call("getMe", nil), status == 200 else { return "❌ Telegram: токен не принят" }
        let name = (json["result"] as? [String: Any])?["username"] as? String ?? "?"
        let (chat, thread) = parseChat(link)
        if chat.isEmpty { return "⚠️ Telegram: бот @\(name), но чат не задан" }
        return "✅ Telegram: бот @\(name), чат \(chat)" + (thread.map { ", тема \($0)" } ?? "")
    }

    /// Адрес с токеном в лог не пишем: по нему любой отправит сообщение от имени бота.
    private static func call(_ method: String, _ payload: [String: Any]?) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(Keychain.get("telegram"))/\(method)")!,
                                 timeoutInterval: 60)
        guard let payload else { return try await Transcriber.call(request) }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await Transcriber.call(request, try JSONSerialization.data(withJSONObject: payload))
    }

    /// Режем по абзацам, чтобы не рвать предложения.
    private static func split(_ text: String) -> [String] {
        guard text.count > maxMessage else { return [text] }
        var parts: [String] = [], current = ""
        for var block in text.components(separatedBy: "\n\n") {
            if current.count + block.count + 2 > maxMessage, !current.isEmpty {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            while block.count > maxMessage {
                parts.append(String(block.prefix(maxMessage)))
                block = String(block.dropFirst(maxMessage))
            }
            current += block + "\n\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts
    }
}

/// Модель отвечает обычным markdown, но ни Telegram, ни окно не показывают заголовки решётками
/// и таблицы. Здесь разметка приводится к общему виду — жирные подзаголовки, точки списка,
/// таблицы строками, — а уже потом каждый получатель рисует её по-своему.
enum Markup {
    // Подписи колонок, которые ничего не добавляют к строке
    private static let noisyHeaders: Set = ["кто", "что", "когда", "срок", "кому", "статус"]

    static func normalize(_ markdown: String) -> String {
        var out: [String] = [], table: [[String]] = []
        func flush() {
            out += tableRows(table)
            table = []
        }
        for line in markdown.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("|"), stripped.hasSuffix("|"), stripped.filter({ $0 == "|" }).count >= 2 {
                table.append(stripped.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            }
            flush()
            if let heading = line.wholeMatch(of: ##/\s*#{1,6}\s*(.+?)\s*/##) {
                // Заголовок мог уже прийти жирным — двойных звёздочек быть не должно
                let title = String(heading.1).replacing(#/\*\*(.+?)\*\*/#) { String($0.1) }
                out.append("**\(title.hasSuffix(":") ? String(title.dropLast()) : title)**")
            } else if let bullet = line.wholeMatch(of: #/(\s*)[-*+]\s+(.+)/#) {
                out.append((bullet.1.count >= 2 ? "   " : "") + "• \(bullet.2)")
            } else {
                out.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n").replacing(#/\n{3,}/#, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableRows(_ table: [[String]]) -> [String] {
        let rows = table.filter { !$0.allSatisfy { $0.wholeMatch(of: #/:?-{2,}:?/#) != nil } }
        guard !rows.isEmpty else { return [] }
        let header = rows.count > 1 ? rows[0] : []
        return (header.isEmpty ? rows : Array(rows.dropFirst())).compactMap { row in
            let parts = row.enumerated().compactMap { index, cell -> String? in
                guard !cell.isEmpty else { return nil }
                let name = index < header.count ? header[index] : ""
                return !name.isEmpty && !noisyHeaders.contains(name.lowercased()) ? "\(name): \(cell)" : cell
            }
            return parts.isEmpty ? nil : "• " + parts.joined(separator: " — ")
        }
    }

    /// Для окна: жирный рисуется шрифтом, а не звёздочками.
    static func attributed(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(normalize(markdown))
        while let match = rest.firstMatch(of: #/\*\*(.+?)\*\*/#.dotMatchesNewlines()) {
            result += AttributedString(String(rest[..<match.range.lowerBound]))
            var bold = AttributedString(String(match.1))
            bold.inlinePresentationIntent = .stronglyEmphasized
            result += bold
            rest = rest[match.range.upperBound...]
        }
        return result + AttributedString(String(rest))
    }

    static func telegramHTML(_ markdown: String) -> String {
        var text = normalize(markdown)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        text = text.replacing(#/\*\*(.+?)\*\*/#.dotMatchesNewlines()) { "<b>\($0.1)</b>" }
        text = text.replacing(#/__(.+?)__/#.dotMatchesNewlines()) { "<b>\($0.1)</b>" }
        text = text.replacing(#/`([^`\n]+?)`/#) { "<code>\($0.1)</code>" }
        // В литералах Swift нет просмотра назад, поэтому курсив — через NSRegularExpression
        let italic = try! NSRegularExpression(pattern: #"(?<![\w*])\*([^*\n]+?)\*(?![\w*])"#)
        text = italic.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<i>$1</i>")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plain(_ html: String) -> String {
        html.replacing(#/<[^>]+>/#, with: "")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
