import AppKit
import SwiftUI

/// Keeps native selection, dragging, contextual menus, and copy behavior intact.
final class ReadingTextView: NSTextView {
    var onSelectionBegan: () -> Void = {}
    var onSelectionEnded: () -> Void = {}
    var onSingleClick: (NSPoint) -> Void = { _ in }
    var onSelectionHover: (NSPoint) -> Void = { _ in }
    var onPageTurn: ((Bool) -> Void)?
    private(set) var trackingSelection = false
    private var selectionTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let selectionTrackingArea { removeTrackingArea(selectionTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        selectionTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onSelectionHover(convert(event.locationInWindow, from: nil))
    }

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

    override func keyDown(with event: NSEvent) {
        if let onPageTurn, event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
           event.keyCode == 123 || event.keyCode == 124 {
            onPageTurn(event.keyCode == 124)
            return
        }
        super.keyDown(with: event)
    }

}

final class SelectionActionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ReadingPagination: Equatable {
    let revision: UUID
    let index: Int
    let count: Int
    let previousOffset: Int?
    let nextOffset: Int?
}

struct ReadingText: NSViewRepresentable {
    let bodyText: String
    let revision: UUID
    let selection: NSRange?
    let fontSize: CGFloat
    let singleClickLookupEnabled: Bool
    let onTap: (Int) -> NSRange?
    let onSelectionChange: (NSRange?, Bool) -> Void
    let onDictionaryLookup: (NSRange) -> Void
    let onModelLookup: (NSRange) -> Void
    let onTranslation: (NSRange) -> Void
    let selectionLevel: (NSRange) -> TranslationSelection.Level?
    let onSentenceAnalysis: (NSRange) -> Void
    var onModelChat: (NSRange) -> Void = { _ in }
    var searchHighlight: NSRange?
    var pageSize: CGSize?
    var readingOffset = 0
    var onPagination: ((ReadingPagination) -> Void)?
    var onPageTurn: ((Bool) -> Void)?
    var onReadingProgress: ((Int, UUID) -> Void)?

