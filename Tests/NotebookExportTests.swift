import Foundation

private struct ExportTestFailure: Error {
    let message: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ExportTestFailure(message: message) }
}

@main struct NotebookExportTests {
    static func text(_ words: [SavedWord], fields: Set<NotebookExportField>, format: NotebookExportFormat) -> String {
        String(decoding: NotebookExporter.data(words: words, fields: fields, format: format), as: UTF8.self)
    }

    static func main() throws {
        let definition = Definition(head: "喫茶店", reading: "きっさてん", chinese: "咖啡馆；茶饮店", english: "coffee shop")
        let contextual = Definition(head: "喫茶店", reading: "きっさてん", chinese: "本句中的咖啡馆\n名词。", english: nil,
                                    source: "DeepSeek · deepseek-flash")
        let first = Occurrence(bookID: UUID(), filename: "小説,\"上巻\".pdf", kind: "PDF", page: 2, offset: 4,
                               context: SentenceContext(before: "雨后、", word: "喫茶店", after: "に入った。\n一休みした。"))
        var second = Occurrence(bookID: UUID(), filename: "物語.epub", kind: "EPUB", page: 0, offset: 0,
                                context: SentenceContext(before: "", word: "喫茶店", after: "で読書する。"))
        second.definition = contextual
        let third = Occurrence(bookID: second.bookID, filename: second.filename, kind: second.kind, page: 1,
                               offset: second.offset, context: second.context, definition: contextual)
        let word = SavedWord(definition: definition, examples: [first, second, third])

        let minimal = text([word], fields: [], format: .csv)
        try require(minimal == "\u{FEFF}\"单词\"\r\n\"喫茶店\"\r\n", "Words-only CSV deduplicates examples")
        try require(text([word], fields: [], format: .text) == "喫茶店\n", "Words-only TXT is a reusable word list")

        let escaped = text([SavedWord(definition: definition, examples: [first])], fields: [.sentence, .filename, .location], format: .csv)
        try require(escaped == "\u{FEFF}\"单词\",\"原句\",\"文件名\",\"页码或节位置\"\r\n" +
                    "\"喫茶店\",\"雨后、喫茶店に入った。\n一休みした。\",\"小説,\"\"上巻\"\".pdf\",\"第 3 页\"\r\n",
                    "CSV preserves commas, quotes, embedded newlines, Unicode, and one-based locations")

        let meanings = NotebookExporter.rows(words: [word], fields: [.reading, .chinese, .english, .source])
        try require(meanings.count == 2, "Identical definitions from multiple examples merge")
        try require(meanings[0] == ["喫茶店", "きっさてん", "咖啡馆；茶饮店", "coffee shop", "离线词典"],
                    "Legacy example uses stored word definition")
        try require(meanings[1] == ["喫茶店", "きっさてん", "本句中的咖啡馆\n名词。", "", "DeepSeek · deepseek-flash"],
                    "Contextual definition stays paired with its source")

        let examples = NotebookExporter.rows(words: [word], fields: [.chinese, .sentence, .location])
        try require(examples.count == 3, "Every example survives an export with occurrence fields")
        try require(examples[1][1] == contextual.chinese && examples[1][2] == second.context.sentence,
                    "Model meaning stays paired with its sentence")
        try require(examples[2].last == "第 2 节", "EPUB section is one-based")

        let optionalFields: [(NotebookExportField, String)] = [
            (.reading, "きっさてん"), (.chinese, "本句中的咖啡馆"), (.source, "DeepSeek · deepseek-flash"),
            (.sentence, "で読書する。"), (.filename, "物語.epub"), (.location, "第 1 节")
        ]
        let single = [SavedWord(definition: contextual, examples: [second])]
        for (field, marker) in optionalFields {
            for format in NotebookExportFormat.allCases {
                let included = text(single, fields: [field], format: format)
                let excluded = text(single, fields: [], format: format)
                try require(included.contains(marker) && !excluded.contains(marker), "Unchecked field is omitted in \(format)")
            }
        }
        let englishOnly = text([word], fields: [.english], format: .text)
        try require(englishOnly.contains("coffee shop") && !englishOnly.contains("咖啡馆") && !englishOnly.contains("DeepSeek"),
                    "Chinese meanings and attribution can be omitted independently")
        let surface = NotebookExporter.rows(words: [word], fields: [.surface])
        try require(surface == Array(repeating: ["喫茶店", "喫茶店"], count: 3), "Original surface keeps example rows")

        let orphan = SavedWord(definition: definition, examples: [])
        let missingExamples = NotebookExporter.rows(words: [orphan], fields: [.reading, .chinese, .sentence, .filename])
        try require(missingExamples == [["喫茶店", "きっさてん", "咖啡馆；茶饮店", "", ""]],
                    "Words without examples still export")
        let missingMeaning = SavedWord(definition: Definition(head: "未知語", reading: "", chinese: nil, english: nil), examples: [])
        let missing = NotebookExporter.rows(words: [missingMeaning], fields: [.chinese, .english, .source])
        try require(missing == [["未知語", "", "", ""]], "Missing dictionary fields export as empty cells")

        let sameSpelling = SavedWord(definition: Definition(head: "喫茶店", reading: "別の読み", chinese: nil, english: nil), examples: [])
        try require(NotebookExporter.rows(words: [word, sameSpelling], fields: []).count == 2,
                    "Distinct saved entries keep their order and identity")
        try require(NotebookExporter.rows(words: [], fields: []).isEmpty, "Empty notebook")

        let loanDefinition = Definition(head: "アルバイト", reading: "あるばいと", chinese: "打工；兼职", english: nil,
                                        source: "DeepSeek · deepseek-flash", etymology: "德语 Arbeit，原意为工作。")
        let loanword = SavedWord(definition: loanDefinition, examples: [])
        for format in NotebookExportFormat.allCases {
            let included = text([loanword], fields: [.etymology], format: format)
            let excluded = text([loanword], fields: [.chinese], format: format)
            try require(included.contains("外来语词源") && included.contains("德语 Arbeit"), "Origin has its own export field")
            try require(!excluded.contains("Arbeit") && !excluded.contains("外来语词源"), "Origin can be excluded independently")
        }
        let oldOrigin = NotebookExporter.rows(words: [word], fields: [.etymology])
        try require(oldOrigin == [["喫茶店", ""]], "Legacy entries export an empty origin field")

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("yomitoki-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: path) }
        let exported = NotebookExporter.data(words: [word], fields: Set(NotebookExportField.allCases), format: .csv)
        try exported.write(to: path, options: .atomic)
        let restored = try Data(contentsOf: path)
        try require(restored == exported && restored.starts(with: [0xEF, 0xBB, 0xBF]), "UTF-8 CSV survives a file round trip")
        print("Passed export fields, CSV escaping, TXT, contextual meanings, legacy data, and file round-trip checks.")
    }
}
