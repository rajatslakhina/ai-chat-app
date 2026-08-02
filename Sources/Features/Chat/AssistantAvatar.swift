import SwiftUI

/// The assistant's face.
///
/// Drawn rather than an image asset so it scales with the bubble and needs no `@2x`/`@3x` set, and
/// gradient-filled from the same two colours as the app icon so the mark reads as one product
/// rather than as two unrelated blue circles.
struct AssistantAvatar: View {
    var diameter: CGFloat = 28

    /// The icon's gradient. Written as literal components rather than `Color.accentColor` on
    /// purpose: the accent is still the system default until the global accent build setting is
    /// set, so reading it here would quietly make the avatar a different blue from the icon.
    private static let top = Color(red: 0.290, green: 0.478, blue: 0.910)
    private static let bottom = Color(red: 0.227, green: 0.149, blue: 0.580)

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Self.top, Self.bottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sparkles")
                .font(.system(size: diameter * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityIdentifier("assistantAvatar")
    }
}
