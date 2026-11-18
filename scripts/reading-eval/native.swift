import Foundation

@main struct Readings {
    static func main() throws {
        let lexicon = Lexicon(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let texts = try JSONDecoder().decode([String].self, from: data)
        let rows = texts.map { text in
            lexicon.readingAnnotations(text, tokens: Lexicon.tokens(text), saved: [], showKana: true)
                .filter { !$0.kana.isEmpty }
                .map { [$0.range.location, NSMaxRange($0.range), $0.kana] as [Any] }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: rows))
    }
}
