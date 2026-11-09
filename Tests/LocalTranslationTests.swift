import AppKit
import Foundation

private struct TranslationTestFailure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TranslationTestFailure(message: message) }
}
private func fails(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TranslationTestFailure(message: "Expected validation failure")
}

@main struct LocalTranslationTests {
    @MainActor static func finished(_ service: LocalTranslation, preparing: Bool = false) async throws {
        for _ in 0..<600 {
            if preparing ? !service.preparingModel : !service.translating { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TranslationTestFailure(message: "Translation did not finish")
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("translation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyConfiguration = Data(#"{"modelPath":"/models/user.gguf","modelIdentity":"verified","runtimePath":"/opt/homebrew/bin/old-server"}"#.utf8)
        let migrated = try JSONDecoder().decode(TranslationConfiguration.self, from: legacyConfiguration)
        let migratedData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: String]
        try require(migrated.modelPath == "/models/user.gguf" && migrated.modelIdentity == "verified" && migratedData["runtimePath"] == nil,
                    "Keep legacy model selection while dropping machine-specific engine paths")
        let firstBundle = root.appendingPathComponent("First.app")
        let movedBundle = root.appendingPathComponent("Moved.app")
        try require(TranslationEngine.executableURL(in: movedBundle).path == movedBundle.appendingPathComponent("Contents/Helpers/llama-server").path
                    && TranslationEngine.executableURL(in: firstBundle) != TranslationEngine.executableURL(in: movedBundle),
                    "Bundled engine follows the App when it moves")
        let initialProgress = TranslationDownloadState(completedBytes: 0, totalBytes: -1)
        try require(initialProgress.totalBytes == TranslationModel.byteCount && initialProgress.fractionCompleted == 0,
                    "Progress starts at zero even before the server reports a size")
        let streamingProgress = TranslationDownloadState(completedBytes: TranslationModel.byteCount / 4, totalBytes: -1)
        try require(streamingProgress.fractionCompleted == 0.25,
                    "Chunked downloads use the pinned model size for a visible percentage")
        let reportedProgress = TranslationDownloadState(completedBytes: 50, totalBytes: 200)
        try require(reportedProgress.fractionCompleted == 0.25 && reportedProgress.totalBytes == 200,
                    "A reported server size is respected")
        let invalidProgress = TranslationDownloadState(completedBytes: -10, totalBytes: 0)
        let finishedProgress = TranslationDownloadState(completedBytes: 201, totalBytes: 200)
        try require(invalidProgress.completedBytes == 0 && invalidProgress.fractionCompleted == 0 && finishedProgress.fractionCompleted == 1,
                    "Progress values remain within the displayed range")
        let original = "☕️ 雨が上がった。\n\n私は喫茶店に入った。"
        let selected = (original as NSString).range(of: "雨が上がった。\n\n私は喫茶店に入った。")
        let text = TranslationModel.selectedText(selected, in: original)!
        try require(text == "雨が上がった。\n\n私は喫茶店に入った。", "Translate the exact selection, including paragraph boundaries")
        try require(TranslationModel.selectedText(NSRange(location: 0, length: 0), in: original) == nil, "No selection does nothing")
        try require(TranslationModel.selectedText(NSRange(location: 999, length: 1), in: original) == nil, "Reject invalid range")
        try require(TranslationModel.selectedText(NSRange(location: 1, length: 1), in: "😀") == nil, "Reject a split surrogate")
        try require(TranslationModel.selectedText(NSRange(location: 0, length: 3), in: " 雨 ") == " 雨 ", "Preserve selected whitespace")
        let abc = root.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        let checksum = try TranslationModel.checksum(abc)
        try require(checksum == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "Streamed SHA256")
        try fails { try TranslationModel.validateFile(abc) }
        let key = TranslationModel.cacheKey(text: text, identity: "first")
        try require(key != TranslationModel.cacheKey(text: text + "。", identity: "first"), "Cache includes exact source")
        try require(key != TranslationModel.cacheKey(text: text, identity: "second"), "Cache separates model identities")
        let complete = Data(#"{"choices":[{"message":{"content":"雨停了。"},"finish_reason":"stop"}]}"#.utf8)
        let parsed = try LocalTranslationRuntime.result(complete)
        try require(parsed == "雨停了。", "Decode plain translation, no dictionary JSON requirement")
        for response in [#"{"choices":[{"message":{"content":"半句"},"finish_reason":"length"}]}"#,
                         #"{"choices":[{"message":{"content":" "},"finish_reason":"stop"}]}"#, "{}"] {
            try fails { _ = try LocalTranslationRuntime.result(Data(response.utf8)) }
        }

        var requests = 0
        let cacheRoot = root.appendingPathComponent("cache")
        let service = LocalTranslation(directory: cacheRoot) { source, _ in
            requests += 1
            try require(source == text, "Backend gets selected sentences, never dictionary lemmas")
            return "雨停了。\n\n我走进了咖啡馆。"
        }
        try require(requests == 0 && service.source == nil && !service.preparingModel, "Opening the app cannot translate or download")
        service.translate(text)
        try await finished(service)
        try require(requests == 1 && service.result?.contains("咖啡馆") == true, "Explicit action translates")
        service.translate(text)
        try require(requests == 1 && service.reused, "Repeated selection reuses translation cache")
        let reopened = LocalTranslation(directory: cacheRoot) { _, _ in
            requests += 1
            return "Must not be called"
        }
        reopened.translate(text)
        try require(requests == 1 && reopened.reused && reopened.result == service.result, "Cache survives restart")
        service.retry()
        try await finished(service)
        try require(requests == 2 && !service.reused, "Explicit retry bypasses cache")
        service.translate(String(repeating: "あ", count: 2001))
        try require(!service.translating && service.failure != nil && requests == 2, "Limit long input before loading model")
        service.clear()
        try require(service.source == nil && service.result == nil && service.failure == nil, "Clear removes the translation panel state")
        var changedConfiguration = TranslationConfiguration()
        changedConfiguration.modelIdentity = "another-file"
        try service.setConfiguration(changedConfiguration)
        service.translate(text)
        try await finished(service)
        try require(requests == 3 && !service.reused, "Model change cannot reuse old translations")
        let configured = LocalTranslation(directory: cacheRoot)
        try require(configured.configuration.modelIdentity == "another-file" && configured.source == nil,
                    "Configuration persists without starting a translation")

        let slow = LocalTranslation(directory: root.appendingPathComponent("slow")) { source, _ in
            // Deliberately ignore cancellation to check stale-result suppression.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return "Late \(source)"
        }
        slow.translate("雨")
        await Task.yield()
        slow.clear()
        try await Task.sleep(nanoseconds: 130_000_000)
        try require(slow.result == nil && slow.source == nil, "Navigation/cancellation cannot show stale translations")

        // Corrupt local state and failed model verification must preserve user files.
        let brokenRoot = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
        let brokenCache = brokenRoot.appendingPathComponent("translations.json")
        try Data("bad cache".utf8).write(to: brokenCache)
        let broken = LocalTranslation(directory: brokenRoot) { _, _ in "译文" }
        broken.translate("雨")
        try await finished(broken)
        let preserved = try Data(contentsOf: brokenCache)
        try require(broken.result == "译文" && broken.cacheWarning != nil && preserved == Data("bad cache".utf8), "Bad cache is retained")
        broken.prepareModel(from: abc)
        try await finished(broken, preparing: true)
        try require(broken.setupFailure != nil && broken.configuration.modelPath.isEmpty && FileManager.default.fileExists(atPath: abc.path),
                    "Invalid model is not activated and selected user file is preserved")

        // Exercise process launch, actual loopback HTTP, prompt, auth and cancellation
        // with a tiny fixture engine. No weights are downloaded by tests.
        let model = root.appendingPathComponent("fixture.gguf")
        try Data("GGUF fixture".utf8).write(to: model)
        let engine = root.appendingPathComponent("llama-server")
        let script = #"""
        #!/usr/bin/python3
        import sys, json, time
        from http.server import HTTPServer, BaseHTTPRequestHandler
        args = sys.argv[1:]
        def arg(key): return args[args.index(key)+1]
        model = arg('--model')
        with open(model + '.args', 'w') as f: json.dump(args, f)
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def send(self, body, code=200):
                data = json.dumps(body, ensure_ascii=False).encode('utf-8')
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def do_GET(self): self.send({'status':'ok'})
            def do_POST(self):
                if self.headers.get('Authorization') != 'Bearer ' + arg('--api-key'):
                    self.send({}, 401); return
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if self.path == '/tokenize':
                    self.send({'tokens': list(range(5601)) if 'TOO_LONG' in body['content'] else [1,2,3]}); return
                with open(model + '.request', 'w') as f: json.dump(body, f, ensure_ascii=False)
                if 'WAIT' in body['messages'][0]['content']: time.sleep(10)
                self.send({'choices':[{'message':{'content':'雨停了。\n\n我走进了咖啡馆。'},'finish_reason':'stop'}]})
        HTTPServer((arg('--host'), int(arg('--port'))), Handler).serve_forever()
        """#
        try script.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let runtime = LocalTranslationRuntime(executableURL: engine)
        defer { runtime.stop() }
        let identity = try TranslationModel.fingerprint(model)
        let configuration = TranslationConfiguration(modelPath: model.path, modelIdentity: identity)
        let missing = LocalTranslationRuntime(executableURL: root.appendingPathComponent("missing-server"))
        do {
            _ = try await missing.translate(text, configuration: configuration)
            throw TranslationTestFailure(message: "Missing bundled engine must not fall back to a system installation")
        } catch let error as ModelFailure {
            try require(error.localizedDescription.contains("内置翻译引擎"), "Explain missing engine without asking users to install Homebrew")
        }
        let live = try await runtime.translate(text, configuration: configuration)
        try require(live.contains("咖啡馆"), "Real local process and HTTP round trip")
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: model.path + ".args")))
        try require(arguments.contains("127.0.0.1") && !arguments.contains("0.0.0.0"), "Only listen on loopback")
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: model.path + ".request"))) as! [String: Any]
        let messages = request["messages"] as! [[String: String]]
        try require(messages.count == 1 && messages[0]["role"] == "user" && messages[0]["content"] == TranslationModel.prompt(text),
                    "Official user-only translation prompt preserves exact selected source")
        do {
            _ = try await runtime.translate("TOO_LONG", configuration: configuration)
            throw TranslationTestFailure(message: "Context budget must reject oversized tokenization")
        } catch is ModelFailure {}
        var changedFileConfiguration = configuration
        changedFileConfiguration.modelIdentity = "stale fingerprint"
        do {
            _ = try await runtime.translate(text, configuration: changedFileConfiguration)
            throw TranslationTestFailure(message: "Changed file must be reselected and verified")
        } catch is ModelFailure {}
        let waiting = Task { try await runtime.translate("WAIT", configuration: configuration) }
        try await Task.sleep(nanoseconds: 60_000_000)
        waiting.cancel()
        runtime.stop()
        do {
            _ = try await waiting.value
            throw TranslationTestFailure(message: "Cancelled runtime must not return a result")
        } catch is TranslationTestFailure { throw TranslationTestFailure(message: "Cancellation failed") }
        catch {}
        print("Passed exact selection, translation cache/restart, cancellation, checksum, file preservation, context limits, and local engine HTTP integration.")
    }
}
