import SwiftUI

/// Shared visual language: a dark terminal surface with one cool accent.
enum Theme {
    static let accent = Color(red: 0.31, green: 0.55, blue: 1.00)
    static let accentAlt = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let background = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let surface = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let surfaceRaised = Color(red: 0.12, green: 0.14, blue: 0.18)
    static let border = Color(white: 1.0).opacity(0.08)
    static let textPrimary = Color(white: 0.95)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.42)
    static let danger = Color(red: 0.98, green: 0.37, blue: 0.36)
    static let success = Color(red: 0.26, green: 0.85, blue: 0.55)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.30)

    static let accentGradient = LinearGradient(
        colors: [accent, accentAlt],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cornerRadius: CGFloat = 16
}

// MARK: - Building blocks

/// A raised panel with a hairline border.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

/// A section heading above a group of controls.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .kerning(1.2)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A filled primary action.
struct PrimaryButtonStyle: ButtonStyle {
    var isEnabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accentGradient)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

/// A small coloured status dot with a glow.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.8), radius: 4)
    }
}

/// Inline error, dismissible by the caller.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
