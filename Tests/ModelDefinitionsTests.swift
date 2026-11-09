import Foundation

private struct TestFailure: Error {
    let message: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

private final class StubProtocol: URLProtocol {
    static var respond: (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

@main struct ModelDefinitionsTests {
    static func completion(_ content: String?, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [
            ["message": ["content": content as Any? ?? NSNull()], "finish_reason": finish]
        ]])
    }

    @MainActor static func main() async throws {
        var settings = DefinitionSettings()
        try require(settings.source == .dictionary && settings.provider == .deepseek, "Initial source and provider")
        let deepseekEndpoint = try settings.endpoint()
        try require(deepseekEndpoint.absoluteString == "https://api.deepseek.com/chat/completions", "DeepSeek endpoint")
        settings.provider = .custom
        settings.customModel = "custom-model"
        for (address, expected) in [
            ("https://example.com/v1", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1?api-version=2026", "https://example.com/v1/chat/completions?api-version=2026"),
            ("http://localhost:1234/v1", "http://localhost:1234/v1/chat/completions")
        ] {
            settings.customURL = address
            let endpoint = try settings.endpoint()
            try require(endpoint.absoluteString == expected, "Custom endpoint normalization")
        }
        for address in ["", "example.com", "file:///tmp", "https://user:password@example.com/v1", "https://example.com/#fragment"] {
            settings.customURL = address
            do {
                _ = try settings.endpoint()
                throw TestFailure(message: "Invalid endpoint accepted")
            } catch is ModelFailure {}
        }
        settings.customURL = "https://example.com/v1"
        do {
            try settings.validate(apiKey: "")
            throw TestFailure(message: "Missing key accepted")
        } catch is ModelFailure {}
        do {
            try settings.validate(apiKey: "key\ninjected-header")
            throw TestFailure(message: "Multiline key accepted")
        } catch is ModelFailure {}

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let lexicon = ModelLexicon(session: session)
        let context = SentenceContext(before: "昨日学校に", word: "行った", after: "。")
        let json = "{\"head\":\"行く\",\"reading\":\"いく\",\"meaning\":\"去；前往\",\"note\":\"本句为过去式。\"}"

        settings.provider = .deepseek
        StubProtocol.respond = { request in
            try require(request.httpMethod == "POST", "POST method")
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key", "Bearer authentication")
            let body = try StubProtocol.body(request)
            try require(body["model"] as? String == "deepseek-flash", "DeepSeek model")
            try require((body["thinking"] as? [String: String])?["type"] == "disabled", "DeepSeek non-thinking mode")
            let messages = body["messages"] as! [[String: String]]
            let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
            try require(input["before"] == context.before && input["word"] == context.word && input["after"] == context.after,
                        "Original sentence and selected surface reach model")
            return (200, try completion(json))
        }
        let definition = try await lexicon.definition(context: context, settings: settings, apiKey: "test-only-key")
        try require(definition.head == "行く" && definition.reading == "いく", "Contextual lemma and reading")
        try require(definition.chinese == "去；前往\n本句为过去式。", "Chinese definition and note")
        try require(definition.source == "DeepSeek · deepseek-flash" && definition.english == nil, "Source attribution")

        settings.provider = .custom
        StubProtocol.respond = { request in
            let body = try StubProtocol.body(request)
            try require(body["model"] as? String == "custom-model", "Custom model ID")
            try require(body["thinking"] == nil && body["response_format"] == nil, "Custom service gets compatible parameters")
            return (200, try completion("```json\n" + json + "\n```"))
        }
        let custom = try await lexicon.definition(context: context, settings: settings, apiKey: "test-only-key")
        try require(custom.head == "行く" && custom.source == "自定义模型 · custom-model", "Fenced JSON response")

        let origins: [(String, String, String?)] = [
            ("コンピューター", "こんぴゅーたー", "英语 computer。"),
            ("アルバイト", "あるばいと", "德语 Arbeit，原意为工作。"),
            ("パン", "ぱん", "葡萄牙语 pão。"),
            ("サラリーマン", "さらりーまん", "和制外来语，由英语 salary 和 man 组成。"),
            ("サンプル語", "さんぷるご", "词源不确定。"),
            ("キラキラ", "きらきら", "  "),
            ("読む", "よむ", nil)
        ]
        for provider in ModelProvider.allCases {
            settings.provider = provider
            for (head, reading, origin) in origins {
                let result: [String: Any] = ["head": head, "reading": reading, "meaning": "测试释义", "note": "",
                                             "etymology": origin as Any? ?? NSNull()]
                let content = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
                StubProtocol.respond = { request in
                    let body = try StubProtocol.body(request)
                    let messages = body["messages"] as! [[String: String]]
                    let instructions = messages[0]["content"] ?? ""
                    try require(instructions.contains("etymology") && instructions.contains("来源语言") &&
                                instructions.contains("和制外来语") && instructions.contains("词源不确定"),
                                "Both providers receive loanword-origin requirements")
                    return (200, try completion(content))
                }
                let target = SentenceContext(before: "", word: head, after: "を調べた。")
                let resultDefinition = try await lexicon.definition(context: target, settings: settings, apiKey: "test-only-key")
                let expected = origin?.trimmingCharacters(in: .whitespacesAndNewlines)
                try require(resultDefinition.etymology == (expected?.isEmpty == false ? expected : nil),
                            "Origin spelling, language, uncertainty, and empty fields are preserved")
                let occurrence = Occurrence(bookID: UUID(), filename: "book.pdf", kind: "PDF", page: 0,
                                            offset: 0, context: target, definition: resultDefinition)
                let word = SavedWord(definition: resultDefinition, examples: [occurrence])
                let restored = try JSONDecoder().decode(SavedWord.self, from: JSONEncoder().encode(word))
                try require(restored.definition == resultDefinition && (restored.examples[0].definition ?? restored.definition) == resultDefinition,
                            "Origins survive saving in both word and example definitions")
            }
        }

        let errors: [(Int, Data, String)] = [
            (401, Data(), "认证失败"), (402, Data(), "余额不足"), (404, Data(), "找不到接口"),
            (429, Data(), "配额不足"), (500, Data(), "HTTP 500"),
            (200, Data("invalid".utf8), "Chat Completions"),
            (200, try completion(nil), "完整释义"),
            (200, try completion(json, finish: "length"), "完整释义"),
            (200, try completion("{\"head\":\"行く\"}"), "格式不完整"),
            (200, try completion("{\"head\":\"行く\",\"reading\":\" \",\"meaning\":\"\"}"), "格式不完整")
        ]
        for (status, data, expected) in errors {
            StubProtocol.respond = { _ in (status, data) }
            do {
                _ = try await lexicon.definition(context: context, settings: settings, apiKey: "test-only-key")
                throw TestFailure(message: "Invalid response accepted")
            } catch let error as ModelFailure {
                try require(error.message.contains(expected), "Actionable response error")
            }
        }

        StubProtocol.respond = { _ in throw URLError(.appTransportSecurityRequiresSecureConnection) }
        for (address, expected) in [
            ("http://example.com/v1", "模型接口使用 HTTP"),
            ("https://example.com/v1", "重定向到 HTTP")
        ] {
            settings.provider = .custom
            settings.customURL = address
            do {
                _ = try await lexicon.definition(context: context, settings: settings, apiKey: "test-only-key")
                throw TestFailure(message: "ATS failure accepted")
            } catch let error as ModelFailure {
                try require(error.message.contains(expected) && error.message.contains("ATS"),
                            "ATS failures explain the cause and next action in Chinese")
            }
        }

        StubProtocol.respond = { _ in throw URLError(.timedOut) }
        do {
            _ = try await lexicon.definition(context: context, settings: settings, apiKey: "test-only-key")
            throw TestFailure(message: "Network failure accepted")
        } catch let error as URLError {
            try require(error.code == .timedOut, "Network error reaches caller")
        }
        StubProtocol.respond = { _ in (200, try completion(json)) }
        let cancelled = Task {
            try await lexicon.definition(context: context, settings: settings, apiKey: "test-only-key")
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw TestFailure(message: "Cancelled request returned a definition")
        } catch is CancellationError {
        } catch let error as URLError {
            try require(error.code == .cancelled, "Cancelled network request")
        }

        let oldDefinition = try JSONDecoder().decode(Definition.self, from: Data("""
        {"head":"喫茶店","reading":"きっさてん","chinese":"咖啡馆","english":"coffee shop"}
        """.utf8))
        try require(oldDefinition.source == nil && oldDefinition.etymology == nil && oldDefinition.head == "喫茶店",
                    "Existing saved definitions remain readable without etymology")
        let oldOccurrence = try JSONDecoder().decode(Occurrence.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000001","bookID":"00000000-0000-0000-0000-000000000002",
         "filename":"book.pdf","kind":"PDF","page":0,"offset":0,"context":{"before":"","word":"喫茶店","after":"。"}}
        """.utf8))
        try require(oldOccurrence.definition == nil, "Existing examples remain readable")
        var occurrence = oldOccurrence
        occurrence.definition = definition
        let word = SavedWord(definition: definition, examples: [occurrence])
        let restored = try JSONDecoder().decode(SavedWord.self, from: JSONEncoder().encode(word))
        try require((restored.examples[0].definition ?? restored.definition) == definition, "Contextual meaning survives saving and reopening")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        let preferences = DefinitionPreferences(path: path)
        var offline = settings
        offline.source = .dictionary
        try preferences.save(offline, apiKey: "must-not-be-persisted")
        let reloaded = DefinitionPreferences(path: path)
        try require(reloaded.settings == offline, "Settings survive restart")
        let savedText = try String(contentsOf: path, encoding: .utf8)
        try require(!savedText.contains("must-not-be-persisted"), "Settings file excludes API key")
        print("Passed model request, response, URL, error, settings, and legacy data checks.")
    }
}
