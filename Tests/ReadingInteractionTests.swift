import AppKit

private struct InteractionFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw InteractionFailure(message: message) }
}

@main struct ReadingInteractionTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let chapter = String(repeating: "駅まで歩いた。☕️ 明日もここで会おう。\n\n", count: 60)
        let styledChapter = NSAttributedString(string: chapter, attributes: [.font: NSFont.systemFont(ofSize: 26)])
        let smallPages = ReadingText.pageStarts(for: styledChapter, size: CGSize(width: 280, height: 240))
        let largePages = ReadingText.pageStarts(for: styledChapter, size: CGSize(width: 560, height: 480))
        try require(smallPages.count > largePages.count && largePages.count > 1, "EPUB page count follows viewport size")
        let slices = zip(smallPages, smallPages.dropFirst() + [styledChapter.length]).compactMap { start, end in
            Range(NSRange(location: start, length: end - start), in: chapter).map { String(chapter[$0]) }
        }
        try require(slices.count == smallPages.count && slices.joined() == chapter, "Screen pages preserve all Unicode text")
        let source = "雨が上がった。私は喫茶店に入った。\n\n寒い。\n\n明日は駅へ行く"
        for selected in ["雨が上がった。", "雨が上がった", "私は喫茶店に入った。", "雨が上がった。私は喫茶店に入った。", "寒い。", "明日は駅へ行く", source] {
            let range = (source as NSString).range(of: selected)
            try require(TranslationSelection.isEligible(range, in: source), "Complete sentence/paragraph must enable translation: \(selected)")
        }
        for selected in ["雨", "喫茶店", "入った", "寒い", "駅", "私は喫茶店", "が上がった。", "。", "\n\n"] {
            let range = (source as NSString).range(of: selected)
            try require(!TranslationSelection.isEligible(range, in: source), "Word/fragment must disable translation: \(selected)")
        }
        for word in ["喫茶店", "取り出した", "食べました", "国際連合教育科学文化機関", "カフェラテ"] {
            try require(!TranslationSelection.isEligible(NSRange(location: 0, length: word.utf16.count), in: word),
                        "A standalone word must not become a paragraph because of length: \(word)")
        }
        try require(!TranslationSelection.isEligible(NSRange(location: NSNotFound, length: 10), in: source), "Invalid range stays disabled")
        try require(!TranslationSelection.isEligible(NSRange(location: 1, length: 1), in: "😀"), "Invalid Unicode boundary stays disabled")
        let levels: [(String, TranslationSelection.Level)] = [
            ("喫茶店", .word), ("入った", .word), ("私は喫茶店", .word),
            ("雨が上がった。", .sentence), ("雨が上がった", .sentence), ("寒い。", .sentence),
            ("雨が上がった。私は喫茶店に入った。", .paragraph), (source, .paragraph)
        ]
        for (selected, expected) in levels {
            try require(TranslationSelection.level(of: (source as NSString).range(of: selected), in: source) == expected,
                        "Selection level: \(selected)")
        }
        try require(TranslationSelection.level(of: NSRange(location: 0, length: 0), in: source) == nil, "Empty selection has no actions")
        try require(TranslationSelection.level(of: NSRange(location: 1, length: 1), in: "😀") == nil, "Invalid Unicode has no actions")
        let policy: [(TranslationSelection.Level, [TranslationSelection.Action], [String])] = [
            (.word, [.dictionary, .modelDefinition, .modelChat], ["词典释义", "大模型释义", "大模型对话"]),
            (.sentence, [.translation, .sentenceAnalysis, .modelChat], ["本地翻译", "长句分析", "大模型对话"]),
            (.paragraph, [.translation, .modelChat], ["本地翻译", "大模型对话"])
        ]
        let toolbar = ReadingText.Coordinator()
        for (level, expectedActions, expectedTitles) in policy {
            try require(level.actions == expectedActions, "Each level has exactly the requested actions")
            let buttons = level.actions.map { toolbar.button(for: $0) }
            try require(buttons.map(\.title) == expectedTitles && buttons.allSatisfy { $0.action != nil },
                        "Rendered toolbar buttons match the three-level policy")
        }
        let view = ReadingTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        view.isEditable = false
        view.isSelectable = true
        view.string = "☕️ 雨が上がったので、傘を閉じて小さな喫茶店に入った。"
        let coordinator = ReadingText.Coordinator()
        view.delegate = coordinator
        var lookups = 0
        var lastSelection: NSRange?
        coordinator.onTap = { _ in lookups += 1; return NSRange(location: 0, length: 99) }
        coordinator.onSelectionChange = { range, _ in lastSelection = range }
        for text in ["上がった", "がった", "傘を閉じて小さな", "☕️", "、", " "] {
            let range = (view.string as NSString).range(of: text)
            view.setSelectedRange(range)
            coordinator.selectionChanged(in: view, showActions: false)
            try require(view.selectedRange() == range, "Manual selection was changed by lookup: \(text)")
            try require(lookups == 0, "Manual selection invoked automatic segmentation")
            try require((view.string as NSString).substring(with: view.selectedRange()) == text,
                        "Selected text must preserve exact characters, not the dictionary lemma")
            if text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
                try require(lastSelection == range, "Dictionary and model actions use the exact manual range")
            }
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))

        let range = (view.string as NSString).range(of: "雨")
        let layout = view.layoutManager!
        let container = view.textContainer!
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        coordinator.singleClickLookupEnabled = false
        coordinator.singleClick(at: point, in: view)
        try require(lookups == 0, "Disabled single-click lookup must not run the dictionary")
        coordinator.singleClickLookupEnabled = true
        coordinator.singleClick(at: point, in: view)
        try require(lookups == 1, "Enabled single-click lookup still works")
        coordinator.singleClickLookupEnabled = false
        coordinator.singleClick(at: point, in: view)
        try require(lookups == 1, "Changing the switch takes effect immediately")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let panel = SelectionActionsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        window.addChildWindow(panel, ordered: .above)
        try require(window.firstResponder === view && !panel.canBecomeKey && !panel.canBecomeMain,
                    "Selection actions must leave keyboard copy with the reader")
        window.removeChildWindow(panel)
        panel.close()
        print("Passed sentence/paragraph translation eligibility, word/fragment rejection, single-click switch, exact selection, Unicode, and toolbar focus checks.")
    }
}