    static func pageStarts(for text: NSAttributedString, size: CGSize) -> [Int] {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: max(11, size.width - 8),
                                                              height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(for: container)
        var starts = [0]
        var pageTop: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, line, _ in
            guard line.location > 0, rect.maxY - pageTop > max(1, size.height - 24) else { return }
            let offset = layout.characterRange(forGlyphRange: line, actualGlyphRange: nil).location
            guard offset > (starts.last ?? 0), offset < text.length else { return }
            starts.append(offset)
            pageTop = rect.minY
        }
        return starts
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTap: (Int) -> NSRange? = { _ in nil }
        var onSelectionChange: (NSRange?, Bool) -> Void = { _, _ in }
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
        var searchMatch: NSRange?
        var pageSize: CGSize?
        var pageStarts = [0]
        var visibleRange: NSRange?
        var pagination: ReadingPagination?
        var attributedText = NSAttributedString()
        var requestedReadingOffset: Int?
        var appliedReadingOffset: Int?
        var onReadingProgress: ((Int, UUID) -> Void)?
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
                onSelectionChange(nil, false)
                return
            }
            let text = view.string[selected]
            let hasLetters = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            let canQuote = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            onSelectionChange(canQuote ? range : nil, hasLetters)
            if showActions, hasLetters { scheduleActions(range, in: view) }
        }

        func singleClick(at point: NSPoint, in view: ReadingTextView) {
            guard singleClickLookupEnabled, let index = character(at: point, in: view) else { return }
            _ = onTap(index)
        }

        private func character(at point: NSPoint, in view: ReadingTextView) -> Int? {
            guard view.visibleRect.contains(point), let layout = view.layoutManager,
                  let container = view.textContainer else { return nil }
            let local = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
            let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            guard index < view.string.utf16.count else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: container).contains(local) ? index : nil
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
            view.onSelectionHover = { [weak self, weak view] point in
                if let view { self?.restoreActions(at: point, in: view) }
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
                object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                    self?.dismissActions()
                    if let scroll { self?.recordScroll(in: scroll) }
                })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: nil, queue: .main) { [weak self] notification in
                    if let window = notification.object as? NSWindow, window === self?.textView?.window {
                        self?.dismissActions()
                    }
                })
        }

        func restoreActions(at point: NSPoint, in view: ReadingTextView) {
            let range = view.selectedRange()
            guard panel == nil, pendingActions == nil, !view.trackingSelection, range.length > 0,
                  let index = character(at: point, in: view), NSLocationInRange(index, range) else { return }
            scheduleActions(range, in: view)
        }

        private func recordScroll(in scroll: NSScrollView) {
            guard !updating, pageSize == nil, let revision, let view = textView,
                  let layout = view.layoutManager, let container = view.textContainer,
                  let onReadingProgress else { return }
            let top = scroll.documentVisibleRect.minY - view.textContainerOrigin.y
            let offset = top <= 0 ? 0 : layout.characterIndex(
                for: NSPoint(x: container.lineFragmentPadding, y: top), in: container,
                fractionOfDistanceBetweenInsertionPoints: nil)
            guard offset != appliedReadingOffset else { return }
            appliedReadingOffset = offset
            onReadingProgress(offset, revision)
        }

        func restoreScroll(_ offset: Int, in scroll: NSScrollView, view: NSTextView) {
            appliedReadingOffset = offset
            guard offset > 0, let layout = view.layoutManager, let container = view.textContainer,
                  let length = view.textStorage?.length, length > 0 else {
                view.scrollToBeginningOfDocument(nil)
                return
            }
            layout.ensureLayout(for: container)
            let character = min(offset, length - 1)
            let glyph = layout.glyphIndexForCharacter(at: character)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // Ensure the text view has sized itself before moving the clip view to this line.
            view.scrollRangeToVisible(NSRange(location: character, length: 1))
            let clip = scroll.contentView
            let bounds = clip.constrainBoundsRect(NSRect(
                origin: NSPoint(x: clip.bounds.minX, y: line.minY + view.textContainerOrigin.y),
                size: clip.bounds.size))
            clip.scroll(to: bounds.origin)
            scroll.reflectScrolledClipView(clip)
        }

        private func scheduleActions(_ range: NSRange, in view: ReadingTextView) {
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self else { return }
                self.pendingActions = nil
                guard let view, view.selectedRange() == range,
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
                let buttons = (self.selectionLevel(range)?.actions ?? []).map { self.button(for: $0) }
                guard !buttons.isEmpty else { return }
                let panelWidth = max(140, CGFloat(buttons.count) * 116 + 12)
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
                let stack = NSStackView(views: buttons)
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 4
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
            button.font = .systemFont(ofSize: 14, weight: .semibold)
            button.isBordered = false
            button.contentTintColor = AppTheme.accentColor
            button.wantsLayer = true
            button.layer?.backgroundColor = AppTheme.selectionColor.cgColor
            button.layer?.cornerRadius = 8
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 112),
                button.heightAnchor.constraint(equalToConstant: 34)
            ])
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
        scroll.hasVerticalScroller = pageSize == nil
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
        coordinator.onReadingProgress = onReadingProgress
        defer { coordinator.updating = false }
        let newPage = coordinator.revision != revision
        let newText = newPage || coordinator.fontSize != fontSize
        if newText {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 10
            paragraph.paragraphSpacing = 7
            let font = NSFont(name: "HiraginoSans-W3", size: fontSize) ?? .systemFont(ofSize: fontSize)
            coordinator.attributedText = NSAttributedString(
                string: bodyText.isEmpty ? "此页没有可提取的文字。" : bodyText,
                attributes: [.font: font, .foregroundColor: AppTheme.textColor, .paragraphStyle: paragraph])
        }
        if let pageSize, newText || coordinator.pageSize != pageSize {
            coordinator.pageStarts = Self.pageStarts(for: coordinator.attributedText, size: pageSize)
        }
        let starts = coordinator.pageStarts
        let index = pageSize == nil ? 0 : (starts.lastIndex { $0 <= readingOffset } ?? 0)
        let start = pageSize == nil ? 0 : starts[index]
        let next = pageSize != nil && index + 1 < starts.count ? starts[index + 1] : nil
        let visible = NSRange(location: start, length: (next ?? coordinator.attributedText.length) - start)
        let changedSlice = coordinator.visibleRange != visible
        coordinator.pageSize = pageSize
        coordinator.visibleRange = visible
        if let onPagination, pageSize != nil {
            let pagination = ReadingPagination(revision: revision, index: index, count: starts.count,
                previousOffset: index > 0 ? starts[index - 1] : nil, nextOffset: next)
            if pagination != coordinator.pagination {
                coordinator.pagination = pagination
                DispatchQueue.main.async { [weak coordinator] in
                    if coordinator?.pagination == pagination { onPagination(pagination) }
                }
            }
        } else { coordinator.pagination = nil }
        let sourceRange: (NSRange) -> NSRange = { NSRange(location: $0.location + start, length: $0.length) }
        let localRange: (NSRange) -> NSRange? = { range in
            guard range.location >= start, NSMaxRange(range) <= NSMaxRange(visible) else { return nil }
            return NSRange(location: range.location - start, length: range.length)
        }
        coordinator.onTap = { onTap($0 + start).flatMap(localRange) }
        coordinator.singleClickLookupEnabled = singleClickLookupEnabled
        coordinator.onSelectionChange = { range, hasLetters in
            onSelectionChange(range.map(sourceRange), hasLetters)
        }
        coordinator.onDictionaryLookup = { onDictionaryLookup(sourceRange($0)) }
        coordinator.onModelLookup = { onModelLookup(sourceRange($0)) }
        coordinator.onTranslation = { onTranslation(sourceRange($0)) }
        coordinator.selectionLevel = { selectionLevel(sourceRange($0)) }
        coordinator.onSentenceAnalysis = { onSentenceAnalysis(sourceRange($0)) }
        coordinator.onModelChat = { onModelChat(sourceRange($0)) }
        view.setAccessibilityLabel(singleClickLookupEnabled
            ? "日语正文，单击自动查词，选词可查释义，句段可本地翻译，单句可长句分析，按 ⌘C 复制"
            : "日语正文，选词可查释义，句段可本地翻译，单句可长句分析，按 ⌘C 复制")
        scroll.hasVerticalScroller = pageSize == nil
        scroll.verticalScrollElasticity = pageSize == nil ? .automatic : .none
        view.onPageTurn = pageSize == nil ? nil : onPageTurn
        view.isVerticallyResizable = pageSize == nil
        if let pageSize {
            view.frame.size = pageSize
        }
        if newText || changedSlice {
            coordinator.dismissActions()
            let previousSelection = view.selectedRange()
            let selectedRange = newPage || changedSlice ? NSRange(location: 0, length: 0) : previousSelection
            storage.setAttributedString(coordinator.attributedText.attributedSubstring(from: visible))
            if NSMaxRange(selectedRange) <= storage.length { view.setSelectedRange(selectedRange) }
            coordinator.revision = revision
            coordinator.fontSize = fontSize
            coordinator.selection = nil
            coordinator.searchMatch = nil
            if pageSize != nil, newPage || changedSlice { view.scrollToBeginningOfDocument(nil) }
            if changedSlice && !newPage && previousSelection.length > 0 {
                DispatchQueue.main.async { [weak coordinator, weak view] in
                    guard let coordinator, coordinator.revision == revision, coordinator.visibleRange == visible,
                          view?.selectedRange().length == 0 else { return }
                    coordinator.onSelectionChange(nil, false)
                }
            }
        }
        if pageSize == nil {
            let changedOffset = coordinator.requestedReadingOffset != readingOffset
            if newPage || changedOffset && coordinator.appliedReadingOffset != readingOffset {
                coordinator.restoreScroll(readingOffset, in: scroll, view: view)
            } else if newText {
                coordinator.restoreScroll(coordinator.appliedReadingOffset ?? readingOffset, in: scroll, view: view)
            }
            coordinator.requestedReadingOffset = readingOffset
        }
        let match = searchHighlight.map { NSIntersectionRange($0, visible) }
            .flatMap { $0.length > 0 ? localRange($0) : nil }
        let selection = match ?? selection.flatMap(localRange)
        if coordinator.selection != selection || coordinator.searchMatch != match {
            if let old = coordinator.selection, NSMaxRange(old) <= storage.length { storage.removeAttribute(.backgroundColor, range: old) }
            if let selection, NSMaxRange(selection) <= storage.length {
                storage.addAttribute(.backgroundColor,
                    value: match == nil ? AppTheme.selectionColor : NSColor(calibratedRed: 1, green: 0.86, blue: 0.49, alpha: 1),
                    range: selection)
            }
            coordinator.selection = selection
            coordinator.searchMatch = match
            if let match, pageSize == nil { view.scrollRangeToVisible(match) }
        }
    }
}
