import Foundation
import SQLite3

private struct CacheTestFailure: Error { let message: String }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CacheTestFailure(message: message) }
}

@main struct DefinitionCacheTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("jmdict.sqlite").path, &db) == SQLITE_OK else {
            throw CacheTestFailure(message: "Fixture database")
        }
        let sql = """
        CREATE TABLE entries(form TEXT, head TEXT, reading TEXT, meaning TEXT, pos TEXT, rank INTEGER);
        INSERT INTO entries VALUES('食べる','食べる','たべる','eat','v1',1);
        INSERT INTO entries VALUES('読む','読む','よむ','read','v5m',1);
        INSERT INTO entries VALUES('微笑む','微笑む','ほほえむ','smile','v5m vi',1);
        INSERT INTO entries VALUES('書く','書く','かく','write','v5k',1);
        INSERT INTO entries VALUES('来る','来る','くる','come','vk',1);
        INSERT INTO entries VALUES('する','する','する','do','vs-i',1);
        INSERT INTO entries VALUES('高い','高い','たかい','high','adj-i',1);
        INSERT INTO entries VALUES('静か','静か','しずか','quiet','adj-na',1);
        """
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        try require(status == SQLITE_OK, "Create dictionary fixture")
        try "食べる\t吃；进食\n読む\t阅读\n".write(to: directory.appendingPathComponent("zh.tsv"), atomically: true, encoding: .utf8)
        let dictionary = Lexicon(resources: directory)
        func selected(_ surface: String, after: String = "。") -> Lookup {
            let book = Book(name: "cache.txt", kind: "TXT", pages: [surface + after])
            return dictionary.lookup(book: book, page: 0, selection: NSRange(location: 0, length: surface.utf16.count))!
        }
        for (surface, base) in [
            ("食べた", "食べる"), ("食べませんでした", "食べる"), ("食べていました", "食べる"),
            ("食べられなかった", "食べる"), ("読んでいた", "読む"), ("読みました", "読む"),
            ("読めなかった", "読む"), ("読まれた", "読む"), ("書かせた", "書く"),
            ("来ました", "来る"), ("した", "する"), ("高かった", "高い"),
            ("高くなかった", "高い"), ("静かだった", "静か"),
            ("微笑んだ", "微笑む"), ("微笑んで", "微笑む"), ("微笑んでいた", "微笑む"),
            ("微笑みました", "微笑む"), ("微笑まなかった", "微笑む")
        ] {
            try require(selected(surface).definition.head == base, "Normalize conjugation: \(surface)")
            let tapped = dictionary.lookup(book: Book(name: "tap", kind: "TXT", pages: [surface]), page: 0, at: 0,
                                          tokens: [NSRange(location: 0, length: surface.utf16.count)])
            try require(tapped?.definition.head == base, "Normalize a single clicked token: \(surface)")
        }

        var settings = DefinitionSettings()
        settings.provider = .custom
        settings.customURL = "https://example.com/v1"
        settings.customModel = "model-a"
        let path = directory.appendingPathComponent("definitions.json")
        let resolver = DefinitionResolver(path: path, dictionary: dictionary)
        var requests = 0
        let generated = Definition(head: "食べた", reading: "たべた", chinese: "吃；过去式。", english: nil, source: "test")
        let first = try await resolver.resolve(selected("食べた"), settings: settings, savedWords: []) {
            requests += 1
            return generated
        }
        try require(!first.reused && first.definition.head == "食べる" && first.definition.reading == "たべる",
                    "Model output is stored under its dictionary form")
        for form in ["食べた", "食べない", "食べます", "食べられた"] {
            let result = try await resolver.resolve(selected(form), settings: settings, savedWords: []) {
                throw CacheTestFailure(message: "Cache hit invoked network or API key access")
            }
            try require(result.reused && result.definition == first.definition, "Reuse a previously queried lemma")
        }
        try require(requests == 1, "All conjugations reuse one model request")
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        try require((persisted["entries"] as! [Any]).count == 1, "One cached record per lemma and reading")
        let reopened = DefinitionResolver(path: path, dictionary: dictionary)
        let diskHit = try await reopened.resolve(selected("食べなかった"), settings: settings, savedWords: []) {
            throw CacheTestFailure(message: "Persisted cache missed")
        }
        try require(diskHit.reused, "Cache survives application restarts without adding to notebook")

        let secondContext = selected("食べない")
        let secondMeaning = Definition(head: "食べる", reading: "たべる", chinese: "不吃。", english: nil, source: "test")
        let contextualLookup = try await reopened.resolve(secondContext, settings: settings, savedWords: [],
                                                          requireExactContext: true) { secondMeaning }
        try require(contextualLookup.definition == secondMeaning && !contextualLookup.reused,
                    "A new context must not reuse a different sentence's definition")
        let contextsReopened = DefinitionResolver(path: path, dictionary: dictionary)
        for (form, expected) in [("食べた", first.definition), ("食べない", secondMeaning)] {
            let hit = try await contextsReopened.resolve(selected(form), settings: settings, savedWords: [],
                                                        requireExactContext: true) {
                throw CacheTestFailure(message: "Exact context should survive a restart")
            }
            try require(hit.definition == expected && hit.reused, "Each context retains its own meaning")
        }

        var savedExample = selected("食べた").occurrence
        let contextual = Definition(head: "食べる", reading: "たべる", chinese: "吃过亏。", english: nil, source: "saved")
        savedExample.definition = contextual
        let word = SavedWord(definition: first.definition, examples: [savedExample])
        let empty = DefinitionResolver(path: directory.appendingPathComponent("empty.json"), dictionary: dictionary)
        let savedHit = try await empty.resolve(selected("食べた"), settings: settings, savedWords: [word]) {
            throw CacheTestFailure(message: "Saved contextual definition invoked network")
        }
        try require(savedHit.definition == contextual && savedHit.reused, "Prefer saved meaning for the same sentence")
        let savedLemmaHit = try await empty.resolve(selected("食べない"), settings: settings, savedWords: [word]) {
            throw CacheTestFailure(message: "Saved lemma invoked network")
        }
        try require(savedLemmaHit.definition == first.definition, "Reuse the notebook lemma in a new sentence")
        let refreshed = try await empty.resolve(selected("食べた"), settings: settings, savedWords: [word], refresh: true) {
            requests += 1
            return contextual
        }
        try require(!refreshed.reused && refreshed.definition == contextual, "Explicit regeneration bypasses cached and saved data")

        var changed = settings
        changed.customURL = "https://other.example.com/v1"
        _ = try await resolver.resolve(selected("食べた"), settings: changed, savedWords: []) { requests += 1; return generated }
        changed = settings
        changed.customModel = "model-b"
        _ = try await resolver.resolve(selected("食べた"), settings: changed, savedWords: []) { requests += 1; return generated }
        try require(requests == 4, "Different API endpoints and model names have independent caches")

        let correctedSelection = Lookup(definition: Definition(head: "行う", reading: "おこなう", chinese: "进行", english: nil),
                                       occurrence: selected("行った").occurrence)
        let correction = Definition(head: "行く", reading: "いく", chinese: "去", english: nil)
        _ = try await resolver.resolve(correctedSelection, settings: settings, savedWords: []) { correction }
        let learned = try await resolver.resolve(correctedSelection, settings: settings, savedWords: []) {
            throw CacheTestFailure(message: "Model-corrected dictionary identity was not remembered")
        }
        try require(learned.reused && learned.definition.head == "行く", "Remember a model correction to a dictionary guess")

        // Identical spelling with different readings must not share a word record.
        func ambiguous(_ reading: String) -> Lookup {
            let occurrence = selected("生").occurrence
            return Lookup(definition: Definition(head: "生", reading: reading, chinese: nil, english: nil), occurrence: occurrence)
        }
        for (reading, meaning) in [("せい", "生命"), ("なま", "生的") ] {
            _ = try await resolver.resolve(ambiguous(reading), settings: settings, savedWords: []) {
                Definition(head: "生", reading: reading, chinese: meaning, english: nil)
            }
        }
        let readingHit = try await resolver.resolve(ambiguous("なま"), settings: settings, savedWords: []) {
            throw CacheTestFailure(message: "Reading identity missed")
        }
        try require(readingHit.definition.chinese == "生的", "Keep readings distinct")

        let failurePath = directory.appendingPathComponent("failed.json")
        let failed = DefinitionResolver(path: failurePath, dictionary: dictionary)
        do {
            _ = try await failed.resolve(selected("読む"), settings: settings, savedWords: []) {
                throw URLError(.timedOut)
            }
            throw CacheTestFailure(message: "Network failure accepted")
        } catch let error as URLError { try require(error.code == .timedOut, "Network error preserved") }
        try require(!FileManager.default.fileExists(atPath: failurePath.path), "Failed requests do not poison cache")
        _ = try await failed.resolve(selected("読む"), settings: settings, savedWords: []) {
            Definition(head: "読む", reading: "よむ", chinese: "读", english: nil)
        }
        let corruptPath = directory.appendingPathComponent("corrupt.json")
        let corruptData = Data("not JSON".utf8)
        try corruptData.write(to: corruptPath)
        let corrupt = DefinitionResolver(path: corruptPath, dictionary: dictionary)
        let recovered = try await corrupt.resolve(selected("読む"), settings: settings, savedWords: []) {
            Definition(head: "読む", reading: "よむ", chinese: "读", english: nil)
        }
        try require(recovered.warning != nil, "Cache failure is visible without blocking definitions")
        let remaining = try Data(contentsOf: corruptPath)
        try require(remaining == corruptData, "Preserve an unreadable cache file")

        let past = SavedWord(definition: generated, examples: [selected("食べた").occurrence])
        var negativeExample = selected("食べない").occurrence
        negativeExample.definition = contextual
        let basic = SavedWord(definition: first.definition, examples: [negativeExample])
        let merged = dictionary.normalizedWords([past, basic])
        try require(merged.count == 1 && merged[0].definition.head == "食べる" && merged[0].examples.count == 2,
                    "Old inflected notebook entries merge into the same lemma")
        try require(merged[0].examples[0].context.word == "食べた" && merged[0].examples[1].context.word == "食べない",
                    "Preserve original forms and locations in examples")
        let bytes = try JSONEncoder().encode(merged[0])
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let examples = object["examples"] as! [[String: Any]]
        try require(examples[0]["definition"] == nil && examples[1]["definition"] != nil,
                    "Omit repeated word definitions but retain different contextual meanings")
        let decoded = try JSONDecoder().decode(SavedWord.self, from: bytes)
        let rows = NotebookExporter.rows(words: [decoded], fields: [.chinese, .surface])
        try require(rows[0][1] == first.definition.chinese && rows[1][1] == contextual.chinese,
                    "Compacted notebook definitions export with their original meanings")
        try require(dictionary.normalizedWords(merged) == merged, "Notebook migration is idempotent")
        var otherMeaning = merged[0].examples[0]
        otherMeaning.id = UUID()
        otherMeaning.definition = contextual
        let sameLocation = dictionary.normalizedWords([merged[0], SavedWord(definition: contextual, examples: [otherMeaning])])
        try require(sameLocation[0].examples.count == 3, "Migration keeps different saved meanings at the same source location")
        let requestsBeforeDisplay = requests
        let display = dictionary.notebookMeanings(for: decoded)
        try require(display.chinese == "吃；进食" && display.modelDefinitions == [first.definition, contextual],
                    "Notebook shows dictionary Chinese alongside all saved model meanings, including compacted examples")
        let offline = Definition(head: "食べる", reading: "たべる", chinese: " 收藏时的中文释义 ", english: "eat")
        var repeated = selected("食べない").occurrence
        repeated.definition = contextual
        let mixed = SavedWord(definition: offline, examples: [negativeExample, repeated])
        let mixedDisplay = dictionary.notebookMeanings(for: mixed)
        try require(mixedDisplay.chinese == "收藏时的中文释义" && mixedDisplay.modelDefinitions == [contextual],
                    "Keep saved Chinese and deduplicate model previews across examples")
        let offlineOnly = dictionary.notebookMeanings(for: SavedWord(definition: offline, examples: []))
        try require(offlineOnly.chinese != nil && offlineOnly.modelDefinitions.isEmpty,
                    "Dictionary-only words have no model section")
        let blank = Definition(head: "未知語", reading: "みちご", chinese: " \n ", english: "unknown", source: "test")
        let missing = dictionary.notebookMeanings(for: SavedWord(definition: blank, examples: []))
        try require(missing.chinese == nil && missing.modelDefinitions.isEmpty,
                    "Missing dictionary Chinese and whitespace-only model meanings produce no sections")
        let modelOnlyDefinition = Definition(head: "未知語", reading: "みちご", chinese: "仅有模型中文", english: nil, source: "test")
        let modelOnly = dictionary.notebookMeanings(for: SavedWord(definition: modelOnlyDefinition, examples: []))
        try require(modelOnly.chinese == nil && modelOnly.modelDefinitions == [modelOnlyDefinition],
                    "Model-only words do not repeat the AI text under dictionary Chinese")
        let dictionaryFallback = dictionary.notebookMeanings(for: SavedWord(
            definition: Definition(head: "読む", reading: "よむ", chinese: nil, english: "read"), examples: []))
        try require(dictionaryFallback.chinese == "阅读" && dictionaryFallback.modelDefinitions.isEmpty,
                    "Older saved words can display Chinese from bundled dictionary without rewriting saved data")
        let beforeDisplay = try Data(contentsOf: path)
        _ = dictionary.notebookMeanings(for: decoded)
        let afterDisplay = try Data(contentsOf: path)
        try require(requests == requestsBeforeDisplay && beforeDisplay == afterDisplay,
                    "Notebook display performs no model requests or cache writes")
        print("Passed lemma caching, notebook meanings, empty-field hiding, migration, persistence, and compact storage checks.")
    }
}
