import AppKit
import SwiftUI

/// Keeps native selection, dragging, contextual menus, and copy behavior intact.
final class ReadingTextView: NSTextView {
    var onSelectionBegan: () -> Void = {}
    var onSelectionEnded: () -> Void = {}
    var onSingleClick: (NSPoint) -> Void = { _ in }
    private(set) var trackingSelection = false

    override func mouseDown(with event: NSEvent) {
        onSelectionBegan()
        trackingSelection = true
        var dragged = false
        let start = event.locationInWindow
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { drag in
            if hypot(drag.locationInWindow.x - start.x, drag.locationInWindow.y - start.y) >= 3 { dragged = true }
            return drag
        }
        super.mouseDown(with: event)
        if let monitor { NSEvent.removeMonitor(monitor) }
        trackingSelection = false
        if event.clickCount == 1, selectedRange().length == 0, !dragged {
            onSingleClick(convert(event.locationInWindow, from: nil))
        }
        onSelectionEnded()
    }

}

final class SelectionActionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ReadingText: NSViewRepresentable {
    let bodyText: String
    let revision: UUID
    let selection: NSRange?
    let fontSize: CGFloat
    let singleClickLookupEnabled: Bool
    let onTap: (Int) -> NSRange?
    let onSelectionChange: (NSRange?) -> Void
    let onDictionaryLookup: (NSRange) -> Void
    let onModelLookup: (NSRange) -> Void
    let onTranslation: (NSRange) -> Void
    let selectionLevel: (NSRange) -> TranslationSelection.Level?
    let onSentenceAnalysis: (NSRange) -> Void
    var onModelChat: (NSRange) -> Void = { _ in }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTap: (Int) -> NSRange? = { _ in nil }
        var onSelectionChange: (NSRange?) -> Void = { _ in }
        var onDictionaryLookup: (NSRange) -> Void = { _ in }
        var onModelLookup: (NSRange) -> Void = { _ in }
        var onTranslation: (NSRange) -> Void = { _ in }
        var selectionLevel: (NSRange) -> TranslationSelection.Level? = { _ in nil }
        var onSentenceAnalysis: (NSRange) -> Void = { _ in }
        var onModelChat: (NSRange) -> Void = { _ in }
        var updating = false
        var revision: UUID?
        var fontSize: CGFloat = 0
        var selection: NSRange?
        var singleClickLookupEnabled = false
        private weak var textView: ReadingTextView?
        private var panel: SelectionActionsPanel?
        private var actionRange: NSRange?
        private var pendingActions: DispatchWorkItem?
        private var mouseMonitor: Any?
        private var observers: [NSObjectProtocol] = []

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? ReadingTextView else { return }
            selectionChanged(in: view, showActions: !view.trackingSelection && NSEvent.pressedMouseButtons == 0)
        }

        func selectionChanged(in view: ReadingTextView, showActions: Bool) {
            dismissActions()
            let range = view.selectedRange()
            guard range.length > 0, let selected = Range(range, in: view.string) else {
                onSelectionChange(nil)
                return
            }
            let hasLetters = view.string[selected].unicodeScalars.contains { CharacterSet.letters.contains($0) }
            onSelectionChange(hasLetters ? range : nil)
            if showActions, hasLetters { scheduleActions(range, in: view) }
        }

        func singleClick(at point: NSPoint, in view: ReadingTextView) {
            guard singleClickLookupEnabled else { return }
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            let local = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
            let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            guard index < view.string.utf16.count else { return }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            guard layout.boundingRect(forGlyphRange: glyphs, in: container).contains(local) else { return }
            _ = onTap(index)
        }

        func observeSelection(in view: ReadingTextView, scroll: NSScrollView) {
            textView = view
            view.onSelectionBegan = { [weak self] in self?.dismissActions() }
            view.onSingleClick = { [weak self, weak view] point in
                if let view { self?.singleClick(at: point, in: view) }
            }
            view.onSelectionEnded = { [weak self, weak view] in
                if let view { self?.selectionChanged(in: view, showActions: true) }
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismissActions() }
                } else if event.window !== self.panel {
                    self.dismissActions()
                }
                return event
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in self?.dismissActions() })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: nil, queue: .main) { [weak self] notification in
                    if let window = notification.object as? NSWindow, window === self?.textView?.window {
                        self?.dismissActions()
                    }
                })
        }

        private func scheduleActions(_ range: NSRange, in view: ReadingTextView) {
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view, view.selectedRange() == range,
                      let window = view.window, window.isVisible,
                      let layout = view.layoutManager, let container = view.textContainer,
                      Range(range, in: view.string) != nil else { return }
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x += view.textContainerOrigin.x
                rect.origin.y += view.textContainerOrigin.y
                rect = rect.intersection(view.visibleRect)
                guard !rect.isNull, !rect.isEmpty else { return }
                let screenRect = window.convertToScreen(view.convert(rect, to: nil))
                let frame = window.screen?.visibleFrame ?? screenRect.insetBy(dx: -400, dy: -200)
                guard let level = self.selectionLevel(range) else { return }
                let panelWidth = max(140, CGFloat(level.actions.count) * 116 + 12)
                let panel = SelectionActionsPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 44),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.becomesKeyOnlyIfNeeded = true
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = true
                panel.isReleasedWhenClosed = false
                panel.hasShadow = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.level = .floating
                let background = NSVisualEffectView(frame: panel.contentView!.bounds)
                background.material = .popover
                background.state = .active
                background.wantsLayer = true
                background.layer?.cornerRadius = 10
                background.layer?.masksToBounds = true
                let stack = NSStackView(views: level.actions.map { self.button(for: $0) })
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 10
                stack.translatesAutoresizingMaskIntoConstraints = false
                background.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
                ])
                panel.contentView = background
                let x = min(max(frame.minX + 8, screenRect.midX - panelWidth / 2), frame.maxX - panelWidth - 8)
                let above = screenRect.maxY + 8
                let y = above + 44 <= frame.maxY - 8 ? above : max(frame.minY + 8, screenRect.minY - 52)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                self.panel = panel
                self.actionRange = range
                window.addChildWindow(panel, ordered: .above)
                panel.orderFront(nil) // Never make the toolbar key: ⌘C stays with the text view.
            }
            pendingActions = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }

        private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.isBordered = false
            button.contentTintColor = AppTheme.accentColor
            button.setAccessibilityLabel(title)
            return button
        }
        func button(for action: TranslationSelection.Action) -> NSButton {
            let selector: Selector
            switch action {
            case .dictionary: selector = #selector(defineSelection)
            case .modelDefinition: selector = #selector(defineModelSelection)
            case .translation: selector = #selector(translateSelection)
            case .sentenceAnalysis: selector = #selector(analyzeSelection)
            case .modelChat: selector = #selector(startModelChat)
            }
            return button(action.title, symbol: action.symbol, action: selector)
        }

        private func permits(_ action: TranslationSelection.Action, at range: NSRange) -> Bool {
            selectionLevel(range)?.actions.contains(action) == true
        }

        @objc private func defineSelection() {
            guard let range = actionRange, permits(.dictionary, at: range) else { return }
            dismissActions()
            onDictionaryLookup(range)
        }
        @objc private func defineModelSelection() {
            guard let range = actionRange, permits(.modelDefinition, at: range) else { return }
            dismissActions()
            onModelLookup(range)
        }
        @objc private func translateSelection() {
            guard let range = actionRange, permits(.translation, at: range) else { return }
            dismissActions()
            onTranslation(range)
        }
        @objc private func analyzeSelection() {
            guard let range = actionRange, permits(.sentenceAnalysis, at: range) else { return }
            dismissActions()
            onSentenceAnalysis(range)
        }
        @objc private func startModelChat() {
            guard let range = actionRange, permits(.modelChat, at: range) else { return }
            dismissActions()
            onModelChat(range)
        }
        func dismissActions() {
            pendingActions?.cancel()
            pendingActions = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.close()
            }
            panel = nil
            actionRange = nil
        }
        func stopObserving() {
            dismissActions()
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            mouseMonitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = ReadingTextView(frame: scroll.contentView.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 4, height: 12)
        view.delegate = context.coordinator
        view.setAccessibilityLabel("日语正文，双击或拖选文字后可复制、查释义或与大模型对话")
        scroll.documentView = view
        context.coordinator.observeSelection(in: view, scroll: scroll)
        return scroll
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.stopObserving() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ReadingTextView, let storage = view.textStorage else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.onTap = onTap
        coordinator.singleClickLookupEnabled = singleClickLookupEnabled
        coordinator.onSelectionChange = onSelectionChange
        coordinator.onDictionaryLookup = onDictionaryLookup
        coordinator.onModelLookup = onModelLookup
        coordinator.onTranslation = onTranslation
        coordinator.selectionLevel = selectionLevel
        coordinator.onSentenceAnalysis = onSentenceAnalysis
        coordinator.onModelChat = onModelChat
        view.setAccessibilityLabel(singleClickLookupEnabled
            ? "日语正文，单击自动查词，选词可查释义，句段可本地翻译，单句可长句分析，按 ⌘C 复制"
            : "日语正文，选词可查释义，句段可本地翻译，单句可长句分析，按 ⌘C 复制")
        let newPage = coordinator.revision != revision
        if newPage { coordinator.dismissActions() }
        if newPage || coordinator.fontSize != fontSize {
            let selectedRange = newPage ? NSRange(location: 0, length: 0) : view.selectedRange()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 10
            paragraph.paragraphSpacing = 7
            let font = NSFont(name: "HiraginoSans-W3", size: fontSize) ?? .systemFont(ofSize: fontSize)
            let display = bodyText.isEmpty ? "此页没有可提取的文字。" : bodyText
            storage.setAttributedString(NSAttributedString(string: display, attributes: [
                .font: font,
                .foregroundColor: AppTheme.textColor,
                .paragraphStyle: paragraph
            ]))
            if NSMaxRange(selectedRange) <= storage.length { view.setSelectedRange(selectedRange) }
            coordinator.revision = revision
            coordinator.fontSize = fontSize
            coordinator.selection = nil
            if newPage { view.scrollToBeginningOfDocument(nil) }
        }
        if coordinator.selection != selection {
            if let old = coordinator.selection, NSMaxRange(old) <= storage.length { storage.removeAttribute(.backgroundColor, range: old) }
            if let selection, NSMaxRange(selection) <= storage.length {
                storage.addAttribute(.backgroundColor,
                    value: AppTheme.selectionColor, range: selection)
            }
            coordinator.selection = selection
        }
    }
}
