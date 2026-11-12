import AppKit
import SwiftUI

/// Shared by SwiftUI panels and the native reading/split views.
enum AppTheme {
    static let background = Color(red: 253 / 255, green: 252 / 255, blue: 249 / 255)
    static let sidebar = Color(red: 239 / 255, green: 239 / 255, blue: 245 / 255)
    static let surface = Color(red: 247 / 255, green: 246 / 255, blue: 244 / 255)
    static let textColor = NSColor(srgbRed: 39 / 255, green: 40 / 255, blue: 49 / 255, alpha: 1)
    static let accentColor = NSColor(srgbRed: 0.286, green: 0.275, blue: 0.541, alpha: 1)
    static let selectionColor = NSColor(srgbRed: 233 / 255, green: 231 / 255, blue: 247 / 255, alpha: 1)
    static let text = Color(nsColor: textColor)
    static let accent = Color(nsColor: accentColor)
    static let selection = Color(nsColor: selectionColor)
    static let secondary = Color(red: 89 / 255, green: 90 / 255, blue: 107 / 255)
    static let separator = Color(red: 221 / 255, green: 219 / 255, blue: 226 / 255)
    static let interfaceFont = Font.system(size: 14)
    static let captionFont = Font.system(size: 13)
    static let defaultDefinitionSize = 20.0
    static let readingMeasure: CGFloat = 720
    static let readingTopInset: CGFloat = 20
}

struct AppActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    var quiet = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(minWidth: 34, minHeight: 34)
            .foregroundStyle(prominent ? .white : AppTheme.accent)
            .background(prominent ? AppTheme.accent : (quiet && !configuration.isPressed ? .clear : AppTheme.selection),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .opacity(isEnabled ? 1 : 0.48)
            .contentShape(Rectangle())
    }
}

struct AppOptionButtons<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option)).frame(maxWidth: .infinity)
                }
                .buttonStyle(AppActionButtonStyle(prominent: selection == option))
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
