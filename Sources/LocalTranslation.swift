import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum TranslationModel {
    static let name = "Hy-MT2-1.8B · Q4_K_M"
    static let filename = "Hy-MT2-1.8B-Q4_K_M.gguf"
    static let byteCount: Int64 = 1_133_080_448
    // Pin the official file revision and verify its LFS SHA-256 before activation.
    static let downloadURL = URL(string: "https://hf-mirror.com/tencent/Hy-MT2-1.8B-GGUF/resolve/b27182d810fa3ceb6ed04e7c324c54e35c0d209c/Hy-MT2-1.8B-Q4_K_M.gguf")!
    static let homepage = URL(string: "https://hf-mirror.com/tencent/Hy-MT2-1.8B-GGUF")!
    static let officialHomepage = URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF")!
    static let downloadStatus = "正在从 HF 镜像下载模型…"
    static let sha256 = "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
    static let promptVersion = "ja-zh-v1"

    static func prompt(_ text: String) -> String {
        "将以下文本翻译为简体中文，注意只需要输出翻译后的结果，不要额外解释，保留段落划分：\n\n" + text
    }

    static func selectedText(_ range: NSRange, in text: String) -> String? {
        guard range.location >= 0, range.length > 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let range = Range(range, in: text),
              range.lowerBound.samePosition(in: text.unicodeScalars) != nil,
              range.upperBound.samePosition(in: text.unicodeScalars) != nil else { return nil }
        let selected = String(text[range])
        return selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selected
    }

    static func fingerprint(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.standardizedFileURL.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    static func cacheKey(text: String, identity: String) -> String {
        SHA256.hash(data: Data((promptVersion + "\u{0}" + identity + "\u{0}" + text).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validateFile(_ url: URL) throws {
        guard try checksum(url) == sha256 else {
            throw ModelFailure("文件与官方 Hy-MT2-1.8B Q4_K_M 模型不符。请选择正确的完整文件，或重新下载。")
        }
    }
}

struct TranslationConfiguration: Codable, Equatable {
    var modelPath = ""
    var modelIdentity = ""
    var downloadMirror = TranslationMirror.hfMirror

    private enum CodingKeys: String, CodingKey { case modelPath, modelIdentity, downloadMirror }
}

extension TranslationConfiguration {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try values.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
        modelIdentity = try values.decodeIfPresent(String.self, forKey: .modelIdentity) ?? ""
        downloadMirror = try values.decodeIfPresent(TranslationMirror.self, forKey: .downloadMirror) ?? .hfMirror
    }
}

enum TranslationEngine {
    static func executableURL(in bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/llama-server")
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL().path)
    }
}

struct TranslationDownloadState: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64

    init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = max(0, completedBytes)
        // Some mirrors stream without Content-Length. The pinned file has a known size.
        self.totalBytes = totalBytes > 0 ? totalBytes : TranslationModel.byteCount
    }

    var fractionCompleted: Double { min(1, Double(completedBytes) / Double(totalBytes)) }
    var byteCountDescription: String {
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "已下载 \(completed) / \(total)"
    }
}

