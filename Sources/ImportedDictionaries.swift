import Foundation

struct ImportedDictionaryInfo: Codable, Identifiable {
    let id: UUID
    let name: String
}

struct DictionaryCatalog: Codable {
    var dictionaries: [ImportedDictionaryInfo] = []
    var selected: UUID?
}

struct ImportedDictionaryIndex {
    let info: ImportedDictionaryInfo
    private let entries: [String: String]

    init(info: ImportedDictionaryInfo, chunks: [String]) throws {
        var entries: [String: String] = [:]
        for chunk in chunks {
            let values = try JSONDecoder().decode([String: String].self, from: Data(chunk.utf8))
            entries.merge(values) { first, _ in first }
        }
        guard !entries.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        self.info = info
        self.entries = entries
    }

    func meaning(for forms: [String], reading: String = "") -> String? {
        let normalizedReading = reading.precomposedStringWithCompatibilityMapping
        let kana = normalizedReading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? normalizedReading
        let keys = forms.filter { !$0.isEmpty }.flatMap { form -> [String] in
            let normalized = form.precomposedStringWithCompatibilityMapping
            return (kana.isEmpty ? [] : [normalized + "\n" + kana]) + [form, normalized]
        }
        for candidate in keys {
            var key = candidate
            var seen = Set<String>()
            while seen.insert(key).inserted, let text = entries[key] {
                guard text.hasPrefix("@@@LINK=") else { return text }
                key = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

struct ImportedDictionaryFiles {
    let directory: URL

    func catalog() throws -> DictionaryCatalog {
        let file = directory.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return DictionaryCatalog() }
        return try JSONDecoder().decode(DictionaryCatalog.self, from: Data(contentsOf: file))
    }

    func save(_ catalog: DictionaryCatalog) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
    }

    func file(for info: ImportedDictionaryInfo) -> URL {
        directory.appendingPathComponent(info.id.uuidString + ".json")
    }

    func load(_ info: ImportedDictionaryInfo) throws -> ImportedDictionaryIndex {
        let chunks = try JSONDecoder().decode([String].self, from: Data(contentsOf: file(for: info)))
        return try ImportedDictionaryIndex(info: info, chunks: chunks)
    }
}
