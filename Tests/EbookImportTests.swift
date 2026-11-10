import AppKit
import CryptoKit
import PDFKit
import JavaScriptCore

private struct EbookTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw EbookTestFailure(message: message) }
}
private struct Fixture: Decodable {
    let id: String, file: String, kind: String, reject: Bool, sha256: String
    let expected: String?
    let long: Bool?
    var blocks: [String] {
        if long == true {
            return (1...30).flatMap { chapter in
                ["第\(chapter)章", "LONG\(chapter)_START " + String(repeating: "私は静かな喫茶店で本を読み、窓の外を見た。", count: 250) + " LONG\(chapter)_END"]
            }
        }
        return (expected ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
}
private func compact(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }

@main struct EbookImportTests {
    @MainActor static func wait(_ state: ReaderState) async throws {
        let end = Date().addingTimeInterval(40)
        while state.importing, Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        try require(!state.importing, "Reader import did not finish")
    }
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        guard CommandLine.arguments.count == 4 else { throw EbookTestFailure(message: "Expected fixtures, app resources, report") }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundled = CommandLine.arguments[2] == "--bundled"
        let resources = bundled ? Bundle.main.resourceURL! : URL(fileURLWithPath: CommandLine.arguments[2])
        let ebook: URL? = bundled ? nil : resources.appendingPathComponent("Ebook")
        let report = URL(fileURLWithPath: CommandLine.arguments[3])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Yomitoki macOS 日本語 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Exercise the exact compatibility bootstrap with APIs absent, as on Safari 17.0.
        let js = JSContext()!
        js.evaluateScript("Object.groupBy = undefined; Map.groupBy = undefined;")
        js.evaluateScript(try String(contentsOf: resources.appendingPathComponent("Ebook/ebook-import/compat.js"), encoding: .utf8))
        let grouping = js.evaluateScript("""
        (() => {
          const symbol = Symbol(), key = {};
          const object = Object.groupBy(['__proto__', '__proto__', 'x'], x => x);
          const symbols = Object.groupBy([1, 2], () => symbol);
          const map = Map.groupBy([key, key, NaN, NaN], x => x);
          return Object.getPrototypeOf(object) === null && object.__proto__.length === 2
            && symbols[symbol].length === 2 && map.get(key).length === 2 && map.get(NaN).length === 2
            && JSON.stringify(Object.groupBy(new Set([3, 4]), (_, i) => i)) === '{"0":[3],"1":[4]}';
        })()
        """)
        try require(js.exception == nil && grouping?.toBool() == true, "Safari 17.0 grouping compatibility")
        let originalGrouping = js.evaluateScript("Object.groupBy")!
        js.evaluateScript(try String(contentsOf: resources.appendingPathComponent("Ebook/ebook-import/compat.js"), encoding: .utf8))
        try require(js.evaluateScript("Object.groupBy")!.isEqual(to: originalGrouping), "Bootstrap must preserve existing APIs")
        let state = ReaderState(directory: directory, resources: resources)
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json")))
        let windowCount = NSApp.windows.filter { $0.isVisible }.count
        var results: [[String: Any]] = []
        for test in cases {
            let file = fixtures.appendingPathComponent(test.file)
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            try require(digest == test.sha256, "Fixture hash changed: " + test.id)
            let before = try JSONEncoder().encode(state.library)
            let count = state.library.books.count
            state.failure = nil
            state.importBook(file, ebookResources: ebook)
            try await wait(state)
            if test.reject {
                try require(state.library.books.count == count && state.failure != nil, "Must reject: " + test.id)
                // Compare decoded data, since JSON object key order is intentionally unspecified.
                let old = try JSONSerialization.jsonObject(with: before) as! NSDictionary
                let now = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.library)) as! NSDictionary
                try require(old == now, "Rejected file changed library: " + test.id)
            } else {
                try require(state.failure == nil, test.id + ": " + (state.failure ?? ""))
                try require(state.library.books.count == count + 1 && state.book.kind == test.kind, "Import contract: " + test.id)
                let text = compact(state.book.pages.joined(separator: "\n\n"))
                var tail = text.startIndex
                for block in test.blocks {
                    guard let found = text.range(of: compact(block), range: tail..<text.endIndex) else {
                        throw EbookTestFailure(message: "Missing/out-of-order text: " + test.id + " " + String(block.prefix(60)))
                    }
                    tail = found.upperBound
                }
                for marker in ["HIDDEN_ATTR_PROBE", "HIDDEN_INLINE_PROBE", "HIDDEN_CSS_PROBE", "SCRIPT_PROBE", "STYLE_PROBE"] {
                    try require(!text.contains(marker), "Hidden content leaked: " + test.id)
                }
                if !["mobi6-japanese", "mobi6-uncompressed"].contains(test.id) {
                    try require(!text.contains("きっさてん"), "Ruby leaked: " + test.id)
                }
                if test.long == true {
                    try require(state.book.pages.count >= 30, "Long book lost pages")
                    state.showPage(2)
                    try require(state.book.page == 2, "Long book navigation")
                }
            }
            try require(NSApp.windows.filter { $0.isVisible }.count == windowCount, "Parser leaked a visible window")
            results.append(["id": test.id, "rejectedAsExpected": test.reject, "ok": true])
            print("PASS " + test.id)
        }
        let ruby = fixtures.appendingPathComponent("epub3-japanese-ruby.epub")
        let originalCount = state.library.books.count
        state.importBook(ruby, ebookResources: ebook)
        try await wait(state)
        try require(state.library.books.count == originalCount, "Duplicate import created another book")
        let range = (state.book.pages[0] as NSString).range(of: "喫茶店")
        try require(range.location != NSNotFound, "Imported body available to reader")
        _ = state.choose(range.location)
        try require(state.lookup?.definition.head == "喫茶店", "Lookup of imported word")
        state.save(state.lookup!)
        let restored = ReaderState(directory: directory, resources: resources)
        try require(restored.book.pages == state.book.pages && restored.library.words.contains { $0.definition.head == "喫茶店" }, "Restart restores reader and notebook")
        let saved = try Data(contentsOf: state.path)
        for delay in [UInt64(0), 20_000_000] {
            state.failure = nil
            state.importBook(fixtures.appendingPathComponent("epub3-ruby-many-chapters.epub"), ebookResources: ebook)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try require(state.importing, "Import finished before running cancellation could be tested")
            state.cancelImport()
            try await wait(state)
            try require(state.failure == nil && (try Data(contentsOf: state.path)) == saved, "Cancelled import must preserve all saved data")
        }
        state.importBook(ruby, ebookResources: ebook)
        state.openBook(state.book.id)
        try await wait(state)
        try require(try Data(contentsOf: state.path) == saved, "Navigation must cancel import")
        do {
            _ = try await BookImport.read(ruby, ebookResources: ebook, timeout: 0.001)
            throw EbookTestFailure(message: "Timeout was ignored")
        } catch let error as BookImport.Failure { try require(error.message.contains("超时"), "Timeout error") }
        let cancelled = Task { try await BookImport.read(ruby, ebookResources: ebook) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw EbookTestFailure(message: "Pre-cancelled task ran") }
        catch is CancellationError {}
        do {
            _ = try await BookImport.read(ruby, ebookResources: directory.appendingPathComponent("missing"))
            throw EbookTestFailure(message: "Missing resources accepted")
        } catch let error as BookImport.Failure { try require(error.message.contains("解析器缺失"), "Missing parser error") }
        // A killed parser must not interfere with the next disposable WebKit instance.
        let recovered = try await BookImport.read(ruby, ebookResources: ebook)
        try require(recovered.pages == state.book.pages, "Import did not recover after cancellation/timeout")
        // Preserve PDF text extraction while replacing only the ebook implementation.
        let pdf = directory.appendingPathComponent("日本語 PDF.pdf")
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: CGDataConsumer(data: output)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "PDF regression 喫茶店", attributes: [.font: NSFont.systemFont(ofSize: 20)]).draw(at: NSPoint(x: 40, y: 700))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        try (output as Data).write(to: pdf)
        let importedPDF = try await BookImport.read(pdf)
        try require(importedPDF.kind == "PDF" && importedPDF.pages.joined().contains("喫茶店"), "PDF regression")
        let payload: [String: Any] = [
            "platform": "macOS", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "resourcePath": resources.path, "bundledResourceLookup": bundled, "results": results,
            "checks": ["legacyWebKitGrouping", "fixtureHashes", "chapterOrder", "unicode", "ruby", "hiddenContent", "longBookNavigation", "duplicateImport", "dictionaryLookup", "notebookSave", "restartRestore", "earlyCancellation", "runningCancellation", "navigationCancellation", "timeout", "preCancelledTask", "missingResources", "recovery", "pdf", "noVisibleParserWindow"]
        ]
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        print("Passed all 25 native macOS ebook cases and reader/persistence/cancellation/PDF regression checks.")
    }
    @MainActor static func main() async {
        do { try await run(); exit(0) }
        catch { fputs("FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