private final class TranslationDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (TranslationDownloadState) -> Void
    private var lastUpdate = Date.distantPast
    init(update: @escaping @Sendable (TranslationDownloadState) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = TranslationDownloadState(completedBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
        guard Date().timeIntervalSince(lastUpdate) > 0.1 || progress.fractionCompleted >= 1 else { return }
        lastUpdate = Date()
        update(progress)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

private final class LoopbackSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Owns exactly one llama-server, bound only to loopback. No remote fallback.
@MainActor final class LocalTranslationRuntime {
    private var process: Process?
    private var baseURL: URL?
    private var identity = ""
    private var apiKey = ""
    private var logURL: URL?
    private var logHandle: FileHandle?
    private var terminationObserver: NSObjectProtocol?
    private let session: URLSession
    private let executableOverride: URL?

    // The override is for isolated integration tests; user configuration cannot
    // replace the bundled executable or depend on an absolute installation path.
    init(session: URLSession? = nil, executableURL: URL? = nil) {
        executableOverride = executableURL
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = session ?? URLSession(configuration: config, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if process?.isRunning == true { process?.terminate() }
        try? logHandle?.close()
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        session.invalidateAndCancel()
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            // Bound shutdown without blocking the UI if a backend ignores SIGTERM.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        baseURL = nil
        identity = ""
        try? logHandle?.close()
        logHandle = nil
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        logURL = nil
    }

    private static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ModelFailure("无法分配本地翻译端口。") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw ModelFailure("无法绑定本地翻译端口。") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw ModelFailure("无法读取本地翻译端口。") }
        return UInt16(bigEndian: address.sin_port)
    }

    private func start(_ configuration: TranslationConfiguration) async throws -> URL {
        guard !configuration.modelPath.isEmpty else { throw ModelFailure("请先在「设置 → 本地翻译」下载或选择模型。") }
        let executable = executableOverride ?? TranslationEngine.executableURL()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ModelFailure("App 内置翻译引擎缺失或损坏，请重新安装完整的读解 App。")
        }
        let model = URL(fileURLWithPath: configuration.modelPath)
        let currentIdentity = try TranslationModel.fingerprint(model)
        guard currentIdentity == configuration.modelIdentity else {
            throw ModelFailure("模型文件已移动或改变，请在「设置 → 本地翻译」重新选择并校验。")
        }
        let requested = currentIdentity + "|" + executable.path
        if let process, process.isRunning, identity == requested, let baseURL { return baseURL }
        stop()
        let port = try Self.availablePort()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let key = UUID().uuidString
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--model", model.path, "--host", "127.0.0.1", "--port", String(port),
                             "--ctx-size", "8192", "--parallel", "1", "--n-gpu-layers", "99",
                             "--alias", "yomitoki-translation", "--api-key", key, "--jinja"]
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("yomitoki-translation-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        self.process = process
        logURL = log
        logHandle = handle
        apiKey = key
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try Task.checkCancellation()
                guard process.isRunning else {
                    let details = (try? String(contentsOf: log, encoding: .utf8))?.suffix(1000) ?? ""
                    throw ModelFailure("内置翻译引擎启动失败，请确认内存充足，或更新读解后重试。\n\(details)")
                }
                var request = URLRequest(url: url.appendingPathComponent("health"))
                request.timeoutInterval = 2
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                    try Task.checkCancellation()
                    self.baseURL = url
                    identity = requested
                    return url
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw ModelFailure("模型加载超时，请确认内存充足、模型完整，并重试。")
        } catch {
            // A cancelled older request must not stop a newer request's server.
            if self.process === process { stop() }
            throw error
        }
    }

    func translate(_ text: String, configuration: TranslationConfiguration) async throws -> String {
        let url = try await start(configuration)
        try Task.checkCancellation()
        let prompt = TranslationModel.prompt(text)
        let tokenData = try await post(url.appendingPathComponent("tokenize"), body: ["content": prompt])
        guard let object = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let tokens = object["tokens"] as? [Int] else { throw ModelFailure("翻译引擎分词响应无效，请更新读解后重试。") }
        guard tokens.count <= 5600 else { throw ModelFailure("所选内容超出模型上下文，请减少文字并分段翻译。") }
        let data = try await post(url.appendingPathComponent("v1/chat/completions"), body: [
            "model": "yomitoki-translation", "stream": false, "temperature": 0.2, "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ])
        try Task.checkCancellation()
        return try Self.result(data)
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ModelFailure("本地翻译引擎请求失败，请缩短选文或更新读解后重试。")
        }
        return data
    }

    static func result(_ data: Data) throws -> String {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = completion.choices.first else { throw ModelFailure("本地翻译引擎返回格式无效。") }
        guard choice.finish_reason == "stop" else { throw ModelFailure("译文未完整生成，请缩短选文后重试。") }
        guard let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ModelFailure("模型未返回译文，请重试。")
        }
        return text
    }
}

