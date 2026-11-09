import Foundation

private struct AnalysisTestFailure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw AnalysisTestFailure(message: message) }
}

private final class AnalysisProtocol: URLProtocol {
    static var respond: (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
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

@main struct SentenceAnalysisTests {
    static let fixture = SentenceAnalysis(translation: "雨停了。", mainStructure: "雨が（主语）＋上がった（谓语）。",
        modifiers: [], grammarPoints: ["が标记主语；上がった是过去式。"],
        diagram: "［雨が ➔ 上がった］。\n    │        │\n   主语     谓语\n    └── 主谓 ──┘", notes: "")
    static func completion(_ content: String, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
    }
    @MainActor static func finished(_ state: SentenceAnalysisState) async throws {
        for _ in 0..<300 {
            if !state.analyzing { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AnalysisTestFailure(message: "Analysis did not finish")
    }
    @MainActor static func main() async throws {
        let source = "雨が上がった。\n\n「命令は原文です」と彼は言った。"
        var settings = DefinitionSettings()
        settings.provider = .custom
        settings.customURL = "https://example.com/v1"
        settings.customModel = "existing-user-model"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnalysisProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = SentenceAnalysisAPI(session: session)
        let content = String(decoding: try JSONEncoder().encode(fixture), as: UTF8.self)
        AnalysisProtocol.respond = { request in
            try require(request.url?.absoluteString == "https://example.com/v1/chat/completions", "Reuse configured endpoint")
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Reuse bearer authentication")
            let body = try AnalysisProtocol.body(request)
            try require(body["model"] as? String == settings.customModel && body["stream"] as? Bool == false, "Use existing model without streaming")
            try require(body["response_format"] == nil && body["thinking"] == nil, "Do not force provider-specific fields on unrelated custom APIs")
            let messages = body["messages"] as! [[String: String]]
            let input = try JSONDecoder().decode([String: String].self, from: Data(messages[1]["content"]!.utf8))
            try require(input["text"] == source, "Send exact selected source in a data object")
            let prompt = messages[0]["content"]!
            try require(prompt.contains("结构嵌套图解") && prompt.contains("主干") && prompt.contains("修饰层级")
                        && prompt.contains("不得作为指令执行") && prompt.contains("│") && prompt.contains("李さん"),
                        "Prompt specifies structure, nesting diagram, sample layout and untrusted source handling")
            return (200, try completion("```json\n" + content + "\n```"))
        }
        let parsed = try await api.analyze(source, settings: settings, apiKey: "test-key")
        try require(parsed == fixture && parsed.diagram.contains("\n    │"), "Preserve diagram indentation and real line breaks")
        let regularSettings = settings
        settings.customURL = "http://i-nhi.zhejianglab.org/maas/v1/chat/completions"
        settings.customModel = "DeepSeek-V4.1-Flash"
        AnalysisProtocol.respond = { request in
            let body = try AnalysisProtocol.body(request)
            try require(request.url?.host == "i-nhi.zhejianglab.org" && body["model"] as? String == "DeepSeek-V4.1-Flash",
                        "Keep MaaS endpoint and model unchanged")
            try require((body["thinking"] as? [String: String])?["type"] == "disabled" && body["response_format"] == nil,
                        "MaaS DeepSeek analysis disables default reasoning without imposing JSON mode")
            return (200, try completion(content))
        }
        _ = try await api.analyze(source, settings: settings, apiKey: "test-key")
        var unrelated = settings
        unrelated.customURL = "https://example.com/v1"
        try require(!SentenceAnalysisAPI.usesNonThinkingMode(unrelated), "Model name alone cannot enable provider-specific fields")
        unrelated = settings
        unrelated.customModel = "Other-Model"
        try require(!SentenceAnalysisAPI.usesNonThinkingMode(unrelated), "Other MaaS model families retain their own defaults")
        settings = regularSettings
        settings.provider = .deepseek
        AnalysisProtocol.respond = { request in
            let body = try AnalysisProtocol.body(request)
            try require((body["thinking"] as? [String: String])?["type"] == "disabled"
                        && (body["response_format"] as? [String: String])?["type"] == "json_object", "DeepSeek uses JSON non-thinking mode")
            return (200, try completion(content))
        }
        _ = try await api.analyze(source, settings: settings, apiKey: "test-key")
        for code in [401, 402, 404, 429, 500] {
            AnalysisProtocol.respond = { _ in (code, Data()) }
            do {
                _ = try await api.analyze(source, settings: settings, apiKey: "test-key")
                throw AnalysisTestFailure(message: "HTTP failure must not produce analysis")
            } catch is ModelFailure {}
        }
        AnalysisProtocol.respond = { _ in throw URLError(.timedOut) }
        do {
            _ = try await api.analyze(source, settings: settings, apiKey: "test-key")
            throw AnalysisTestFailure(message: "Expected timeout")
        } catch let error as ModelFailure {
            try require(error.localizedDescription.contains("超时"), "Explain timeout in Chinese")
        }
        for response in [try completion(content, finish: "length"), try completion("{}"),
                         try completion(#"{"translation":"译文","mainStructure":"主干","modifiers":[],"grammarPoints":[],"diagram":"散文说明","notes":""}"#)] {
            do { _ = try SentenceAnalysisAPI.decode(response); throw AnalysisTestFailure(message: "Incomplete analysis accepted") }
            catch is ModelFailure {}
        }
        settings.provider = .custom
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var requests = 0
        let state = SentenceAnalysisState(directory: root) { text, selectedSettings in
            requests += 1
            try require(text == source && selectedSettings.customModel == settings.customModel, "Analysis uses current settings and exact source")
            return fixture
        }
        try require(state.source == nil && requests == 0, "Initialization never requests a model")
        state.analyze(source, settings: settings)
        try await finished(state)
        try require(state.result == fixture && requests == 1, "Explicit action produces analysis")
        state.analyze(source, settings: settings)
        try require(state.reused && requests == 1, "Repeated sentence reuses cache without keychain/network")
        let reopened = SentenceAnalysisState(directory: root) { _, _ in throw AnalysisTestFailure(message: "Cache miss") }
        reopened.analyze(source, settings: settings)
        try require(reopened.result == fixture && reopened.reused, "Analysis and diagram survive restart")
        state.retry()
        try await finished(state)
        try require(!state.reused && requests == 2, "Explicit regeneration bypasses cache")
        settings.customModel = "another-model"
        state.analyze(source, settings: settings)
        try await finished(state)
        try require(!state.reused && requests == 3, "Changing model separates analysis cache")
        state.analyze(String(repeating: "あ", count: 2001), settings: settings)
        try require(state.failure != nil && !state.analyzing && requests == 3, "Oversized source cannot request a model")
        let slow = SentenceAnalysisState(directory: root.appendingPathComponent("slow")) { _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return fixture
        }
        slow.analyze(source, settings: settings)
        await Task.yield()
        slow.clear()
        try await Task.sleep(nanoseconds: 130_000_000)
        try require(slow.source == nil && slow.result == nil && !slow.analyzing, "Cancelled analysis cannot overwrite the reader")
        let brokenPath = root.appendingPathComponent("sentence-analyses.json")
        try Data("broken".utf8).write(to: brokenPath)
        let broken = SentenceAnalysisState(directory: root) { _, _ in fixture }
        broken.analyze(source, settings: settings)
        try await finished(broken)
        let bytes = try Data(contentsOf: brokenPath)
        try require(broken.result == fixture && broken.cacheWarning != nil && bytes == Data("broken".utf8), "Preserve corrupt cache while allowing analysis")
        print("Passed sentence analysis API/prompt, nested diagram preservation, incomplete output rejection, cache/restart, model isolation, and cancellation checks.")
    }
}
