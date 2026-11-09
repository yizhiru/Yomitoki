import AppKit
import SwiftUI

enum SavedSplitEdge { case leading, trailing }

/// Stores the user's preferred width separately from the width that fits today.
/// Shrinking a window must not overwrite the preference with a clamped value.
final class SplitWidthStore {
    let key: String
    private let defaults: UserDefaults
    private(set) var preferredWidth: CGFloat

    init(identifier: String, idealWidth: CGFloat, defaults: UserDefaults = .standard) {
        key = "splitWidth." + identifier
        self.defaults = defaults
        let saved = (defaults.object(forKey: key) as? NSNumber).map { CGFloat(truncating: $0) }
        preferredWidth = saved.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? idealWidth
    }

    func fittedWidth(available: CGFloat, minimum: CGFloat, maximum: CGFloat, otherMinimum: CGFloat) -> CGFloat {
        let limit = max(0, available - otherMinimum)
        return min(limit, maximum, max(minimum, preferredWidth))
    }

    func remember(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        preferredWidth = width
        defaults.set(Double(width), forKey: key)
    }
}

final class RememberingSplitView: NSSplitView {
    var onLayout: () -> Void = {}
    var onDragFinished: () -> Void = {}
    private(set) var draggingDivider = false

    override func layout() {
        super.layout()
        onLayout()
    }

    override func mouseDown(with event: NSEvent) {
        draggingDivider = true
        super.mouseDown(with: event)
        draggingDivider = false
        onDragFinished()
    }
}

struct PersistedHSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let identifier: String
    var savedEdge = SavedSplitEdge.leading
    let minimumWidth: CGFloat
    let idealWidth: CGFloat
    let maximumWidth: CGFloat
    let otherMinimumWidth: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    final class Coordinator: NSObject, NSSplitViewDelegate {
        let width: SplitWidthStore
        let edge: SavedSplitEdge
        let minimum: CGFloat
        let maximum: CGFloat
        let otherMinimum: CGFloat
        let leading: NSHostingView<AnyView>
        let trailing: NSHostingView<AnyView>
        private var applying = false

        init(_ owner: PersistedHSplitView) {
            width = SplitWidthStore(identifier: owner.identifier, idealWidth: owner.idealWidth)
            edge = owner.savedEdge
            minimum = owner.minimumWidth
            maximum = owner.maximumWidth
            otherMinimum = owner.otherMinimumWidth
            leading = NSHostingView(rootView: Self.content(owner.leading()))
            trailing = NSHostingView(rootView: Self.content(owner.trailing()))
            super.init()
            // The split view owns sizing; SwiftUI content fills the assigned panes.
            leading.sizingOptions = []
            trailing.sizingOptions = []
        }

        static func content<V: View>(_ view: V) -> AnyView {
            AnyView(view.frame(maxWidth: .infinity, maxHeight: .infinity)
                .font(AppTheme.interfaceFont).tint(AppTheme.accent)
                .foregroundStyle(AppTheme.text)
                .environment(\.colorScheme, .light))
        }

        func layout(_ split: RememberingSplitView) {
            guard !applying, split.subviews.count == 2, split.bounds.width > 0 else { return }
            applying = true
            defer { applying = false }
            let available = max(0, split.bounds.width - split.dividerThickness)
            let fixed: CGFloat
            if split.draggingDivider {
                fixed = edge == .leading ? leading.frame.width : trailing.frame.width
            } else {
                fixed = width.fittedWidth(available: available, minimum: minimum,
                                          maximum: maximum, otherMinimum: otherMinimum)
            }
            let firstWidth = edge == .leading ? fixed : max(0, available - fixed)
            let first = NSRect(x: 0, y: 0, width: firstWidth, height: split.bounds.height)
            let second = NSRect(x: firstWidth + split.dividerThickness, y: 0,
                                width: max(0, available - firstWidth), height: split.bounds.height)
            if leading.frame != first { leading.frame = first }
            if trailing.frame != second { trailing.frame = second }
        }

        func rememberWidth() {
            width.remember(edge == .leading ? leading.frame.width : trailing.frame.width)
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            if let split = splitView as? RememberingSplitView { layout(split) }
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            let available = max(0, splitView.bounds.width - splitView.dividerThickness)
            return edge == .leading ? min(minimum, max(0, available - otherMinimum))
                : max(otherMinimum, available - maximum)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            let available = max(0, splitView.bounds.width - splitView.dividerThickness)
            return edge == .leading ? min(maximum, max(0, available - otherMinimum))
                : max(0, available - minimum)
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RememberingSplitView {
        let split = RememberingSplitView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.addArrangedSubview(context.coordinator.leading)
        split.addArrangedSubview(context.coordinator.trailing)
        split.onLayout = { [weak split, weak coordinator = context.coordinator] in
            if let split { coordinator?.layout(split) }
        }
        split.onDragFinished = { [weak coordinator = context.coordinator] in coordinator?.rememberWidth() }
        context.coordinator.layout(split)
        return split
    }

    func updateNSView(_ split: RememberingSplitView, context: Context) {
        context.coordinator.leading.rootView = Coordinator.content(leading())
        context.coordinator.trailing.rootView = Coordinator.content(trailing())
        context.coordinator.layout(split)
    }
}
