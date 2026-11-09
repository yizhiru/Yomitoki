import Foundation
import NaturalLanguage

/// Recognizes complete selected sentences/paragraphs using the original text.
enum TranslationSelection {
    enum Action: Equatable {
        case dictionary, modelDefinition, translation, sentenceAnalysis, modelChat
        var title: String {
            switch self {
            case .dictionary: return "词典释义"
            case .modelDefinition: return "大模型释义"
            case .translation: return "本地翻译"
            case .sentenceAnalysis: return "长句分析"
            case .modelChat: return "大模型对话"
            }
        }
        var symbol: String {
            switch self {
            case .dictionary: return "text.magnifyingglass"
            case .modelDefinition: return "sparkles"
            case .translation: return "character.bubble"
            case .sentenceAnalysis: return "text.alignleft"
            case .modelChat: return "bubble.left.and.bubble.right"
            }
        }
    }

    enum Level: Equatable {
        case word, sentence, paragraph
        var actions: [Action] {
            switch self {
            case .word: return [.dictionary, .modelDefinition, .modelChat]
            case .sentence: return [.translation, .sentenceAnalysis, .modelChat]
            case .paragraph: return [.translation, .modelChat]
            }
        }
    }

    private static let endings = CharacterSet(charactersIn: "。！？.!?")
    private static let padding = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "。！？.!?「」『』“”‘’\"（）()［］[]"))

    static func level(of selection: NSRange, in text: String) -> Level? {
        guard selection.location >= 0, selection.length > 0, selection.location <= text.utf16.count,
              selection.length <= text.utf16.count - selection.location,
              let range = Range(selection, in: text),
              range.lowerBound.samePosition(in: text.unicodeScalars) != nil,
              range.upperBound.samePosition(in: text.unicodeScalars) != nil,
              text[range].unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        guard isEligible(selection, in: text), let content = contentRange(selection, in: text) else { return .word }
        // Prefer sentence level for a single sentence, including a one-sentence
        // paragraph. Multiple complete sentences or paragraphs use translation only.
        if unitCount(overlapping: content, in: text, unit: .sentence) > 1
            || unitCount(overlapping: content, in: text, unit: .paragraph) > 1 { return .paragraph }
        return .sentence
    }

    private static func unitCount(overlapping selection: NSRange, in text: String, unit: NLTokenUnit) -> Int {
        let tokenizer = NLTokenizer(unit: unit)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let content = contentRange(NSRange(range, in: text), in: text), NSIntersectionRange(content, selection).length > 0 {
                count += 1
            }
            return count < 2
        }
        return count
    }

    static func isEligible(_ selection: NSRange, in text: String) -> Bool {
        guard selection.location >= 0, selection.length > 0, selection.location <= text.utf16.count,
              selection.length <= text.utf16.count - selection.location,
              let range = Range(selection, in: text),
              range.lowerBound.samePosition(in: text.unicodeScalars) != nil,
              range.upperBound.samePosition(in: text.unicodeScalars) != nil else { return false }
        let selected = String(text[range])
        guard selected.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
              let content = contentRange(selection, in: text) else { return false }
        // Ignore surrounding whitespace/quotes and optional terminal punctuation,
        // but require both ends to coincide with source sentence/paragraph ends.
        guard coversUnits(content, in: text, unit: .sentence)
            || coversUnits(content, in: text, unit: .paragraph) else { return false }
        if selected.unicodeScalars.contains(where: { endings.contains($0) }) { return true }

        // A bare noun or inflected verb can fill a whole line too. Without
        // sentence punctuation, require a clause with a tokenized connector.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = selected
        var words: [String] = []
        tokenizer.enumerateTokens(in: selected.startIndex..<selected.endIndex) { range, _ in
            let word = String(selected[range])
            if word.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { words.append(word) }
            return true
        }
        let connectors: Set<String> = ["が", "は", "を", "に", "へ", "と", "も", "から", "まで", "より", "ので", "のに"]
        return words.count >= 3 && words.contains(where: { connectors.contains($0) })
    }

    private static func contentRange(_ range: NSRange, in text: String) -> NSRange? {
        let substring = (text as NSString).substring(with: range) as NSString
        let first = substring.rangeOfCharacter(from: padding.inverted)
        guard first.location != NSNotFound else { return nil }
        let last = substring.rangeOfCharacter(from: padding.inverted, options: .backwards)
        return NSRange(location: range.location + first.location, length: NSMaxRange(last) - first.location)
    }

    private static func coversUnits(_ selection: NSRange, in text: String, unit: NLTokenUnit) -> Bool {
        let tokenizer = NLTokenizer(unit: unit)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = text
        var beginsUnit = false
        var endsUnit = false
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let content = contentRange(NSRange(range, in: text), in: text) {
                if content.location == selection.location { beginsUnit = true }
                if NSMaxRange(content) == NSMaxRange(selection) { endsUnit = true }
            }
            return !(beginsUnit && endsUnit)
        }
        return beginsUnit && endsUnit
    }
}
