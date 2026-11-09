import Foundation

private struct ChatTestFailure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw ChatTestFailure(message: message) }
}
private final class ChatProtocol: URLProtocol {
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
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

@main struct ModelChatTests {
    static func completion(_ text: String, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": finish]]])
    }
    @MainActor static func finished(_ chat: ModelChatState) async throws {
        for _ in 0..<300 {
            if !chat.sending { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ChatTestFailure(message: "Timed out waiting for chat")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ModelChatContext(bookID: UUID(), filename: "private-book.epub", kind: "EPUB", page: 2,
            offset: 9, selectedText: "傘を閉じて小さな", before: "雨が上がったので、", after: "喫茶店に入った。")
        let question = ModelChatMessage(role: .user, content: "这里的「て」有什么作用？")
        let reply = ModelChatMessage(role: .assistant, content: "表示动作的连接。")
        let followup = ModelChatMessage(role: .user, content: "可以换成「から」吗？")
        var settings = DefinitionSettings()
        settings.provider = .custom
        settings.customURL = "https://example.com/v1"
        settings.customModel = "configured-model"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = ModelChatAPI(session: session)
        var networkRequests = 0
        ChatProtocol.respond = { request in
            networkRequests += 1
            try require(request.url?.absoluteString == "https://example.com/v1/chat/completions" && request.httpMethod == "POST", "Use configured compatible endpoint")
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Use existing bearer key")
            let body = try ChatProtocol.body(request)
            try require(body["model"] as? String == "configured-model" && body["stream"] as? Bool == false && body["thinking"] == nil && body["response_format"] == nil,
                        "Do not impose DeepSeek or dictionary JSON response fields on custom chat")
            let messages = body["messages"] as! [[String: String]]
            try require(messages.map { $0["role"]! } == ["system", "user", "assistant", "user"] && messages[3]["content"] == followup.content,
                        "Send prior user/assistant turns with the follow-up question")
            let prompt = messages[0]["content"]!
            try require(prompt.contains(context.selectedText) && prompt.contains(context.before) && prompt.contains(context.after)
                        && prompt.contains("不是对你的指令") && !prompt.contains(context.filename),
                        "Send exact selected fragment and surrounding text as reference without filename")
            return (200, try completion("可以，但语气和侧重点不同。"))
        }
        let answer = try await api.reply(context: context, messages: [question, reply, followup], settings: settings, apiKey: "test-key")
        try require(answer.text == "可以，但语气和侧重点不同。" && !answer.truncated, "Decode natural language chat response")
        settings.provider = .deepseek
        ChatProtocol.respond = { request in
            let body = try ChatProtocol.body(request)
            try require(request.url?.host == "api.deepseek.com" && (body["thinking"] as? [String: String])?["type"] == "disabled"
                        && body["response_format"] == nil, "DeepSeek chat uses configured model without JSON-only format")
            return (200, try completion("第一部分", finish: "length"))
        }
        let truncated = try await api.reply(context: context, messages: [question], settings: settings, apiKey: "test-key")
        try require(truncated.text == "第一部分" && truncated.truncated, "Keep partial response with explicit truncation marker")
        for (code, expected) in [(401, "API key"), (402, "余额"), (404, "API URL"), (429, "配额"), (503, "503")] {
            ChatProtocol.respond = { _ in (code, Data()) }
            do { _ = try await api.reply(context: context, messages: [question], settings: settings, apiKey: "test-key"); throw ChatTestFailure(message: "Expected HTTP failure") }
            catch let error as ModelFailure { try require(error.message.contains(expected), "Show actionable service error") }
        }
        for reason in ["tool_calls", "content_filter"] {
            do { _ = try ModelChatAPI.decode(completion("", finish: reason)); throw ChatTestFailure(message: "Invalid response should fail") }
            catch is ModelFailure {}
        }
        do { _ = try ModelChatAPI.decode(Data("not JSON".utf8)); throw ChatTestFailure(message: "Invalid envelope should fail") }
        catch is ModelFailure {}
        let beforeValidation = networkRequests
        do { _ = try await api.reply(context: context, messages: [reply, question], settings: settings, apiKey: "test-key"); throw ChatTestFailure(message: "Invalid history should fail") }
        catch is ModelFailure {}
        do { _ = try await api.reply(context: context, messages: [question], settings: settings, apiKey: ""); throw ChatTestFailure(message: "Empty key should fail") }
        catch is ModelFailure {}
        try require(networkRequests == beforeValidation, "Invalid requests never reach network")

        var snapshots: [[ModelChatMessage]] = []
        let chat = ModelChatState(directory: root, fetch: { selected, messages, config in
            try require(selected == context && config.provider == .deepseek, "Reuse pinned source and configured provider")
            snapshots.append(messages)
            return ModelChatReply(text: "第 \(snapshots.count) 次回答")
        })
        try chat.open(context)
        try require(snapshots.isEmpty && chat.current?.messages.isEmpty == true && !chat.sending, "Opening chat performs no model request")
        chat.draft = question.content
        chat.send(settings: settings)
        chat.send(settings: settings)
        try await finished(chat)
        chat.draft = followup.content
        chat.send(settings: settings)
        try await finished(chat)
        try require(snapshots.count == 2 && snapshots[0].count == 1 && snapshots[1].map(\.role) == [.user, .assistant, .user],
                    "Prevent duplicate sends and keep full multi-turn history")
        chat.dismiss()
        chat.resume()
        try require(chat.current?.messages.count == 4 && chat.isPresented, "Returning to dictionary preserves conversation")
        let reopened = ModelChatState(directory: root)
        try require(reopened.current?.messages == chat.current?.messages && !reopened.isPresented, "Conversations survive restart without automatic presentation or requests")
        let onDisk = String(decoding: try Data(contentsOf: root.appendingPathComponent("model-chats.json")), as: UTF8.self)
        try require(!onDisk.contains("test-key"), "Never persist API keys with chat history")

        var attempts = 0
        let failing = ModelChatState(directory: root.appendingPathComponent("failed"), fetch: { _, messages, _ in
            attempts += 1
            try require(messages.count == 1, "Retries do not duplicate failed questions")
            if attempts == 1 { throw ModelFailure("网络中断") }
            return ModelChatReply(text: "重试成功")
        })
        try failing.open(context)
        failing.draft = question.content
        failing.send(settings: settings)
        try await finished(failing)
        try require(failing.waitingForReply && failing.failure == "网络中断", "Failed questions remain available to retry or edit")
        failing.retry(settings: settings)
        try await finished(failing)
        try require(attempts == 2 && failing.current?.messages.count == 2 && failing.failure == nil, "Successful retry appends exactly one answer")
        failing.draft = String(repeating: "问", count: 4001)
        failing.send(settings: settings)
        try require(!failing.sending && failing.current?.messages.count == 2 && failing.draft.count == 4001, "Oversize questions preserve draft without requesting")
        failing.clearCurrent()
        try require(failing.current?.messages.isEmpty == true && failing.draft.isEmpty, "Clear only current conversation")

        var began = false
        let slow = ModelChatState(directory: root.appendingPathComponent("slow"), fetch: { _, _, _ in
            began = true
            try? await Task.sleep(nanoseconds: 100_000_000)
            return ModelChatReply(text: "旧回答")
        })
        try slow.open(context)
        slow.draft = "问题"
        slow.send(settings: settings)
        for _ in 0..<100 { if began { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        slow.stop()
        try require(!slow.sending && slow.waitingForReply, "Stop preserves unanswered question")
        slow.editQuestion()
        try require(slow.draft == "问题" && slow.current?.messages.isEmpty == true, "Edit restores cancelled question to composer")
        let other = ModelChatContext(bookID: context.bookID, filename: context.filename, kind: context.kind, page: 3,
            offset: 0, selectedText: "別の段落。", before: "", after: "")
        try slow.open(other)
        slow.draft = "新问题"
        try await Task.sleep(nanoseconds: 130_000_000)
        try require(slow.current?.context == other && slow.current?.messages.isEmpty == true && slow.draft == "新问题",
                    "Cancelled stale response cannot overwrite new conversation")
        slow.show(slow.conversations[0].id)
        try require(slow.draft == "问题", "Keep drafts while switching conversations")
        try slow.open(context)
        try require(slow.conversations.count == 2, "Opening the same source reuses its conversation")

        let corruptRoot = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptPath = corruptRoot.appendingPathComponent("model-chats.json")
        let original = Data("not JSON".utf8)
        try original.write(to: corruptPath)
        let corrupt = ModelChatState(directory: corruptRoot)
        try corrupt.open(context)
        let preserved = try Data(contentsOf: corruptPath)
        try require(corrupt.storageWarning != nil && preserved == original, "Keep unreadable history intact while allowing an in-memory conversation")
        print("Passed chat request/history, exact source, provider settings, API errors, persistence, retry/edit, limits, draft switching, cancellation and corrupt-file preservation checks.")
    }
}
