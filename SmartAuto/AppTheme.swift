import SwiftUI

enum AppTheme {
    static let background = Color.black
    static let surface = Color(white: 0.08)
    static let accent = Color.cyan
    static let cornerRadius: CGFloat = 16
}

/// Static placeholders avoid continuous animation and respect Reduce Motion by default.
struct SkeletonBlock: View {
    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            .fill(AppTheme.surface)
            .accessibilityHidden(true)
    }
}
