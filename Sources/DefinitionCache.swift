import Foundation

struct DefinitionResolution {
    let definition: Definition
    let reused: Bool
    var warning: String? = nil
}

/// Groups original-sentence explanations by lemma, reading, and model configuration.
/// Surface forms remain aliases of their dictionary entry.
@MainActor final class DefinitionResolver {
    private struct Scope: Codable, Equatable {
        let provider: ModelProvider
        let endpoint: String
        let model: String

        init(_ settings: DefinitionSettings) throws {
            provider = settings.provider
            endpoint = try settings.endpoint().absoluteString
            model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct Entry: Codable {
        let scope: Scope
        var definition: Definition
        var forms: [String]
        var context: SentenceContext?
        var aliases: [Alias]?
        var contexts: [ContextualDefinition]?
    }

    private struct ContextualDefinition: Codable {
        let context: SentenceContext
        let definition: Definition
    }

    private struct Alias: Codable, Equatable {
        let head: String
        let reading: String
        let surface: String
    }

    private struct Store: Codable {
        var version = 1
        var entries: [Entry] = []
    }

    private let path: URL
    private let dictionary: Lexicon
    private var store = Store()
    private var writable = true
    private var loadWarning: String?

    init(path: URL, dictionary: Lexicon) {
        self.path = path
        self.dictionary = dictionary
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            let decoded = try JSONDecoder().decode(Store.self, from: Data(contentsOf: path))
            guard decoded.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            store = decoded
        } catch {
            writable = false
            loadWarning = "释义缓存无法读取，原文件已保留；本次结果仅缓存在内存中。"
        }
    }

    func resolve(_ selected: Lookup, settings: DefinitionSettings, savedWords: [SavedWord],
                 refresh: Bool = false, requireExactContext: Bool = false,
                 fetch: () async throws -> Definition) async throws -> DefinitionResolution {
        let scope = try Scope(settings)
        let canonical = dictionary.normalized(selected.definition)
        let alias = Alias(head: canonical.head, reading: canonical.reading, surface: selected.occurrence.context.word)
        if !refresh {
            let candidates = store.entries.filter {
                $0.scope == scope && (matches($0.definition, canonical: canonical,
                                              aliases: $0.forms, surface: selected.occurrence.context.word)
                                       || $0.aliases?.contains(alias) == true)
            }
            let context = selected.occurrence.context
            let exact = candidates.compactMap { entry in
                entry.contexts?.first { $0.context == context }?.definition
                    ?? (entry.context == context ? entry.definition : nil)
            }
            if exact.count == 1, let definition = exact.first {
                return DefinitionResolution(definition: definition, reused: true, warning: loadWarning)
            }
            // A saved example can carry a meaning specific to this exact sentence.
            // Prefer it to a more recently generated, general word-level cache entry.
            if let saved = savedDefinition(for: canonical, context: selected.occurrence.context, words: savedWords, exact: true) {
                return DefinitionResolution(definition: saved, reused: true)
            }
            if !requireExactContext, candidates.count == 1, let cached = candidates.first {
                return DefinitionResolution(definition: cached.definition, reused: true, warning: loadWarning)
            }
            if !requireExactContext,
               let saved = savedDefinition(for: canonical, context: context, words: savedWords, exact: false) {
                return DefinitionResolution(definition: saved, reused: true)
            }
        }
        let generated = try await fetch()
        try Task.checkCancellation()
        let definition = dictionary.normalized(generated)
        // Failed/incomplete generations must never turn into cache hits later.
        guard definition.hasMeaning, !definition.head.isEmpty, !definition.reading.isEmpty else {
            throw ModelFailure("模型返回的释义格式不完整，请重试或更换模型。")
        }
        let key = identity(definition)
        let form = selected.occurrence.context.word
        if let index = store.entries.firstIndex(where: { $0.scope == scope && identity($0.definition) == key }) {
            var contexts = store.entries[index].contexts ?? []
            if contexts.isEmpty, let previous = store.entries[index].context {
                contexts.append(ContextualDefinition(context: previous, definition: store.entries[index].definition))
            }
            contexts.removeAll { $0.context == selected.occurrence.context }
            contexts.append(ContextualDefinition(context: selected.occurrence.context, definition: definition))
            store.entries[index].contexts = contexts
            store.entries[index].definition = definition
            store.entries[index].forms = Array(Set(store.entries[index].forms + [form])).sorted()
            store.entries[index].context = selected.occurrence.context
            if !(store.entries[index].aliases?.contains(alias) ?? false) {
                store.entries[index].aliases = (store.entries[index].aliases ?? []) + [alias]
            }
        } else {
            store.entries.append(Entry(scope: scope, definition: definition, forms: [form],
                                       context: selected.occurrence.context, aliases: [alias]))
        }
        var warning = loadWarning
        if writable {
            do {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(store).write(to: path, options: .atomic)
            } catch {
                warning = "释义已生成，但缓存保存失败；本次结果仅缓存在内存中。\(error.localizedDescription)"
            }
        }
        return DefinitionResolution(definition: definition, reused: false, warning: warning)
    }

    private func identity(_ definition: Definition) -> String {
        definition.head + "\n" + definition.reading
    }

    private func matches(_ definition: Definition, canonical: Definition, aliases: [String], surface: String) -> Bool {
        if !canonical.reading.isEmpty { return identity(definition) == identity(canonical) }
        return definition.head == canonical.head || aliases.contains(surface)
    }

    private func savedDefinition(for canonical: Definition, context: SentenceContext, words: [SavedWord], exact: Bool) -> Definition? {
        let candidates = words.filter { word in
            let definition = dictionary.normalized(word.definition)
            let hasModelDefinition = (definition.hasMeaning && definition.source != nil)
                || word.examples.contains { $0.definition?.hasMeaning == true && $0.definition?.source != nil }
            return hasModelDefinition && matches(definition, canonical: canonical,
                                                 aliases: word.examples.map { $0.context.word }, surface: context.word)
        }
        let contextual = candidates.flatMap { word in
            word.examples.filter { $0.context == context }.map { dictionary.normalized($0.definition ?? word.definition) }
                .filter { $0.source != nil && $0.hasMeaning }
        }
        if exact {
            guard let first = contextual.first, contextual.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        guard candidates.count == 1, let word = candidates.first else { return nil }
        if word.definition.source != nil, word.definition.hasMeaning { return dictionary.normalized(word.definition) }
        return word.examples.compactMap(\.definition).first(where: { $0.source != nil && $0.hasMeaning }).map(dictionary.normalized)
    }
}
