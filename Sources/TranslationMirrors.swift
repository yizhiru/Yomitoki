import Foundation

enum TranslationMirror: String, Codable, CaseIterable, Sendable {
    case hfMirror, modelScope

    var title: String {
        switch self {
        case .hfMirror: return "镜像 1 · HF 镜像"
        case .modelScope: return "镜像 2 · ModelScope"
        }
    }

    var downloadURL: URL {
        switch self {
        case .hfMirror: return TranslationModel.downloadURL
        case .modelScope:
            return URL(string: "https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-1.8B-GGUF/resolve/ef1d40b8b315575d30d1eb6579996130b8fc0bb2/Hy-MT2-1.8B-Q4_K_M.gguf")!
        }
    }

    var homepage: URL {
        switch self {
        case .hfMirror: return TranslationModel.homepage
        case .modelScope: return URL(string: "https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-1.8B-GGUF")!
        }
    }

    var downloadStatus: String { "正在从\(title)下载模型…" }
}

enum TranslationMirrorSpeed: Equatable {
    case testing
    case measured(bytesPerSecond: Double)
    case unavailable
}

struct TranslationMirrorProbe {
    static let sampleBytes = 4 * 1024 * 1024
    let sampleBytes: Int
    let configuration: URLSessionConfiguration

    init(sampleBytes: Int = Self.sampleBytes, configuration: URLSessionConfiguration = .ephemeral) {
        self.sampleBytes = sampleBytes
        self.configuration = configuration
    }

    func measure(_ mirror: TranslationMirror) async throws -> Double {
        try Task.checkCancellation()
        guard sampleBytes > 0 && Int64(sampleBytes) < TranslationModel.byteCount else {
            throw ModelFailure("测速文件片段无效。")
        }
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: mirror.downloadURL)
        request.setValue("bytes=0-\(sampleBytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let started = ProcessInfo.processInfo.systemUptime
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            let expectedRange = "bytes 0-\(sampleBytes - 1)/\(TranslationModel.byteCount)"
            guard let response = response as? HTTPURLResponse, response.statusCode == 206,
                  response.value(forHTTPHeaderField: "Content-Range") == expectedRange else {
                throw ModelFailure("该下载源暂不支持快速测速。")
            }
            var received = 0
            for try await _ in bytes {
                received += 1
                if received == sampleBytes { break }
            }
            try Task.checkCancellation()
            guard received == sampleBytes else { throw ModelFailure("测速片段未下载完整。") }
            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - started)
            return Double(received) / elapsed
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}