@MainActor final class LocalTranslation: ObservableObject {
    @Published private(set) var configuration = TranslationConfiguration()
    @Published private(set) var preparingModel = false
    @Published private(set) var testingMirrors = false
    @Published private(set) var mirrorSpeeds: [TranslationMirror: TranslationMirrorSpeed] = [:]
    @Published private(set) var downloadProgress: TranslationDownloadState?
    @Published private(set) var modelStatus: String?
    @Published private(set) var setupFailure: String?
    @Published private(set) var source: String?
    @Published private(set) var result: String?
    @Published private(set) var translating = false
    @Published private(set) var failure: String?
    @Published private(set) var reused = false
    @Published private(set) var cacheWarning: String?
    private let directory: URL
    private let runtime: LocalTranslationRuntime
    private let fetch: ((String, TranslationConfiguration) async throws -> String)?
    private let measureMirror: (TranslationMirror) async throws -> Double
    private var cache: [String: String] = [:]
    private var canSaveCache = true
    private var canSaveConfiguration = true
    private var task: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var modelPreparationID = UUID()
    private var mirrorTestTask: Task<Void, Never>?
    private var mirrorTestID = UUID()
    private var requestID = UUID()

    convenience init(directory: URL, runtime: LocalTranslationRuntime? = nil,
                     fetch: ((String, TranslationConfiguration) async throws -> String)? = nil) {
        self.init(directory: directory, runtime: runtime,
                  measureMirror: { try await TranslationMirrorProbe().measure($0) }, fetch: fetch)
    }

