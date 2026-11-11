import Foundation
import SQLite3

private struct ReaderTestFailure: Error { let message: String }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ReaderTestFailure(message: message) }
}

@main struct ReaderStateTests {
    @MainActor static func waitForAnalysis(_ state: ReaderState) async throws {
        for _ in 0..<200 {
            if !state.sentenceAnalysis.analyzing { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ReaderTestFailure(message: "Analysis did not finish")
    }
    @MainActor static func waitForLookup(_ state: ReaderState) async throws {
        for _ in 0..<200 {
            if !state.querying { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ReaderTestFailure(message: "Lookup did not finish")
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("jmdict.sqlite").path, &db) == SQLITE_OK else {
            throw ReaderTestFailure(message: "Fixture database")
        }
        let sql = """
        CREATE TABLE entries(form TEXT, head TEXT, reading TEXT, meaning TEXT, pos TEXT, rank INTEGER);
        INSERT INTO entries VALUES('喫茶店','喫茶店','きっさてん','coffee shop','n',1);
        INSERT INTO entries VALUES('雨','雨','あめ','rain','n',1);
        """
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        try require(status == SQLITE_OK, "Create fixture")
        try "喫茶店\t咖啡馆\n雨\t雨\n".write(to: root.appendingPathComponent("zh.tsv"), atomically: true, encoding: .utf8)
        var settings = DefinitionSettings()
        settings.source = .model // An old global setting must no longer trigger automatic model requests.
        settings.provider = .custom
        settings.customURL = "https://example.com/v1"
        settings.customModel = "test-model"
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
        var requests = 0
        var analysisRequests = 0
        let sentence = "雨が上がったので、傘を閉じて小さな喫茶店に入った。"
        let analysis = SentenceAnalysis(translation: "雨停了，我收起伞走进咖啡馆。", mainStructure: "（私は）喫茶店に入った。",
            modifiers: ["雨が上がったので → 入った：原因"], grammarPoints: ["ので表示原因"],
            diagram: "［雨が上がったので］ ➔ 喫茶店に入った。\n        └── 原因状语 ──┘", notes: "主语省略")
        let state = ReaderState(directory: root, resources: root, fetchAnalysis: { text, config in
            analysisRequests += 1
            try require(text == sentence && config.customModel == "test-model", "Analysis uses exact sentence and existing API model")
            return analysis
        }) { context, _ in
            requests += 1
            try require(context.word == "喫茶店", "Explicit lookup retains exact selected text")
            return Definition(head: "喫茶店", reading: "きっさてん", chinese: "本句指避雨的小咖啡馆。", english: nil, source: "test")
        }
        let legacyLibrary = """
        {"books":[],"words":[],"current":"\(state.book.id)"}
        """
        let decodedLibrary = try JSONDecoder().decode(LibraryData.self, from: Data(legacyLibrary.utf8))
        try require(decodedLibrary.notes.isEmpty, "Existing libraries load without a notes field")
        let empty = ReadingNote(bookID: state.book.id, page: 1, excerpt: nil, body: "")
        try require(!state.saveNote(empty), "Reject a note without content")
        var note = ReadingNote(bookID: state.book.id, page: 1, excerpt: "珈琲", body: "")
        try require(state.saveNote(note), "Save an excerpt without a note body")
        note.body = "复习这段的时态"
        try require(state.saveNote(note), "Edit the saved note")
        let restoredNotes = ReaderState(directory: root, resources: root)
        try require(restoredNotes.library.notes.count == 1 && restoredNotes.library.notes.first?.body == note.body
                    && restoredNotes.library.notes.first?.excerpt == "珈琲", "Note and excerpt survive reload")
        state.destination = .notes
        state.openBook(note.bookID, page: note.page)
        try require(state.destination == .reading && state.book.page == 1, "Return from notes to the source page")
        state.deleteNote(note.id)
        try require(state.library.notes.isEmpty, "Delete the note")
        state.showPage(0)
        let range = (state.book.pages[0] as NSString).range(of: "喫茶店")
        state.choose(range.location)
        try require(!state.querying && requests == 0 && state.lookup?.definition.source == nil,
                    "Single clicks always use offline dictionary, even with old model source setting")
        try require(state.lookup?.definition.english?.contains("coffee shop") == true, "Offline English remains available")
        state.textSelection = range
        state.defineSelection()
        try require(!state.querying && requests == 0, "Selected-text dictionary action never requests the model")
        state.save(state.lookup!)

        state.defineModelSelection(range)
        try await waitForLookup(state)
        try require(requests == 1 && state.lookup?.definition.source == "test",
                    "Explicit model action requests the model even if an offline word was already saved")
        try require(state.lookup?.definition.english?.contains("coffee shop") == true
                    && state.lookup?.definition.chinese == "本句指避雨的小咖啡馆。", "Model result retains offline English and contextual Chinese")
        state.defineModelSelection(range)
        try await waitForLookup(state)
        try require(requests == 1 && state.reusedDefinition, "Explicit model action still reuses the persistent cache")

        state.choose(range.location)
        try require(requests == 1 && !state.reusedDefinition && state.lookup?.definition.source == nil,
                    "Ordinary click returns to offline dictionary after model use")
        settings.source = .dictionary
        try state.saveSettings(settings, apiKey: "")
        try require(requests == 1 && !state.querying, "Saving settings cannot start a model lookup")
        state.defineModelSelection(range)
        try await waitForLookup(state)
        try require(state.reusedDefinition && state.lookup?.definition.source == "test",
                    "Explicit model feature also works when legacy source is offline")
        state.regenerateLookup()
        try await waitForLookup(state)
        try require(requests == 2 && !state.reusedDefinition, "Regeneration explicitly bypasses cache")

        let pending = ReaderState(directory: root, resources: root, fetchModel: { _, _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return Definition(head: "喫茶店", reading: "きっさてん", chinese: "Late answer", english: nil)
        })
        pending.defineModelSelection(range)
        pending.regenerateLookup()
        await Task.yield()
        pending.choose(0)
        try await Task.sleep(nanoseconds: 130_000_000)
        try require(!pending.querying && pending.lookup?.definition.head == "雨" && pending.lookup?.definition.source == nil,
                    "Selecting another word cancels the model lookup and cannot be overwritten by a late answer")
        state.translateSelection(range)
        try require(!state.canTranslateSelection && state.translation.source == nil && !state.translation.translating,
                    "A word cannot invoke translation even by calling the entry point directly")
        let sentenceRange = (state.book.pages[0] as NSString).range(of: sentence)
        state.textSelection = sentenceRange
        try require(state.canTranslateSelection, "Complete selected sentence enables translation")
        state.translateSelection(sentenceRange)
        try require(state.translation.source == sentence && requests == 2, "Sentence translation is independent of remote definitions")
        state.showPage(1)
        try require(state.translation.source == nil && !state.translation.translating, "Changing pages dismisses and cancels translation")
        state.showPage(0)
        state.translateSelection(sentenceRange)
        state.inNotebook = true
        try require(state.translation.source == nil && !state.translation.translating, "Entering notebook cancels translation")
        state.inNotebook = false
        state.analyzeSelection(range)
        try require(state.sentenceAnalysis.source == nil && analysisRequests == 0, "A selected word cannot invoke sentence analysis")
        state.analyzeSelection(sentenceRange)
        try await waitForAnalysis(state)
        try require(state.sentenceAnalysis.result == analysis && analysisRequests == 1 && state.translation.source == nil,
                    "Explicit sentence analysis uses configured API independently from translation")
        state.choose(range.location)
        try require(state.sentenceAnalysis.source == nil, "Dictionary action dismisses analysis")
        state.analyzeSelection(sentenceRange)
        try await waitForAnalysis(state)
        try require(state.sentenceAnalysis.reused && analysisRequests == 1, "Reader reuses cached sentence analysis")
        let analysisArchive = SentenceAnalysisState(directory: root)
        try require(analysisArchive.history.count == 1, "A cached analysis does not duplicate the archive entry")
        if let entry = analysisArchive.history.first {
            try require(entry.bookID == state.book.id && entry.page == 0 && entry.offset == sentenceRange.location,
                        "The archive restores the book and location")
            analysisArchive.show(entry)
            try require(analysisArchive.result == analysis && !analysisArchive.canRetry, "Opening an archive entry restores the result")
            analysisArchive.delete(entry.id)
            try require(SentenceAnalysisState(directory: root).history.isEmpty, "Archive deletion persists")
        }
        state.showPage(1)
        try require(state.sentenceAnalysis.source == nil && !state.sentenceAnalysis.analyzing, "Page change dismisses analysis")
        state.showPage(0)
        let paragraph = state.book.pages[0].components(separatedBy: "\n\n")[0]
        let paragraphRange = (state.book.pages[0] as NSString).range(of: paragraph)
        state.textSelection = paragraphRange
        try require(state.selectedContentLevel == .paragraph && state.canTranslateSelection && !state.canAnalyzeSelection,
                    "Paragraphs allow translation only")
        state.analyzeSelection(paragraphRange)
        state.defineSelection()
        state.defineModelSelection(paragraphRange)
        try require(state.sentenceAnalysis.source == nil && state.lookup == nil && requests == 2 && analysisRequests == 1,
                    "Paragraphs cannot invoke sentence analysis or dictionary/model definitions directly")
        state.textSelection = sentenceRange
        state.defineSelection()
        state.defineModelSelection(sentenceRange)
        try require(state.lookup == nil && requests == 2, "Sentences cannot invoke word definitions directly")
        let requestsBeforeChat = requests
        for selected in ["喫茶店", "傘を閉じて小さな", sentence, paragraph] {
            let selectedRange = (state.book.pages[0] as NSString).range(of: selected)
            state.chatSelection(selectedRange)
            try require(state.modelChat.isPresented && state.modelChat.current?.context.selectedText == selected
                        && state.modelChat.current?.context.bookID == state.book.id && state.textSelection == selectedRange,
                        "Word, partial sentence, sentence and paragraph selections open exact chat context")
            try require(!state.modelChat.sending && state.modelChat.current?.messages.isEmpty == true && requests == requestsBeforeChat,
                        "Opening selected-text chat never performs model definitions or automatic chat requests")
        }
        let conversationCount = state.modelChat.conversations.count
        let currentChatID = state.modelChat.activeID
        state.chatSelection(NSRange(location: NSNotFound, length: 1))
        try require(state.modelChat.activeID == currentChatID && state.modelChat.conversations.count == conversationCount,
                    "Invalid chat selections preserve the existing conversation")
        state.showPage(1)
        try require(!state.modelChat.isPresented && state.modelChat.conversations.count == conversationCount,
                    "Changing pages hides chat while preserving its pinned source and history")
        state.openChat()
        try require(state.modelChat.isPresented && state.modelChat.activeID == currentChatID,
                    "Reader toolbar can resume the previous chat without a selection")
        state.inNotebook = true
        try require(!state.modelChat.isPresented, "Entering notebook dismisses chat")
        state.inNotebook = false
        state.showPage(0)
        state.chatSelection(range)
        state.choose(range.location)
        try require(!state.modelChat.isPresented && state.modelChat.conversations.count == conversationCount,
                    "Dictionary actions restore the definition panel and preserve chat records")
        let deletionDirectory = root.appendingPathComponent("word-deletion")
        try FileManager.default.createDirectory(at: deletionDirectory, withIntermediateDirectories: true)
        let saved = state.library.words[0]
        let example = saved.examples[0]
        let secondExample = Occurrence(bookID: example.bookID, filename: example.filename, kind: example.kind,
            page: example.page, offset: example.offset + 1, context: example.context)
        let target = SavedWord(definition: saved.definition, examples: [example, secondExample])
        let remaining = SavedWord(definition: Definition(head: "雨", reading: "あめ", chinese: "雨", english: "rain"), examples: [example])
        var deletionFixture = state.library
        deletionFixture.words = [target, remaining]
        let deletionPath = deletionDirectory.appendingPathComponent("library.json")
        try JSONEncoder().encode(deletionFixture).write(to: deletionPath)
        let deleting = ReaderState(directory: deletionDirectory, resources: root)
        deleting.selectedWord = target.id
        deleting.remove(target)
        try require(deleting.library.words == [remaining] && deleting.selectedWord == remaining.id,
                    "Deleting a word removes all its examples and selects a remaining word")
        try require(ReaderState(directory: deletionDirectory, resources: root).library.words == [remaining],
                    "Word deletion persists across restart")
        // A failed write must preserve the current word and selection.
        try FileManager.default.removeItem(at: deletionPath)
        try FileManager.default.createDirectory(at: deletionPath, withIntermediateDirectories: true)
        deleting.remove(remaining)
        try require(deleting.library.words == [remaining] && deleting.selectedWord == remaining.id && deleting.failure != nil,
                    "Failed deletion preserves the word and current selection")
        try FileManager.default.removeItem(at: deletionPath)
        deleting.remove(remaining)
        try require(deleting.library.words.isEmpty && deleting.selectedWord == nil, "Deleting the final word clears selection")
        let progressDirectory = root.appendingPathComponent("reading-progress")
        try FileManager.default.createDirectory(at: progressDirectory, withIntermediateDirectories: true)
        let firstBook = Book(name: "第一冊", kind: "EPUB", pages: ["最初の節", "次の節の読みかけの文章"])
        let secondBook = Book(name: "第二冊", kind: "PDF", pages: ["長いページの読みかけの文章"])
        let progressLibrary = LibraryData(books: [firstBook, secondBook], words: [], current: firstBook.id)
        try JSONEncoder().encode(progressLibrary).write(to: progressDirectory.appendingPathComponent("library.json"))
        let reading = ReaderState(directory: progressDirectory, resources: root)
        try require(reading.readingOffset == 0, "Books without an offset start at the beginning of their saved section")
        reading.turnReadingPage(section: 1, offset: 4)
        reading.openBook(secondBook.id)
        let previousRevision = reading.revision
        reading.recordReadingProgress(6, revision: previousRevision)
        reading.openBook(firstBook.id)
        try require(reading.book.page == 1 && reading.readingOffset == 4, "Switching books restores the EPUB section and text offset")
        reading.recordReadingProgress(2, revision: previousRevision)
        reading.openBook(secondBook.id)
        try require(reading.readingOffset == 6, "Switching books flushes the pending scroll position")
        let restoredReading = ReaderState(directory: progressDirectory, resources: root)
        try require(restoredReading.book.id == secondBook.id && restoredReading.readingOffset == 6,
                    "Restart restores the last book and scroll position")
        restoredReading.openBook(firstBook.id)
        try require(restoredReading.book.page == 1 && restoredReading.readingOffset == 4,
                    "Other books retain their own positions after restart")
        print("Passed reader actions, cache, cancellation, word deletion persistence, and failed-write preservation checks.")
    }
}
