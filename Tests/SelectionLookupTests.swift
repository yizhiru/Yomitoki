import Foundation
import SQLite3

private struct SelectionTestFailure: Error {}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        print(message)
        throw SelectionTestFailure()
    }
}

@main struct SelectionLookupTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("jmdict.sqlite").path, &db) == SQLITE_OK else {
            throw SelectionTestFailure()
        }
        let sql = """
        CREATE TABLE entries(form TEXT, head TEXT, reading TEXT, meaning TEXT, pos TEXT, rank INTEGER);
        INSERT INTO entries VALUES('喫茶店','喫茶店','きっさてん','coffee shop','n',1);
        INSERT INTO entries VALUES('食べる','食べる','たべる','to eat','v1 vt',1);
        INSERT INTO entries VALUES('微笑む','微笑む','ほほえむ','to smile','v5m vi',1);
        INSERT INTO entries VALUES('微笑','微笑','びしょう','smile','n vi vs',1);
        INSERT INTO entries VALUES('上手','上手','じょうず','skillful','adj-na adj-na',1);
        INSERT INTO entries VALUES('上手','上手','うわて','upper hand','n',1);
        INSERT INTO entries VALUES('無標識','無標識','むひょうしき','unmarked','   ',1);
        INSERT INTO entries VALUES('新規','新規','しんき','new','future-pos',1);
        """
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        try require(status == SQLITE_OK, "Create dictionary fixture")
        try "喫茶店\t咖啡馆\n食べる\t吃\n".write(to: directory.appendingPathComponent("zh.tsv"), atomically: true, encoding: .utf8)
        let dictionary = Lexicon(resources: directory)
        let book = Book(name: "selection.txt", kind: "TXT", pages: ["☕️  喫茶店  でパンを食べた。雨の喫茶店に入った。", "次のページ。"])
        let text = book.pages[0] as NSString

        let selection = text.range(of: "喫茶店")
        let lookup = dictionary.lookup(book: book, page: 0, selection: selection)
        try require(lookup?.definition.head == "喫茶店" && lookup?.definition.chinese == "咖啡馆", "Selected word gets dictionary definition")
        try require(lookup?.range == selection && lookup?.occurrence.context.word == "喫茶店", "Selection and occurrence retain UTF-16 offsets")

        let padded = dictionary.lookup(book: book, page: 0, selection: text.range(of: "  喫茶店  "))
        try require(padded?.range == selection, "Trim selected whitespace without shifting word location")
        let inflection = dictionary.lookup(book: book, page: 0, selection: text.range(of: "食べた"))
        try require(inflection?.definition.head == "食べる" && inflection?.occurrence.context.word == "食べた", "Selected inflected verb uses existing deinflection rules")
        let smileBook = Book(name: "smile.txt", kind: "TXT", pages: ["店主は穏やかに微笑んだ。"])
        let smileRange = (smileBook.pages[0] as NSString).range(of: "微笑んだ")
        let smile = dictionary.lookup(book: smileBook, page: 0, selection: smileRange)
        try require(smile?.definition.head == "微笑む" && smile?.definition.reading == "ほほえむ"
                    && smile?.definition.english?.contains("to smile") == true,
                    "Godan nasal past resolves to the verb lemma, not the noun 微笑")
        try require(smile?.range == smileRange && smile?.occurrence.context.word == "微笑んだ",
                    "Lemma lookup must preserve the original past form and exact copy/selection range")
        let smileTokens = Lexicon.tokens(smileBook.pages[0])
        let clickedSmile = dictionary.lookup(book: smileBook, page: 0, at: smileRange.location, tokens: smileTokens)
        try require(clickedSmile?.definition.head == "微笑む" && clickedSmile?.occurrence.context.word == "微笑んだ",
                    "Automatic token lookup handles the split 微笑ん + だ too")

        let phrase = "雨の喫茶店"
        let phraseRange = text.range(of: phrase)
        let phraseLookup = dictionary.lookup(book: book, page: 0, selection: phraseRange)
        try require(phraseLookup?.definition.head == phrase && phraseLookup?.range == phraseRange, "Selected phrase is not reduced to its first token")
        try require(phraseLookup?.occurrence.context.sentence == "雨の喫茶店に入った。", "Model input keeps selected phrase and original sentence")

        for range in [NSRange(location: 0, length: 0), text.range(of: "  "), text.range(of: "。"),
                      NSRange(location: NSNotFound, length: 1), NSRange(location: text.length, length: 1),
                      NSRange(location: 0, length: Int.max)] {
            try require(dictionary.lookup(book: book, page: 0, selection: range) == nil, "Empty, punctuation-only, or invalid selections are ignored")
        }
        try require(dictionary.lookup(book: book, page: 2, selection: selection) == nil, "Invalid page is ignored")
        let tapped = dictionary.lookup(book: book, page: 0, at: selection.location, tokens: [selection])
        try require(tapped?.definition.head == "喫茶店", "Single-click lookup still works")
        let nounTags = dictionary.partsOfSpeech(for: lookup!.definition)
        try require(nounTags.map(\.code) == ["n"] && nounTags.map(\.label) == ["名词"],
                    "Read and translate the stored noun tag")
        let verbTags = dictionary.partsOfSpeech(for: inflection!.definition)
        try require(verbTags.map(\.code) == ["v1", "vt"] && verbTags.map(\.label) == ["一段动词", "他动词"],
                    "Inflected selections show the lemma's conjugation and transitivity")
        let model = Definition(head: "食べた", reading: "たべた", chinese: "吃了", english: nil, source: "test")
        try require(dictionary.partsOfSpeech(for: model) == verbTags && model.chinese == "吃了" && model.source == "test",
                    "Model definitions use local POS without changing their contextual meaning or source")
        let adjective = Definition(head: "上手", reading: "じょうず", chinese: nil, english: nil)
        let upperHand = Definition(head: "上手", reading: "うわて", chinese: nil, english: nil)
        try require(dictionary.partsOfSpeech(for: adjective).map(\.label) == ["な形容词（形容动词）"] &&
                    dictionary.partsOfSpeech(for: upperHand).map(\.code) == ["n"],
                    "Deduplicate POS and keep homographs with different readings separate")
        for value in [Definition(head: "上手", reading: "", chinese: nil, english: nil),
                      Definition(head: "上手", reading: "not-a-reading", chinese: nil, english: nil),
                      Definition(head: "無標識", reading: "むひょうしき", chinese: nil, english: nil),
                      Definition(head: "未収録語", reading: "みしゅうろくご", chinese: nil, english: nil)] {
            try require(dictionary.partsOfSpeech(for: value).isEmpty, "Ambiguous, mismatched or absent POS is hidden")
        }
        let legacy = try JSONDecoder().decode(Definition.self, from: Data(
            #"{"head":"喫茶店","reading":"","chinese":"咖啡馆","english":null}"#.utf8))
        try require(dictionary.partsOfSpeech(for: legacy) == nounTags, "Old saved words without a reading can use unambiguous local POS")
        let future = Definition(head: "新規", reading: "しんき", chinese: nil, english: nil)
        try require(dictionary.partsOfSpeech(for: future).map(\.label) == ["future-pos"], "Keep unknown dictionary codes visible")
        try require(DictionaryPartOfSpeech(code: "v5m").label == "五段动词（ま行）" &&
                    DictionaryPartOfSpeech(code: "v2k-k").label == "上二段动词（古语・か行）" &&
                    DictionaryPartOfSpeech(code: "v4h").label == "四段动词（古语・は行）",
                    "Translate modern and archaic conjugation classes")
        print("Passed selection, POS labels, lemma/reading matching, missing tags, legacy words, and Unicode checks.")
    }
}
