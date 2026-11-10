import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor final class ReaderState: ObservableObject {
    @Published private(set) var library: LibraryData
    @Published var lookup: Lookup?
    @Published var textSelection: NSRange?
    @Published private(set) var querying = false
    @Published private(set) var lookupFailure: String?
    @Published private(set) var reusedDefinition = false
    @Published private(set) var cacheWarning: String?
    @Published var inNotebook = false {
        didSet {
            if inNotebook { cancelImport(); translation.clear(); sentenceAnalysis.clear(); modelChat.dismiss() }
            if inNotebook { textSelection = nil }
            if inNotebook && querying {
                cancelLookup()
                lookup = nil
            }
        }
    }
    @Published var selectedWord: String?
    @Published private(set) var importing = false
    private var importTask: Task<Void, Never>?
    @Published var search = ""
    @Published var fontSize: CGFloat = 26
    @Published var failure: String?
    @Published private(set) var revision = UUID()
    let dictionary: Lexicon
    let preferences: DefinitionPreferences
    let translation: LocalTranslation
    let sentenceAnalysis: SentenceAnalysisState
    let modelChat: ModelChatState
    let path: URL
    private let definitionResolver: DefinitionResolver
    private let fetchModel: (SentenceContext, DefinitionSettings) async throws -> Definition
    private var canSave = true
    private var lookupTask: Task<Void, Never>?
    private var lookupRequest = UUID()
    private(set) var tokens: [NSRange] = []

    init(directory customDirectory: URL? = nil, resources: URL? = nil,
         fetchAnalysis: ((String, DefinitionSettings) async throws -> SentenceAnalysis)? = nil,
         fetchModel: @escaping (SentenceContext, DefinitionSettings) async throws -> Definition = { context, settings in
             let key = try APIKeyStore.read(settings.provider)
             return try await ModelLexicon().definition(context: context, settings: settings, apiKey: key)
         }) {
        self.fetchModel = fetchModel
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Keep the previous data directory and environment override compatible after renaming.
        let environment = ProcessInfo.processInfo.environment
        let directory = customDirectory ?? (environment["YOMITOKI_DATA_DIRECTORY"]
            ?? environment["KOTOBAHIROI_DATA_DIRECTORY"] ?? environment["BUNMYAKU_DATA_DIRECTORY"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? appSupport.appendingPathComponent("Bunmyaku")
        path = directory.appendingPathComponent("library.json")
        translation = LocalTranslation(directory: directory)
        modelChat = ModelChatState(directory: directory)
        sentenceAnalysis = fetchAnalysis.map { SentenceAnalysisState(directory: directory, fetch: $0) }
            ?? SentenceAnalysisState(directory: directory)
        preferences = DefinitionPreferences(path: directory.appendingPathComponent("settings.json"))
        if let data = try? Data(contentsOf: path) {
            do {
                let decoded = try JSONDecoder().decode(LibraryData.self, from: data)
                guard !decoded.books.isEmpty, decoded.books.allSatisfy({ $0.pages.indices.contains($0.page) }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                library = decoded
            } catch {
                canSave = false
                library = .initial
                failure = "本地书架数据无法读取。现有数据保留在 \(path.path)。"
            }
        } else {
            library = .initial
        }
        dictionary = Lexicon(resources: resources ?? Bundle.main.resourceURL!)
        definitionResolver = DefinitionResolver(path: directory.appendingPathComponent("definitions.json"), dictionary: dictionary)
        let normalized = dictionary.normalizedWords(library.words)
        if normalized != library.words {
            do {
                let backups = directory.appendingPathComponent("backups", isDirectory: true)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: path,
                    to: backups.appendingPathComponent("library-before-lemma-\(UUID().uuidString).json"))
                var candidate = library
                candidate.words = normalized
                _ = persist(candidate)
            } catch {
                failure = "旧生词本备份失败，暂未合并词形。\(error.localizedDescription)"
            }
        }
        refreshTokens()
    }

    var book: Book { library.books.first { $0.id == library.current } ?? library.books[0] }
    var selectedSavedWord: SavedWord? { library.words.first { $0.id == selectedWord } }
    func refreshTokens() {
        textSelection = nil
        tokens = Lexicon.tokens(book.pages[book.page])
        revision = UUID()
    }
    @discardableResult private func persist(_ candidate: LibraryData) -> Bool {
        guard canSave else {
            failure = "原书架无法读取，当前无法保存。数据文件位于 \(path.path)。"
            return false
        }
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(candidate).write(to: path, options: .atomic)
            library = candidate
            return true
        } catch {
            failure = "保存失败。\(error.localizedDescription)"
            return false
        }
    }
    func openBook(_ id: UUID, page: Int? = nil) {
        cancelImport()
        guard let index = library.books.firstIndex(where: { $0.id == id }) else { return }
        var candidate = library
        candidate.current = id
        if let page { candidate.books[index].page = page }
        if candidate.current != library.current || candidate.books[index].page != library.books[index].page {
            guard persist(candidate) else { return }
            refreshTokens()
        }
        cancelLookup()
        modelChat.dismiss()
        translation.clear()
        sentenceAnalysis.clear()
        textSelection = nil
        lookup = nil
        inNotebook = false
    }
    func showPage(_ page: Int) {
        guard book.pages.indices.contains(page) else { return }
        openBook(book.id, page: page)
    }
    @discardableResult func choose(_ offset: Int) -> NSRange? {
        let selected = dictionary.lookup(book: book, page: book.page, at: offset, tokens: tokens)
        showDictionary(selected)
        return selected?.range
    }
    func defineSelection() {
        guard let selection = textSelection, selectionLevel(selection) == .word else { return }
        showDictionary(dictionary.lookup(book: book, page: book.page, selection: selection))
    }
    func defineModelSelection(_ range: NSRange) {
        guard selectionLevel(range) == .word else { return }
        textSelection = range
        requestModelLookup(dictionary.lookup(book: book, page: book.page, selection: range))
    }
    func translateSelection(_ range: NSRange) {
        guard canTranslate(range) else { return }
        guard let text = TranslationModel.selectedText(range, in: book.pages[book.page]) else { return }
        textSelection = range
        cancelLookup()
        modelChat.dismiss()
        sentenceAnalysis.clear()
        translation.translate(text)
    }
    func analyzeSelection(_ range: NSRange) {
        guard selectionLevel(range) == .sentence, let text = TranslationModel.selectedText(range, in: book.pages[book.page]) else { return }
        textSelection = range
        cancelLookup()
        modelChat.dismiss()
        translation.clear()
        sentenceAnalysis.analyze(text, settings: preferences.settings)
    }
    func chatSelection(_ range: NSRange) {
        guard selectionLevel(range) != nil, let selected = Range(range, in: book.pages[book.page]) else { return }
        let text = String(book.pages[book.page][selected])
        guard text.count <= ModelChatAPI.maximumSelection else {
            failure = "对话选文一次最多 8000 个字符，请缩短选文。"
            return
        }
        let context = Lexicon.context(book: book, page: book.page, range: range)
        do {
            try modelChat.open(ModelChatContext(bookID: book.id, filename: book.name, kind: book.kind, page: book.page,
                offset: range.location, selectedText: text, before: String(context.before.suffix(1600)), after: String(context.after.prefix(1600))))
            textSelection = range
            cancelLookup()
            translation.clear()
            sentenceAnalysis.clear()
        } catch { failure = error.localizedDescription }
    }
    func openChat() {
        if let range = textSelection { chatSelection(range) }
        else if !modelChat.conversations.isEmpty {
            cancelLookup()
            translation.clear()
            sentenceAnalysis.clear()
            modelChat.resume()
        }
    }
    var canTranslateSelection: Bool {
        textSelection.map(canTranslate) ?? false
    }
    var selectedContentLevel: TranslationSelection.Level? {
        textSelection.flatMap(selectionLevel)
    }
    var canAnalyzeSelection: Bool { selectedContentLevel == .sentence }
    func selectionLevel(_ range: NSRange) -> TranslationSelection.Level? {
        TranslationSelection.level(of: range, in: book.pages[book.page])
    }
    func canTranslate(_ range: NSRange) -> Bool {
        selectionLevel(range)?.actions.contains(.translation) == true
    }
    private func showDictionary(_ selected: Lookup?) {
        modelChat.dismiss()
        sentenceAnalysis.clear()
        translation.clear()
        cancelLookup()
        lookup = selected
    }
    func retryLookup() {
        requestModelLookup(lookup)
    }
    func regenerateLookup() {
        requestModelLookup(lookup, refresh: true)
    }
    private func requestModelLookup(_ selected: Lookup?, refresh: Bool = false) {
        modelChat.dismiss()
        sentenceAnalysis.clear()
        translation.clear()
        cancelLookup()
        guard let selected else {
            lookup = nil
            return
        }
        var settings = preferences.settings
        settings.source = .model
        // Keep the offline definition visible while a user-requested model lookup runs.
        lookup = selected
        querying = true
        let request = lookupRequest
        lookupTask = Task {
            do {
                let resolution = try await definitionResolver.resolve(selected, settings: settings,
                    savedWords: library.words, refresh: refresh) {
                    try await fetchModel(selected.occurrence.context, settings)
                }
                guard !Task.isCancelled, request == lookupRequest else { return }
                var occurrence = selected.occurrence
                let definition = dictionary.addingDictionaryEnglish(to: resolution.definition)
                occurrence.definition = definition
                lookup = Lookup(definition: definition, occurrence: occurrence)
                reusedDefinition = resolution.reused
                cacheWarning = resolution.warning
            } catch {
                guard !Task.isCancelled, request == lookupRequest else { return }
                lookupFailure = error.localizedDescription
            }
            querying = false
            lookupTask = nil
        }
    }
    private func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        lookupRequest = UUID()
        querying = false
        lookupFailure = nil
        reusedDefinition = false
        cacheWarning = nil
    }
    func saveSettings(_ settings: DefinitionSettings, apiKey: String) throws {
        try preferences.save(settings, apiKey: apiKey)
        sentenceAnalysis.clear()
        let selection = lookup?.range
        cancelLookup()
        if !inNotebook, let selection {
            showDictionary(dictionary.lookup(book: book, page: book.page, selection: selection))
        }
    }
    func show(_ word: SavedWord, at example: Occurrence) {
        openBook(example.bookID, page: example.page)
        guard book.id == example.bookID, book.page == example.page else { return }
        lookup = Lookup(definition: example.definition ?? word.definition, occurrence: example)
    }
    func contains(_ lookup: Lookup) -> Bool {
        guard let word = library.words.first(where: { $0.id == lookup.key }) else { return false }
        return word.examples.contains { $0.samePlace(as: lookup.occurrence) && ($0.definition ?? word.definition) == lookup.definition }
    }
    func hasSavedExample(_ lookup: Lookup) -> Bool {
        library.words.first(where: { $0.id == lookup.key })?.examples.contains(where: { $0.samePlace(as: lookup.occurrence) }) ?? false
    }
    func save(_ lookup: Lookup) {
        guard !querying, lookupFailure == nil, !contains(lookup) else { return }
        var candidate = library
        if let index = candidate.words.firstIndex(where: { $0.id == lookup.key }) {
            if let example = candidate.words[index].examples.firstIndex(where: { $0.samePlace(as: lookup.occurrence) }) {
                var occurrence = lookup.occurrence
                occurrence.id = candidate.words[index].examples[example].id
                candidate.words[index].examples[example] = occurrence
            } else {
                candidate.words[index].examples.append(lookup.occurrence)
            }
        } else {
            candidate.words.insert(SavedWord(definition: lookup.definition, examples: [lookup.occurrence]), at: 0)
        }
        candidate.words = dictionary.normalizedWords(candidate.words)
        if persist(candidate) { selectedWord = lookup.key }
    }
    func remove(_ word: SavedWord) {
        var candidate = library
        guard candidate.words.contains(where: { $0.id == word.id }) else { return }
        candidate.words.removeAll { $0.id == word.id }
        if persist(candidate), selectedSavedWord == nil { selectedWord = library.words.first?.id }
    }
    func remove(_ occurrence: Occurrence, from word: SavedWord) {
        var candidate = library
        guard let index = candidate.words.firstIndex(where: { $0.id == word.id }) else { return }
        candidate.words[index].examples.removeAll { $0.id == occurrence.id }
        if candidate.words[index].examples.isEmpty { candidate.words.remove(at: index) }
        if persist(candidate), selectedSavedWord == nil { selectedWord = library.words.first?.id }
    }
    func importBook() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "导入阅读文件"
        panel.prompt = "导入"
        panel.allowedContentTypes = ["pdf", "epub", "mobi"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importBook(url)
    }
    func cancelImport() { importTask?.cancel() }
    func importBook(_ url: URL, ebookResources: URL? = nil) {
        guard !importing else { return }
        importing = true
        importTask = Task {
            defer { importing = false; importTask = nil }
            do {
                let new = try await BookImport.read(url, ebookResources: ebookResources)
                try Task.checkCancellation()
                var candidate = library
                let existing = candidate.books.first { $0.name == new.name && $0.pages == new.pages }
                if existing == nil { candidate.books.append(new) }
                candidate.current = existing?.id ?? new.id
                if persist(candidate) {
                    modelChat.dismiss()
                    sentenceAnalysis.clear()
                    translation.clear()
                    cancelLookup()
                    lookup = nil
                    inNotebook = false
                    refreshTokens()
                }
            } catch is CancellationError {
                // Cancellation preserves the current book and all saved data.
            } catch { failure = error.localizedDescription }
        }
    }
}
