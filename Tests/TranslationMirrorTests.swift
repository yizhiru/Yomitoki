import Foundation

private struct MirrorTestFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MirrorTestFailure(message: message) }
}

private final class MirrorProtocol: URLProtocol {
    static var respond: (URLRequest) throws -> (Int, [String: String], Data) = { _ in (500, [:], Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct TranslationMirrorTests {
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw MirrorTestFailure(message: "Timed out waiting for test state")
    }

    @MainActor static func main() async throws {
        let legacy = Data(#"{"modelPath":"old.gguf","modelIdentity":"verified-old-file"}"#.utf8)
        let configuration = try JSONDecoder().decode(TranslationConfiguration.self, from: legacy)
        try require(configuration.modelPath == "old.gguf" && configuration.modelIdentity == "verified-old-file" &&
                    configuration.downloadMirror == .hfMirror, "Old settings preserve model and default to HF mirror")
        try require(TranslationMirror.allCases.count == 2, "Two download sources are exposed")
        try require(TranslationMirror.hfMirror.downloadURL.host == "hf-mirror.com" &&
                    TranslationMirror.modelScope.downloadURL.host == "modelscope.cn", "Each source uses its own host")
        try require(TranslationMirror.modelScope.downloadURL.path.contains("ef1d40b8b315575d30d1eb6579996130b8fc0bb2"),
                    "ModelScope file version is pinned")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MirrorProtocol.self]
        let sampleBytes = 128
        let probe = TranslationMirrorProbe(sampleBytes: sampleBytes, configuration: sessionConfiguration)
        let contentRange = "bytes 0-127/\(TranslationModel.byteCount)"
        var requestedURLs: [URL] = []
        MirrorProtocol.respond = { request in
            requestedURLs.append(request.url!)
            try require(request.value(forHTTPHeaderField: "Range") == "bytes=0-127", "Probe requests a bounded file range")
            try require(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity", "Measure uncompressed bytes")
            return (206, ["Content-Range": contentRange], Data(repeating: 42, count: sampleBytes))
        }
        for mirror in TranslationMirror.allCases {
            let speed = try await probe.measure(mirror)
            try require(speed.isFinite && speed > 0, "Only completed measurements produce a positive speed")
        }
        try require(requestedURLs == TranslationMirror.allCases.map(\.downloadURL), "Both selected mirror URLs are measured")
        for (status, range, count) in [(200, contentRange, sampleBytes), (206, "bytes 8-135/1133080448", sampleBytes),
                                        (503, contentRange, 0), (206, contentRange, 8)] {
            MirrorProtocol.respond = { _ in (status, ["Content-Range": range], Data(repeating: 42, count: count)) }
            do {
                _ = try await probe.measure(.hfMirror)
                throw MirrorTestFailure(message: "Unsupported range or truncated body should not report a speed")
            } catch is ModelFailure {}
        }
        MirrorProtocol.respond = { _ in throw URLError(.timedOut) }
        do {
            _ = try await probe.measure(.hfMirror)
            throw MirrorTestFailure(message: "Timeout should not report a speed")
        } catch let error as URLError {
            try require(error.code == .timedOut, "Timeout is preserved")
        }
        let cancelled = Task { try await probe.measure(.modelScope) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw MirrorTestFailure(message: "Cancelled probe should not report a speed")
        } catch is CancellationError {}

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var sources: [TranslationMirror] = []
        let service = LocalTranslation(directory: directory, measureMirror: { mirror in
            sources.append(mirror)
            if mirror == .modelScope { throw URLError(.timedOut) }
            return 1_000_000
        }, fetch: { _, _ in "中文译文" })
        try require(sources.isEmpty && !service.testingMirrors && service.mirrorSpeeds.isEmpty, "Startup does not run network speed tests")
        service.translate("雨が降る。")
        try await waitUntil { !service.translating }
        service.selectDownloadMirror(.modelScope)
        try require(service.configuration.downloadMirror == .modelScope && service.result == "中文译文",
                    "Source selection preserves the current translation")
        let reopened = LocalTranslation(directory: directory)
        try require(reopened.configuration.downloadMirror == .modelScope, "Source selection survives restart")
        service.testDownloadMirrors()
        try await waitUntil { !service.testingMirrors }
        try require(sources == TranslationMirror.allCases, "Mirrors are tested sequentially")
        try require(service.mirrorSpeeds[.hfMirror] == .measured(bytesPerSecond: 1_000_000) &&
                    service.mirrorSpeeds[.modelScope] == .unavailable, "Failed probes show status without a fabricated speed")
        try require(LocalTranslation(directory: directory).mirrorSpeeds.isEmpty, "Short-test speeds are not persisted")

        var calls = 0
        let slow = LocalTranslation(directory: directory.appendingPathComponent("cancelled"), measureMirror: { _ in
            calls += 1
            let first = calls == 1
            if first { try? await Task.sleep(nanoseconds: 100_000_000) }
            return first ? 1 : 2
        })
        slow.testDownloadMirrors()
        try await waitUntil { calls == 1 }
        slow.cancelMirrorTesting()
        slow.testDownloadMirrors()
        try await waitUntil { !slow.testingMirrors }
        try await Task.sleep(nanoseconds: 130_000_000)
        try require(slow.mirrorSpeeds[.hfMirror] == .measured(bytesPerSecond: 2) &&
                    slow.mirrorSpeeds[.modelScope] == .measured(bytesPerSecond: 2), "Cancelled results cannot overwrite a restarted test")
        print("Passed mirror selection, legacy settings, bounded range probes, failed-speed suppression, sequential tests, persistence, and cancellation checks.")
    }
}
