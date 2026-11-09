import AppKit

private struct SplitTestFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SplitTestFailure(message: message) }
}

@main struct SplitWidthTests {
    static func main() throws {
        let suite = "yomitoki-split-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sidebar = SplitWidthStore(identifier: "sidebar", idealWidth: 220, defaults: defaults)
        try require(sidebar.preferredWidth == 220, "New installs use the ideal width")
        sidebar.remember(280)
        let reopened = SplitWidthStore(identifier: "sidebar", idealWidth: 220, defaults: defaults)
        try require(reopened.preferredWidth == 280, "Sidebar width survives a recreated view or restarted app")
        let inspector = SplitWidthStore(identifier: "inspector", idealWidth: 360, defaults: defaults)
        let notebook = SplitWidthStore(identifier: "notebookList", idealWidth: 220, defaults: defaults)
        inspector.remember(540)
        notebook.remember(260)
        try require(sidebar.preferredWidth == 280 && inspector.preferredWidth == 540 && notebook.preferredWidth == 260,
                    "The three divider preferences remain independent")
        try require(inspector.fittedWidth(available: 800, minimum: 300, maximum: 700, otherMinimum: 360) == 440,
                    "Narrow windows preserve space for the reader")
        try require(inspector.preferredWidth == 540, "A temporary window constraint cannot overwrite the user's width")
        try require(inspector.fittedWidth(available: 1500, minimum: 300, maximum: 700, otherMinimum: 360) == 540,
                    "Expanding the window restores the preferred width")
        try require(sidebar.fittedWidth(available: 500, minimum: 198, maximum: 340, otherMinimum: 660) == 0,
                    "Insufficient space never produces a negative frame")
        inspector.remember(.nan)
        inspector.remember(-10)
        try require(inspector.preferredWidth == 540, "Invalid geometry cannot corrupt saved preferences")
        defaults.set(Double.infinity, forKey: "splitWidth.invalid")
        let repaired = SplitWidthStore(identifier: "invalid", idealWidth: 220, defaults: defaults)
        try require(repaired.preferredWidth == 220, "Invalid persisted geometry falls back to a usable default")
        print("Passed split-width persistence, independent panes, window resizing, and invalid-geometry checks.")
    }
}
