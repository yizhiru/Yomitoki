import Foundation

enum NotebookExportFormat: String, CaseIterable {
    case csv, text = "txt"
    var title: String { self == .csv ? "CSV 表格" : "纯文本 TXT" }
}

enum NotebookExportField: String, CaseIterable {
    case reading, chinese, english, etymology, source, surface, sentence, filename, location

    var title: String {
        switch self {
        case .reading: return "读音"
        case .chinese: return "中文释义"
        case .english: return "英文释义"
        case .etymology: return "外来语词源"
        case .source: return "释义来源"
        case .surface: return "原文词形"
        case .sentence: return "原句"
        case .filename: return "文件名"
        case .location: return "页码或节位置"
        }
    }

    var usesOccurrence: Bool {
        [.surface, .sentence, .filename, .location].contains(self)
    }

    func value(definition: Definition, occurrence: Occurrence?) -> String {
        switch self {
        case .reading: return definition.reading
        case .chinese: return definition.chinese ?? ""
        case .english: return definition.english ?? ""
        case .etymology: return definition.etymology ?? ""
        case .source: return definition.source ?? definition.dictionaryName ?? (definition.hasMeaning ? "离线词典" : "")
        case .surface: return occurrence?.context.word ?? ""
        case .sentence: return occurrence?.context.sentence ?? ""
        case .filename: return occurrence?.filename ?? ""
        case .location: return occurrence?.location ?? ""
        }
    }
}

enum NotebookExporter {
    static func rows(words: [SavedWord], fields: [NotebookExportField]) -> [[String]] {
        let includeOccurrences = fields.contains(where: \.usesOccurrence)
        return words.flatMap { word -> [[String]] in
            let examples: [Occurrence?] = word.examples.isEmpty ? [nil] : word.examples.map { $0 }
            var seen: Set<[String]> = []
            return examples.compactMap { occurrence in
                let definition = occurrence?.definition ?? word.definition
                let row = [word.definition.head] + fields.map { $0.value(definition: definition, occurrence: occurrence) }
                guard includeOccurrences || seen.insert(row).inserted else { return nil }
                return row
            }
        }
    }

    static func data(words: [SavedWord], fields: Set<NotebookExportField>, format: NotebookExportFormat) -> Data {
        let columns = NotebookExportField.allCases.filter { fields.contains($0) }
        let headings = ["单词"] + columns.map(\.title)
        let rows = rows(words: words, fields: columns)
        switch format {
        case .csv:
            let text = ([headings] + rows).map { row in
                row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
            }.joined(separator: "\r\n") + "\r\n"
            // The UTF-8 BOM lets spreadsheet apps identify Chinese and Japanese text.
            return Data(("\u{FEFF}" + text).utf8)
        case .text:
            if columns.isEmpty { return Data((rows.map { $0[0] }.joined(separator: "\n") + "\n").utf8) }
            let text = rows.map { row in
                zip(headings, row).map { heading, value in heading + "\t" + value }.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
            return Data(text.utf8)
        }
    }
}
