import AppKit
import WebKit

struct EbookDocument {
    let sections: [String]
    var metadata: BookMetadata?
}

/// Runs only our bundled parser in a disposable WebKit process; book markup is never displayed.
@MainActor enum EbookImport {
    nonisolated static let maximumFileSize = 300_000_000

    static func read(_ url: URL, resources: URL? = nil, timeout: TimeInterval = 30) async throws -> [String] {
        try await readDocument(url, resources: resources, timeout: timeout).sections
    }

    static func readDocument(_ url: URL, resources: URL? = nil, timeout: TimeInterval = 30) async throws -> EbookDocument {
        try Task.checkCancellation()
        let data = try await Task.detached(priority: .userInitiated) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumFileSize else { throw BookImport.Failure(message: "文件超过 300 MB，请先拆分。") }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumFileSize else { throw BookImport.Failure(message: "文件超过 300 MB，请先拆分。") }
            return data
        }.value
        try Task.checkCancellation()
        guard let root = resources ?? Bundle.main.resourceURL?.appendingPathComponent("Ebook") else {
            throw BookImport.Failure(message: "内置电子书解析器缺失，请重新安装完整应用。")
        }
        let job = EbookJob(root: root, data: data, name: url.lastPathComponent, kind: url.pathExtension.uppercased())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(timeout: timeout, continuation: continuation)
                if Task.isCancelled { job.finish(.failure(CancellationError())) }
            }
        } onCancel: {
            Task { @MainActor in job.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor private final class EbookJob: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private static let assets: Set<String> = [
        "/ebook-import/host.html", "/ebook-import/compat.js", "/ebook-import/worker.mjs", "/ebook-import/mdx.mjs", "/ebook-import/yomitan.mjs", "/ebook-import/text.mjs", "/ebook-import/zip.mjs",
        "/vendor/foliate/epub.js", "/vendor/foliate/epubcfi.js", "/vendor/foliate/mobi.js", "/vendor/fflate/fflate.mjs"
    ]
    private let root: URL
    private var data: Data?
    private let name: String
    private let kind: String
    private let host = UUID().uuidString.lowercased()
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<EbookDocument, Error>?
    private var watchdog: Task<Void, Never>?
    private var finished = false
    private var inputDelivered = false
    private var dictionaryChunks: [String] = []
    private var dictionaryLength = 0
    private var dictionaryInputOffset = 0
    private var importingDictionary: Bool { kind == "MDX" || kind == "ZIP" }
    private var hostURL: URL { URL(string: "yomitoki-ebook://\(host)/ebook-import/host.html")! }

    init(root: URL, data: Data, name: String, kind: String) {
        self.root = root; self.data = data; self.name = name; self.kind = kind
    }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<EbookDocument, Error>) {
        self.continuation = continuation
        guard Self.assets.allSatisfy({ FileManager.default.isReadableFile(atPath: root.appendingPathComponent(String($0.dropFirst())).path) }) else {
            finish(.failure(BookImport.Failure(message: "内置电子书解析器缺失，请重新安装完整应用。")))
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: "yomitoki-ebook")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = config.userContentController
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "ebook")
        controller.addUserScript(WKUserScript(source: """
        (() => {
          const send = body => window.webkit.messageHandlers.ebook.postMessage(body);
          let kind;
          Object.defineProperty(window, 'ebookImport', { value: Object.freeze({
            input: async () => {
              const value = await send({type: 'input'});
              kind = value.kind;
              const bytes = new Uint8Array(value.length);
              const copy = (base64, offset) => {
                const binary = atob(base64);
                for (let i = 0; i < binary.length; i++) bytes[offset + i] = binary.charCodeAt(i);
                return binary.length;
              };
              if (value.base64 !== undefined) copy(value.base64, 0);
              else {
                for (let offset = 0; offset < bytes.length;) {
                  offset += copy(await send({type: 'dictionary-input'}), offset);
                }
              }
              return { bytes: bytes.buffer, kind: value.kind, name: value.name };
            },
            result: async value => {
              try {
                if (value.ok && (kind === 'ZIP' || kind === 'MDX')) {
                  for (let i = 0; i < value.sections.length; i += 4) {
                    await send({type: 'dictionary-chunks', chunks: value.sections.slice(i, i + 4)});
                  }
                  value = {ok: true};
                }
                await send({type: 'result', value});
              } catch {
                send({type: 'result', value: {ok: false, error: '词典解析结果传输失败。'}}).catch(() => {});
              }
            }
          }) });
          const failed = () => window.ebookImport.result({ok: false, error: '内置电子书解析器运行失败，请重新导入或检查应用完整性。'});
          window.addEventListener('error', failed);
          window.addEventListener('unhandledrejection', failed);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        webView = view
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, min(timeout, 300)) * 1_000_000_000)) }
            catch { return }
            self?.finish(.failure(BookImport.Failure(message: "电子书导入超时，请检查文件或拆分后重试。")))
        }
        view.load(URLRequest(url: hostURL))
    }

    func finish(_ result: Result<EbookDocument, Error>) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel(); watchdog = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "ebook", contentWorld: .page)
        webView = nil
        data = nil
        let completion = continuation; continuation = nil
        completion?.resume(with: result)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard !finished, message.frameInfo.isMainFrame, message.frameInfo.request.url == hostURL,
              let body = message.body as? [String: Any] else { replyHandler(nil, "请求无效。"); return }
        if body["type"] as? String == "input", !inputDelivered, let data {
            inputDelivered = true
            var input: [String: Any] = ["length": data.count, "kind": kind, "name": name]
            if !importingDictionary {
                input["base64"] = data.base64EncodedString()
                self.data = nil
            }
            replyHandler(input, nil)
            return
        }
        if body["type"] as? String == "dictionary-input", importingDictionary, inputDelivered,
           let data, dictionaryInputOffset < data.count {
            let end = min(dictionaryInputOffset + 1_000_000, data.count)
            let base64 = data[dictionaryInputOffset..<end].base64EncodedString()
            dictionaryInputOffset = end
            if end == data.count { self.data = nil }
            replyHandler(base64, nil)
            return
        }
        if body["type"] as? String == "dictionary-chunks", importingDictionary, inputDelivered,
           let chunks = body["chunks"] as? [String] {
            dictionaryLength += chunks.reduce(0, { $0 + $1.utf16.count })
            guard dictionaryLength <= 100_000_000, dictionaryChunks.count + chunks.count <= 10_000 else {
                replyHandler(nil, "词典内容过多。")
                finish(.failure(BookImport.Failure(message: "词典内容过多。")))
                return
            }
            dictionaryChunks.append(contentsOf: chunks)
            replyHandler(true, nil)
            return
        }
        guard body["type"] as? String == "result", inputDelivered, let value = body["value"] as? [String: Any] else {
            replyHandler(nil, "请求无效。"); return
        }
        replyHandler(true, nil)
        if value["ok"] as? Bool == true, importingDictionary, !dictionaryChunks.isEmpty {
            let sections = dictionaryChunks
            dictionaryChunks.removeAll()
            finish(.success(EbookDocument(sections: sections)))
        } else if value["ok"] as? Bool == true, !importingDictionary, let sections = value["sections"] as? [String],
                  !sections.isEmpty, sections.count <= 10_000,
                  sections.reduce(0, { $0 + $1.utf16.count }) <= 10_000_000 {
            let fields = value["metadata"] as? [String: String] ?? [:]
            let metadata = BookMetadata(title: fields["title"], author: fields["author"],
                                        publisher: fields["publisher"], published: fields["published"])
            finish(.success(EbookDocument(sections: sections, metadata: metadata)))
        } else {
            let error = (value["error"] as? String).map { String($0.prefix(500)) } ?? "电子书解析失败，文件格式无效或内容过大。"
            finish(.failure(BookImport.Failure(message: error)))
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard !finished, let url = urlSchemeTask.request.url, url.host == host,
              url.query == nil, Self.assets.contains(url.path),
              let bytes = try? Data(contentsOf: root.appendingPathComponent(String(url.path.dropFirst()))) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let mime = url.path.hasSuffix(".html") ? "text/html" : "text/javascript"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime + "; charset=utf-8", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(bytes)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == hostURL ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { navigationFailed() }
    private func navigationFailed() {
        finish(.failure(BookImport.Failure(message: "内置电子书解析器已停止，请重新导入。")))
    }
}
