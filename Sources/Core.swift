import AppKit
import NaturalLanguage
import PDFKit
import SQLite3

struct BookMetadata: Codable, Sendable {
    var title: String?
    var author: String?
    var publisher: String?
    var published: String?

    init(title: String? = nil, author: String? = nil, publisher: String? = nil, published: String? = nil) {
        func clean(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return String(text.prefix(500))
        }
        self.title = clean(title)
        self.author = clean(author)
        self.publisher = clean(publisher)
        self.published = clean(published)
    }

    func fillingMissing(from source: Self?) -> Self {
        Self(title: title ?? source?.title, author: author ?? source?.author,
             publisher: publisher ?? source?.publisher, published: published ?? source?.published)
    }
}

struct Book: Codable, Identifiable {
    var id = UUID()
    let name: String
    let kind: String
    let pages: [String]
    var page = 0
    var readingOffset: Int? = nil
    var metadata: BookMetadata? = nil
    var removedFromShelf: Bool? = nil

    func clampedReadingOffset(_ offset: Int) -> Int {
        min(max(0, offset), max(0, pages[page].utf16.count - 1))
    }
    var filenameTitle: String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }
    var title: String { metadata?.title ?? filenameTitle }
    var unit: String { kind == "PDF" ? "页" : "节" }
    var characterCount: Int {
        return pages.reduce(0) { count, page in
            page.unicodeScalars.reduce(count) { subtotal, scalar in
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
                    return subtotal + 1
                default:
                    return subtotal
                }
            }
        }
    }

    static let sample = Book(name: "雨上がりの喫茶店.txt", kind: "示例", pages: [
        """
        雨が上がったので、傘を閉じて小さな喫茶店に入った。窓際の席に座ると、淹れたての珈琲の香りが漂ってきた。

        店主は「お好きな席へどうぞ」と言って、穏やかに微笑んだ。私は鞄から読みかけの小説を取り出した。窓の向こうでは、軒先から落ちる雨粒が午後の光を受けてきらきらと輝いていた。

        頁をめくるたび、街の音が少しずつ遠ざかっていくようだった。こういう静かな時間が、たまには必要なのかもしれない。
        """,
        """
        カップの底に少しだけ珈琲が残っていた。外を見れば、雲の切れ間から青空がのぞいている。

        店を出ると、濡れた石畳に夕暮れの色が映っていた。駅に向かう人々の足音を聞きながら、私はさっき読んだ一文を思い返した。

        明日もこの道を通るだろう。その時は、今日とは違う何かに気づくかもしれない。
        """
    ])
}

