import SwiftUI

/// The app's visual vocabulary, in one place.
///
/// Tokens rather than literals scattered through views, for the ordinary reason: a chat app is
/// mostly the same six decisions repeated, and repeating them by hand is how a screen ends up
/// almost matching the rest of the app.
enum Theme {
    enum Palette {
        static let userBubble = Color.accentColor
        static let assistantBubble = Color(.secondarySystemBackground)
        static let canvas = Color(.systemBackground)
        static let raised = Color(.secondarySystemBackground)
        static let hairline = Color(.separator)
        static let refusal = Color(.systemOrange)
        static let failure = Color(.systemRed)
        static let success = Color(.systemGreen)
        /// A stage that ran and correctly did nothing. Deliberately the quietest colour on the
        /// screen: a no-op is the most common outcome in any trace, and colouring it as loudly as
        /// a refusal would bury the one row a reader is actually looking for.
        static let neutral = Color.secondary
        /// A deliberate non-run — a capability badge, a stage switched off in Settings. Blue
        /// rather than grey so "you turned this off" does not read as "this quietly did nothing".
        static let informational = Color(.systemBlue)
    }

    enum Spacing {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 6
        static let snug: CGFloat = 10
        static let regular: CGFloat = 16
        static let loose: CGFloat = 24
        static let section: CGFloat = 32
    }

    enum Radius {
        static let bubble: CGFloat = 18
        static let card: CGFloat = 14
        static let chip: CGFloat = 8
    }

    enum Typeface {
        static let title = Font.system(.largeTitle, design: .rounded).weight(.semibold)
        static let heading = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body)
        static let caption = Font.system(.caption)
        /// Monospaced digits so a streaming token counter does not jitter as it climbs.
        static let metric = Font.system(.caption, design: .monospaced)
    }
}

/// A small labelled pill — model name, token count, cost, retry count.
struct MetricChip: View {
    let icon: String?
    let text: String
    var tint: Color

    init(_ text: String, icon: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.hair + 2) {
            if let icon {
                Image(systemName: icon).imageScale(.small)
            }
            Text(text)
        }
        .font(Theme.Typeface.metric)
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.tight)
        .padding(.vertical, Theme.Spacing.hair + 1)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .accessibilityLabel(text)
    }
}

/// The banner a refusal renders as.
///
/// It shows the explanation and, when there is one, the single action that resolves it. A refusal
/// with no route out is still shown — silently swallowing it is the failure mode this whole design
/// exists to avoid — it just does not pretend there is a button.
struct RefusalBanner: View {
    let refusal: Refusal
    let onRecover: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.refusal)
                Text(refusal.headline)
                    .font(Theme.Typeface.heading)
            }
            Text(refusal.explanation)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Naming the stage is not decoration: "Budget reserve" tells a returning user which
            // control changed the outcome, which "something went wrong" never does.
            Text("Stopped at \(refusal.stage.title) · \(refusal.stage.package)")
                .font(Theme.Typeface.metric)
                .foregroundStyle(.tertiary)

            if let title = refusal.recoveryTitle, let onRecover {
                Button(title, action: onRecover)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, Theme.Spacing.hair)
            }
        }
        .padding(Theme.Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Palette.refusal.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Palette.refusal.opacity(0.35))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("refusalBanner")
    }
}