    init(directory: URL, runtime: LocalTranslationRuntime? = nil,
         measureMirror: @escaping (TranslationMirror) async throws -> Double,
         fetch: ((String, TranslationConfiguration) async throws -> String)? = nil) {
        self.measureMirror = measureMirror
        self.directory = directory
        self.runtime = runtime ?? LocalTranslationRuntime()
        self.fetch = fetch
        let settingsURL = directory.appendingPathComponent("translation-settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do { configuration = try JSONDecoder().decode(TranslationConfiguration.self, from: Data(contentsOf: settingsURL)) }
            catch { canSaveConfiguration = false; setupFailure = "本地翻译设置无法读取，原文件已保留：\(settingsURL.path)" }
        }
        let cacheURL = directory.appendingPathComponent("translations.json")
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            do { cache = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheURL)) }
            catch { canSaveCache = false; cacheWarning = "翻译缓存无法读取，原文件已保留，本次翻译仍可继续。" }
        }
    }

    private func persistConfiguration(_ candidate: TranslationConfiguration) throws {
        guard canSaveConfiguration else { throw ModelFailure("翻译设置文件损坏，请先在 Finder 中备份并移走 translation-settings.json 后重启。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: directory.appendingPathComponent("translation-settings.json"), options: .atomic)
    }

    func setConfiguration(_ candidate: TranslationConfiguration) throws {
        try persistConfiguration(candidate)
        clear()
        runtime.stop()
        configuration = candidate
        result = nil
        setupFailure = nil
    }

    func selectDownloadMirror(_ mirror: TranslationMirror) {
        guard !preparingModel else { return }
        do {
            var candidate = configuration
            candidate.downloadMirror = mirror
            try persistConfiguration(candidate)
            configuration = candidate
            setupFailure = nil
        } catch { setupFailure = error.localizedDescription }
    }

    func testDownloadMirrors() {
        guard !preparingModel, !testingMirrors else { return }
        testingMirrors = true
        mirrorSpeeds = [:]
        mirrorTestID = UUID()
        let id = mirrorTestID
        mirrorTestTask = Task {
            for mirror in TranslationMirror.allCases {
                guard !Task.isCancelled, id == mirrorTestID else { return }
                mirrorSpeeds[mirror] = .testing
                do {
                    let speed = try await measureMirror(mirror)
                    guard !Task.isCancelled, id == mirrorTestID else { return }
                    mirrorSpeeds[mirror] = .measured(bytesPerSecond: speed)
                } catch {
                    guard !Task.isCancelled, id == mirrorTestID else { return }
                    mirrorSpeeds[mirror] = .unavailable
                }
            }
            testingMirrors = false
            mirrorTestTask = nil
        }
    }

    func cancelMirrorTesting() {
        mirrorTestID = UUID()
        mirrorTestTask?.cancel()
        mirrorTestTask = nil
        testingMirrors = false
        mirrorSpeeds = [:]
    }

    func translate(_ text: String, refresh: Bool = false) {
        cancel()
        source = text
        result = nil
        reused = false
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { failure = "请先选中需要翻译的日语句子或段落。"; return }
        guard text.count <= 2000 else { failure = "一次最多翻译 2000 个字符，请分段选择。"; return }
        let configuration = self.configuration
        let key = TranslationModel.cacheKey(text: text, identity: configuration.modelIdentity)
        if !refresh, let value = cache[key], !value.isEmpty {
            result = value
            reused = true
            return
        }
        translating = true
        let id = requestID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let translated: String
                if let fetch { translated = try await fetch(text, configuration) }
                else { translated = try await runtime.translate(text, configuration: configuration) }
                guard !Task.isCancelled, id == requestID else { return }
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelFailure("模型未返回译文。") }
                result = translated
                cache[key] = translated
                if canSaveCache {
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try JSONEncoder().encode(cache).write(to: directory.appendingPathComponent("translations.json"), options: .atomic)
                        cacheWarning = nil
                    } catch { cacheWarning = "译文已生成，但缓存保存失败。\(error.localizedDescription)" }
                }
            } catch {
                guard !Task.isCancelled, id == requestID else { return }
                failure = error.localizedDescription
            }
            translating = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        if translating { runtime.stop() }
        translating = false
        failure = nil
    }

    func clear() {
        cancel()
        source = nil
        result = nil
        reused = false
    }

    func retry() { if let source { translate(source, refresh: true) } }

    func chooseModel() {
        guard !preparingModel else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Hy-MT2-1.8B Q4_K_M 模型"
        panel.prompt = "选择并校验"
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepareModel(from: url)
    }

    func prepareModel(from localURL: URL? = nil) {
        guard !preparingModel else { return }
        cancelMirrorTesting()
        let mirror = configuration.downloadMirror
        preparingModel = true
        setupFailure = nil
        modelPreparationID = UUID()
        let preparationID = modelPreparationID
        downloadProgress = localURL == nil
            ? TranslationDownloadState(completedBytes: 0, totalBytes: TranslationModel.byteCount) : nil
        modelStatus = localURL == nil ? mirror.downloadStatus : "正在校验模型…"
        modelTask = Task { [self] in
            var temporary: URL?
            defer {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                preparingModel = false
                modelTask = nil
                downloadProgress = nil
            }
            do {
                let file: URL
                if let localURL { file = localURL }
                else {
                    let delegate = TranslationDownloadProgress { [weak self] progress in
                        Task { @MainActor in
                            guard self?.modelPreparationID == preparationID, self?.preparingModel == true,
                                  self?.modelStatus == mirror.downloadStatus else { return }
                            self?.downloadProgress = progress
                        }
                    }
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 60
                    config.timeoutIntervalForResource = 86_400
                    let session = URLSession(configuration: config)
                    defer { session.invalidateAndCancel() }
                    let (url, response) = try await session.download(from: mirror.downloadURL, delegate: delegate)
                    temporary = url
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                        throw ModelFailure("镜像下载失败。可打开镜像模型页面手动下载，再选择本地文件。")
                    }
                    file = url
                }
                try Task.checkCancellation()
                modelStatus = "正在校验模型完整性…"
                downloadProgress = nil
                let verification = Task.detached { try TranslationModel.validateFile(file) }
                try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                try Task.checkCancellation()
                let final: URL
                if localURL != nil { final = file }
                else {
                    let folder = directory.appendingPathComponent("models", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(TranslationModel.filename)
                    // Preserve any existing user file instead of replacing it silently.
                    final = FileManager.default.fileExists(atPath: target.path)
                        ? folder.appendingPathComponent("\(UUID().uuidString)-\(TranslationModel.filename)") : target
                    try FileManager.default.moveItem(at: file, to: final)
                    temporary = final // Clean up if saving the configuration fails.
                }
                var candidate = configuration
                candidate.modelPath = final.path
                candidate.modelIdentity = try TranslationModel.fingerprint(final)
                try setConfiguration(candidate)
                temporary = nil
                modelStatus = "模型已就绪，选中句子或段落后点击「本地翻译」。"
            } catch {
                modelStatus = nil
                if !Task.isCancelled { setupFailure = error.localizedDescription }
            }
        }
    }

    func cancelModelPreparation() { modelTask?.cancel() }
    func stopRuntime() { cancel(); runtime.stop() }
}