struct Definition: Codable, Equatable {
    let head: String
    let reading: String
    let chinese: String?
    let english: String?
    var source: String? = nil
    var etymology: String? = nil
    var dictionaryName: String? = nil
    var dictionaryText: String? = nil
    var modelNote: String? = nil
    var hasMeaning: Bool { chinese != nil || english != nil || dictionaryText != nil }
    var chineseMeaning: String? {
        guard let text = chinese?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

struct NotebookMeanings {
    let chinese: String?
    let modelDefinitions: [Definition]
}

struct SentenceContext: Codable, Equatable {
    let before: String
    let word: String
    let after: String
    var sentence: String { before + word + after }
}

struct Occurrence: Codable, Identifiable, Equatable {
    var id = UUID()
    let bookID: UUID
    let filename: String
    let kind: String
    let page: Int
    let offset: Int
    let context: SentenceContext
    var definition: Definition? = nil
    var location: String { "第 \(page + 1) \(kind == "PDF" ? "页" : "节")" }
    func samePlace(as other: Self) -> Bool {
        bookID == other.bookID && page == other.page && offset == other.offset
    }
}

struct SavedWord: Codable, Identifiable, Equatable {
    let definition: Definition
    var examples: [Occurrence]
    var id: String { definition.head + "\n" + definition.reading }

    private enum CodingKeys: String, CodingKey { case definition, examples }

    init(definition: Definition, examples: [Occurrence]) {
        self.definition = definition
        self.examples = examples
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(definition, forKey: .definition)
        // A nil example definition inherits the word definition when read or exported.
        let compact = examples.map { example -> Occurrence in
            var example = example
            if example.definition == definition { example.definition = nil }
            return example
        }
        try container.encode(compact, forKey: .examples)
    }
}

struct Lookup {
    let definition: Definition
    let occurrence: Occurrence
    var key: String { definition.head + "\n" + definition.reading }
    var range: NSRange { NSRange(location: occurrence.offset, length: occurrence.context.word.utf16.count) }
}

struct ReadingNote: Codable, Identifiable {
    var id = UUID()
    let bookID: UUID
    let page: Int
    let excerpt: String?
    var body: String

    var hasBody: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasExcerpt: Bool { !(excerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct LibraryData: Codable {
    var books: [Book]
    var words: [SavedWord]
    var current: UUID?
    var notes: [ReadingNote] = []
    static var initial: Self { .init(books: [.sample], words: [], current: Book.sample.id) }

    private enum CodingKeys: String, CodingKey { case books, words, current, notes }

    init(books: [Book], words: [SavedWord], current: UUID) {
        self.books = books
        self.words = words
        self.current = current
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        books = try values.decode([Book].self, forKey: .books)
        words = try values.decode([SavedWord].self, forKey: .words)
        current = try values.decodeIfPresent(UUID.self, forKey: .current)
        notes = try values.decodeIfPresent([ReadingNote].self, forKey: .notes) ?? []
    }
}

enum BookImport {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @MainActor static func read(_ url: URL, ebookResources: URL? = nil, timeout: TimeInterval = 30) async throws -> Book {
        try Task.checkCancellation()
        let kind = url.pathExtension.uppercased()
        let pages: [String]
        let metadata: BookMetadata?
        switch kind {
        case "PDF":
            (pages, metadata) = try await Task.detached(priority: .userInitiated) { try readPDF(url) }.value
        case "EPUB", "MOBI":
            let ebook = try await EbookImport.readDocument(url, resources: ebookResources, timeout: timeout)
            pages = paginate(ebook.sections.joined(separator: "\n\n"))
            metadata = ebook.metadata
        default:
            throw Failure(message: "请选择 PDF、EPUB 或 MOBI 文件。")
        }
        try Task.checkCancellation()
        guard pages.contains(where: { !$0.isEmpty }) else {
            throw Failure(message: "文件中没有可提取的文字。扫描版 PDF 需要先进行 OCR。")
        }
        return Book(name: url.lastPathComponent, kind: kind, pages: pages, metadata: metadata)
    }

    private static func readPDF(_ url: URL) throws -> ([String], BookMetadata?) {
        guard let doc = PDFDocument(url: url), !doc.isLocked else {
            throw Failure(message: "无法读取 PDF。请检查文件是否完整，或先解除密码保护。")
        }
        let attributes = doc.documentAttributes
        let xmp = pdfMetadata(doc)
        let metadata = BookMetadata(title: attributes?[PDFDocumentAttribute.titleAttribute] as? String,
                                    author: attributes?[PDFDocumentAttribute.authorAttribute] as? String)
            .fillingMissing(from: xmp)
        let pages = (0..<doc.pageCount).map { index in
            let text = doc.page(at: index)?.string ?? ""
            return clean(text.replacingOccurrences(of: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}、])\h*\n\h*(?=[\p{Han}\p{Hiragana}\p{Katakana}])"#, with: "", options: .regularExpression))
        }
        return (pages, metadata)
    }

    private static func pdfMetadata(_ document: PDFDocument) -> BookMetadata? {
        guard let reference = document.documentRef, let catalog = reference.catalog else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, data.count <= 1_000_000,
              let xml = try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever) else { return nil }
        func field(_ key: String, multiple: Bool = false) -> String? {
            let query = "//*[local-name()='\(key)' and namespace-uri()='http://purl.org/dc/elements/1.1/']"
            guard let node = try? xml.nodes(forXPath: query).first else { return nil }
            let items = (try? node.nodes(forXPath: ".//*[local-name()='li']")) ?? []
            if items.isEmpty { return node.stringValue }
            let values = items.compactMap(\.stringValue)
            return multiple ? values.joined(separator: "、") : values.first
        }
        return BookMetadata(title: field("title"), author: field("creator", multiple: true),
                            publisher: field("publisher", multiple: true), published: field("date"))
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paginate(_ text: String) -> [String] {
        let paragraphs = text.replacingOccurrences(of: #"\n[\t ]*\n+"#, with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n\n").map(clean).filter { !$0.isEmpty }
        var result: [String] = []
        var page = ""
        for paragraph in paragraphs {
            if !page.isEmpty, page.utf16.count + paragraph.utf16.count > 1100 {
                result.append(page)
                page = ""
            }
            page += page.isEmpty ? paragraph : "\n\n" + paragraph
        }
        if !page.isEmpty { result.append(page) }
        return result
    }
}

final class Lexicon {
    private var db: OpaquePointer?
    private var statement: OpaquePointer?
    private var cache: [String: [Entry]] = [:]
    private let chinese: [String: String]
    struct Entry {
        let head: String
        let reading: String
        let gloss: String
        let pos: [String]
        let common: Bool
    }

    init(resources: URL) {
        let url = resources.appendingPathComponent("jmdict.sqlite")
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            sqlite3_prepare_v2(db, "SELECT head, reading, meaning, pos, rank FROM entries WHERE form=? ORDER BY rank DESC LIMIT 24", -1, &statement, nil)
        }
        let tsv = (try? String(contentsOf: resources.appendingPathComponent("zh.tsv"), encoding: .utf8)) ?? ""
        chinese = Dictionary(tsv.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }, uniquingKeysWith: { first, _ in first })
    }
    deinit {
        sqlite3_finalize(statement)
        sqlite3_close(db)
    }

    func entries(_ form: String) -> [Entry] {
        if let saved = cache[form] { return saved }
        guard let statement else { return [] }
        sqlite3_reset(statement)
        _ = form.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var entries: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let values = (0..<4).map { i in sqlite3_column_text(statement, Int32(i)).map { String(cString: $0) } ?? "" }
            entries.append(.init(head: values[0], reading: values[1], gloss: values[2], pos: values[3].components(separatedBy: " "), common: sqlite3_column_int(statement, 4) == 1))
        }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[form] = entries
        return entries
    }

    func definition(_ entry: Entry) -> Definition {
        let meanings = entry.gloss.split(separator: "\n").prefix(4)
        let english = meanings.enumerated().map { index, meaning in "\(index + 1). \(meaning)" }.joined(separator: "\n")
        return Definition(head: entry.head, reading: entry.reading, chinese: chinese[entry.head], english: english)
    }

    func addingDictionaryEnglish(to value: Definition) -> Definition {
        guard value.dictionaryName == nil, value.english == nil,
              let entry = entries(value.head).first(where: { $0.reading == value.reading }) else { return value }
        return Definition(head: value.head, reading: value.reading, chinese: value.chinese,
                          english: definition(entry).english, source: value.source, etymology: value.etymology,
                          modelNote: value.modelNote)
    }

    func partsOfSpeech(for value: Definition) -> [DictionaryPartOfSpeech] {
        let canonical = normalized(value)
        let candidates = entries(canonical.head).filter { $0.head == canonical.head }
        let matches: [Entry]
        if canonical.reading.isEmpty {
            // Old words without readings are safe only when the spelling is unambiguous.
            guard Set(candidates.map(\.reading)).count == 1 else { return [] }
            matches = candidates
        } else {
            matches = candidates.filter { $0.reading == canonical.reading }
        }
        var seen = Set<String>()
        return matches.flatMap(\.pos).compactMap { raw in
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, seen.insert(code).inserted else { return nil }
            return DictionaryPartOfSpeech(code: code)
        }
    }

    func notebookMeanings(for word: SavedWord) -> NotebookMeanings {
        let definitions = [word.definition] + word.examples.compactMap(\.definition)
        let savedChinese = definitions.lazy.filter { $0.source == nil }.compactMap(\.chineseMeaning).first
        let dictionaryChinese = chinese[word.definition.head]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models: [Definition] = []
        for value in definitions where value.source != nil && value.chineseMeaning != nil {
            if !models.contains(where: {
                $0.chineseMeaning == value.chineseMeaning && $0.source == value.source && $0.etymology == value.etymology
            }) { models.append(value) }
        }
        return NotebookMeanings(chinese: savedChinese ?? dictionaryChinese.flatMap { $0.isEmpty ? nil : $0 },
                                modelDefinitions: models)
    }

    private let particles: Set<String> = ["は", "が", "を", "に", "で", "と", "へ", "の", "も", "や", "て", "た", "か", "ね", "よ", "な", "まで", "から", "ので", "です", "ます"]

    func lookup(book: Book, page: Int, at offset: Int, tokens: [NSRange]) -> Lookup? {
        let text = book.pages[page] as NSString
        guard let index = tokens.firstIndex(where: { NSLocationInRange(offset, $0) }) else { return nil }
        let range = tokens[index]
        let surface = text.substring(with: range)
        let next = tokens.dropFirst(index + 1).prefix(3)
        var spans: [(String, NSRange)] = [(surface, range)]
        for token in next {
            guard NSMaxRange(spans.last!.1) == token.location else { break }
            let span = NSUnionRange(range, token)
            spans.append((text.substring(with: span), span))
        }
        let choice = choose(surface: surface, spans: spans)
        return makeLookup(book: book, page: page, range: choice?.1 ?? range, entry: choice?.0)
    }

    func lookup(book: Book, page: Int, selection: NSRange) -> Lookup? {
        guard book.pages.indices.contains(page) else { return nil }
        let content = book.pages[page]
        let text = content as NSString
        guard selection.location >= 0, selection.location <= text.length, selection.length > 0,
              selection.length <= text.length - selection.location, let range = Range(selection, in: content) else { return nil }
        let surface = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        let selectedRange = text.range(of: surface, options: .literal, range: selection)
        let entry = entries(surface).first ?? inflectedEntry(surface)
        return makeLookup(book: book, page: page, range: selectedRange, entry: entry)
    }

    private func makeLookup(book: Book, page: Int, range selectedRange: NSRange, entry: Entry?) -> Lookup {
        let context = Self.context(book: book, page: page, range: selectedRange)
        let occurrence = Occurrence(bookID: book.id, filename: book.name, kind: book.kind, page: page, offset: selectedRange.location, context: context)
        let definition = entry.map { definition($0) }
            ?? Definition(head: context.word, reading: "", chinese: chinese[context.word], english: nil)
        return Lookup(definition: definition, occurrence: occurrence)
    }

    private func inflectedEntry(_ form: String) -> Entry? {
        for (suffix, replacement, classes) in Self.inflections where form.hasSuffix(suffix) && form.count >= suffix.count {
            let base = String(form.dropLast(suffix.count)) + replacement
            if let entry = entries(base).first(where: { entry in entry.pos.contains { classes.contains($0) } }) {
                return entry
            }
        }
        return nil
    }

    func normalized(_ value: Definition) -> Definition {
        let head = value.head.trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = value.reading.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = entries(head)
        // Keep distinct readings of the same spelling separate. Only use an exact
        // dictionary entry when its reading agrees with the supplied definition.
        let entry = exact.first(where: { $0.reading == reading })
            ?? (exact.isEmpty ? inflectedEntry(head) : nil)
        return Definition(head: entry?.head ?? head, reading: entry?.reading ?? reading,
                          chinese: value.chinese, english: value.english,
                          source: value.source, etymology: value.etymology,
                          dictionaryName: value.dictionaryName, dictionaryText: value.dictionaryText, modelNote: value.modelNote)
    }

    func normalizedWords(_ words: [SavedWord]) -> [SavedWord] {
        var result: [SavedWord] = []
        var indices: [String: Int] = [:]
        for word in words {
            let definition = normalized(word.definition)
            let key = definition.head + "\n" + definition.reading
            let index: Int
            if let existing = indices[key] {
                index = existing
            } else {
                index = result.count
                indices[key] = index
                result.append(SavedWord(definition: definition, examples: []))
            }
            for var example in word.examples {
                let meaning = example.definition.map(normalized) ?? definition
                example.definition = meaning == result[index].definition ? nil : meaning
                if !result[index].examples.contains(where: {
                    $0.samePlace(as: example) && $0.context == example.context
                        && ($0.definition ?? result[index].definition) == meaning
                }) {
                    result[index].examples.append(example)
                }
            }
        }
        return result
    }

    private func choose(surface: String, spans: [(String, NSRange)]) -> (Entry, NSRange)? {
        if particles.contains(surface), let exact = entries(surface).first(where: { $0.head == surface }) {
            return (exact, spans[0].1)
        }
        for (form, range) in spans.dropFirst().reversed() {
            if let entry = entries(form).first(where: { $0.common && !$0.pos.contains("exp") }) {
                return (entry, range)
            }
            if let entry = inflectedEntry(form) { return (entry, range) }
        }
        if let entry = entries(surface).first { return (entry, spans[0].1) }
        if let entry = inflectedEntry(surface) { return (entry, spans[0].1) }
        for (form, range) in spans.dropFirst().reversed() {
            if let entry = entries(form).first, range.length <= 10 { return (entry, range) }
        }
        return nil
    }

    private static let inflections: [(String, String, Set<String>)] = {
        var rules: [(String, String, Set<String>)] = []
        func add(_ endings: [String], _ root: String, _ classes: Set<String>) {
            rules.append(contentsOf: endings.map { ($0, root, classes) })
        }
        let polite = ["ます", "ました", "ません", "ませんでした", "ましょう", "たい", "たかった", "たくない"]
        let negative = ["ない", "なかった", "なくて", "なければ"]
        let progressive = ["いる", "いた", "います", "いました", "いない", "いなかった", "しまう", "しまった"]
        add(["た", "て", "れば", "よう", "ろ"] + polite + negative
            + ["られる", "られた", "られない", "られなかった", "させる", "させた", "させられる", "させられた"]
            + progressive.map { "て" + $0 }, "る", ["v1", "v1-s"])
        add(["した", "して", "しない", "しなかった", "しなくて", "すれば", "しよう", "された", "される", "させる"]
            + polite.map { "し" + $0 } + progressive.map { "して" + $0 }, "する", ["vs-i", "vs-s", "vs"])
        add(["来た", "来て", "来ない", "来なかった", "来れば", "来よう", "来られる", "来られた"]
            + polite.map { "来" + $0 } + progressive.map { "来て" + $0 }, "来る", ["vk"])
        add(["きた", "きて", "こない", "こなかった", "くれば", "こよう", "こられる", "こられた"]
            + polite.map { "き" + $0 } + progressive.map { "きて" + $0 }, "くる", ["vk"])
        add(["かった", "くて", "くない", "くなかった", "くなくて", "ければ"], "い", ["adj-i", "adj-ix"])
        add(["よかった", "よくて", "よくない", "よくなかった", "よければ"], "いい", ["adj-ix"])
        add(["だった", "ではない", "ではなかった", "じゃない", "じゃなかった", "な"], "", ["adj-na"])
        let godan = [("う", "い", "わ", "っ", "え", "お", "v5u"), ("つ", "ち", "た", "っ", "て", "と", "v5t"),
                     ("る", "り", "ら", "っ", "れ", "ろ", "v5r"), ("む", "み", "ま", "ん", "め", "も", "v5m"),
                     ("ぶ", "び", "ば", "ん", "べ", "ぼ", "v5b"), ("ぬ", "に", "な", "ん", "ね", "の", "v5n"),
                     ("く", "き", "か", "い", "け", "こ", "v5k"), ("ぐ", "ぎ", "が", "い", "げ", "ご", "v5g"),
                     ("す", "し", "さ", "し", "せ", "そ", "v5s"), ("く", "き", "か", "っ", "け", "こ", "v5k-s")]
        for (base, stem, a, past, e, o, type) in godan {
            add(polite.map { stem + $0 }, base, [type])
            add(negative.map { a + $0 }, base, [type])
            let te = base == "ぐ" || past == "ん" ? "で" : "て"
            let ta = te == "で" ? "だ" : "た"
            add([past + ta, past + te] + progressive.map { past + te + $0 }, base, [type])
            add([e + "ば", e + "る", e + "た", e + "ない", e + "なかった", o + "う",
                 a + "れる", a + "れた", a + "れない", a + "れなかった", a + "せる", a + "せた",
                 a + "せられる", a + "せられた"], base, [type])
        }
        // Keep the order deterministic when several conjugation classes share an ending.
        return rules.enumerated().sorted {
            $0.element.0.count == $1.element.0.count ? $0.offset < $1.offset : $0.element.0.count > $1.element.0.count
        }.map(\.element)
    }()

    static func tokens(_ text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.japanese)
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .filter { text[$0].unicodeScalars.contains { CharacterSet.letters.contains($0) } }
            .map { NSRange($0, in: text) }
    }

    private static let stops = try! NSRegularExpression(pattern: #"[。！？!?]+[」』）】〕〉》”’]*|\n\s*\n"#)
    static func context(book: Book, page: Int, range: NSRange) -> SentenceContext {
        var content = book.pages[page]
        var start = range.location
        if page > 0 {
            let previous = book.pages[page - 1]
            if !previous.isEmpty {
                let separator = book.kind == "PDF" ? "" : "\n\n"
                content = previous + separator + content
                start += (previous + separator).utf16.count
            }
        }
        if page + 1 < book.pages.count {
            let separator = book.kind == "PDF" ? "" : "\n\n"
            content += separator + book.pages[page + 1]
        }
        let string = content as NSString
        let end = start + range.length
        var lower = 0
        var upper = string.length
        for match in stops.matches(in: content, range: NSRange(location: 0, length: string.length)) {
            if NSMaxRange(match.range) <= start {
                lower = NSMaxRange(match.range)
            } else if match.range.location >= end {
                let delimiter = string.substring(with: match.range)
                upper = delimiter.hasPrefix("\n") ? match.range.location : NSMaxRange(match.range)
                break
            }
        }
        let before = string.substring(with: NSRange(location: lower, length: start - lower))
        let after = string.substring(with: NSRange(location: end, length: upper - end))
        return SentenceContext(before: before.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression),
                       word: string.substring(with: NSRange(location: start, length: range.length)),
                       after: after.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
    }
}
