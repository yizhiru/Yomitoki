import AppKit
import SwiftUI

/// Shared by SwiftUI panels and the native reading/split views.
enum AppTheme {
    static let background = Color.white
    static let sidebar = Color(red: 0.965, green: 0.969, blue: 0.976)
    static let surface = Color(red: 0.972, green: 0.976, blue: 0.982)
    static let textColor = NSColor(calibratedRed: 0.145, green: 0.157, blue: 0.173, alpha: 1)
    static let accentColor = NSColor(calibratedRed: 0.286, green: 0.384, blue: 0.478, alpha: 1)
    static let selectionColor = NSColor(calibratedRed: 0.914, green: 0.933, blue: 0.953, alpha: 1)
    static let text = Color(nsColor: textColor)
    static let accent = Color(nsColor: accentColor)
    static let selection = Color(nsColor: selectionColor)
    static let secondary = Color(red: 0.392, green: 0.420, blue: 0.455)
    static let separator = Color(red: 0.894, green: 0.906, blue: 0.922)
    static let interfaceFont = Font.system(size: 14)
    static let captionFont = Font.system(size: 13)
    static let defaultDefinitionSize = 20.0
}
