import SwiftUI

// The Android app's DesignKit.kt in SwiftUI: its cards, rows, tiles and pills, drawn on the
// system grouped backgrounds with system controls, Dynamic Type text styles and SF Symbols.
// Every label is a LocalizedStringKey so it lands in the String Catalog; runtime data goes in
// as a Text built with Text(verbatim:) by the caller.

// MARK: - Cards

private struct CardStyle: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .clipShape(shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color(.separator), lineWidth: 1)
                }
            }
    }
}

extension View {
    /// Android's PremiumCard: 18pt corners on the grouped background, no shadow.
    func cardStyle(padding: CGFloat = 16) -> some View {
        modifier(CardStyle(padding: padding))
    }

    /// For screenshots of long pages in Debug builds: -ld.scroll 0.5 starts a scroll view
    /// halfway, 1 at its end.
    @ViewBuilder
    func screenshotScrollAnchor() -> some View {
        #if DEBUG
        if let position = UserDefaults.standard.object(forKey: "ld.scroll") as? String, let value = Double(position) {
            defaultScrollAnchor(UnitPoint(x: 0.5, y: value))
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// A centred column on iPad and in landscape, full width on a phone.
    func readableWidth() -> some View {
        frame(maxWidth: 700).frame(maxWidth: .infinity)
    }
}

/// Rows in one card, like Android's GroupCard. Put a `CardDivider` between them.
struct CardGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .cardStyle(padding: 0)
    }
}

/// A hairline that starts where the row text starts, as in iOS Settings.
struct CardDivider: View {
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 36

    var body: some View {
        Divider().padding(.leading, 16 + min(tile, 56) + 12)
    }
}

// MARK: - Rows

/// The tinted square behind a row's symbol.
struct IconTile: View {
    let systemName: String
    var tint: Color = Brand.green
    var ink: Color = Brand.ink

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 36
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let size = min(side, 56)
        RoundedRectangle(cornerRadius: Brand.tileRadius, style: .continuous)
            .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(ink)
            }
            .accessibilityHidden(true)
    }
}

/// Android's SettingRow: icon tile, bold title, a subtitle that carries the state, and a
/// trailing control.
struct SettingRow<Trailing: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var subtitle: Text?
    var subtitleColor: Color = .secondary
    var tint: Color = Brand.green
    var ink: Color = Brand.ink
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: systemImage, tint: tint, ink: ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    subtitle
                        .font(.footnote)
                        .foregroundStyle(subtitleColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 44)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        subtitle: Text? = nil,
        subtitleColor: Color = .secondary,
        tint: Color = Brand.green,
        ink: Color = Brand.ink
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            subtitle: subtitle,
            subtitleColor: subtitleColor,
            tint: tint,
            ink: ink,
            trailing: { EmptyView() }
        )
    }
}

/// A row that folds its settings open in place, like Android's ExpandableRow.
struct ExpandableRow<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var subtitle: Text?
    var subtitleColor: Color = .secondary
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.snappy) { isExpanded.toggle() }
                }
            } label: {
                SettingRow(title: title, systemImage: systemImage, subtitle: subtitle, subtitleColor: subtitleColor) {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(isExpanded ? Text("Collapse") : Text("Expand"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A small heading inside an expanded row.
struct RowSubheading: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A value in a list inside a row (a webhook URL, a header), with a remove button.
struct ListLine<Content: View>: View {
    let removeLabel: Text
    let onRemove: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.vertical, 8)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.errorInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(removeLabel)
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Android's FilledField: a filled, borderless text field.
struct FilledFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension TextFieldStyle where Self == FilledFieldStyle {
    static var filled: FilledFieldStyle { FilledFieldStyle() }
}

// MARK: - Header

/// Android's StatusBanner: a green gradient card with the state of the tab and one action.
/// Text is the dark ink on green (6.97:1); Android's white would be 2.56:1.
struct StatusHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: Text
    @ViewBuilder var trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                subtitle
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .foregroundStyle(Brand.onGreen)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Brand.green, Color(BrandTone(0x6ACBA2))],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
        )
    }
}

/// The action on a StatusHeader: a light capsule on the green.
struct HeaderChip: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.onGreen)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.35), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Buttons

/// Android's PrimaryPill: the full-width green capsule for Sync Now, with dark ink on green.
/// Not `.borderedProminent`, which puts white text on the green.
struct PrimaryButtonStyle: ButtonStyle {
    var isBusy = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().tint(Brand.onGreen)
            }
            configuration.label
        }
        .font(.headline)
        .foregroundStyle(Brand.onGreen.opacity(isEnabled ? 1 : 0.55))
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(Brand.green.opacity(isEnabled ? 1 : 0.35), in: Capsule())
        .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The inside of an action tile, shared by `ActionTile` and a tile that opens a menu.
struct ActionTileLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var ink: Color = Brand.ink
    var isBusy = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 6))
        layout {
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(ink)
                }
            }
            .frame(minHeight: 24)
            .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Brand.actionTileRadius, style: .continuous)
        )
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

/// Android's ActionTile: a symbol over a short label.
struct ActionTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    var ink: Color = Brand.ink
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionTileLabel(title: title, systemImage: systemImage, ink: ink, isBusy: isBusy)
        }
        .buttonStyle(.plain)
    }
}

/// Tiles side by side, one under the other at the accessibility text sizes.
struct ActionTileRow<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            content
        }
    }
}

// MARK: - Status

/// What a status says, for the pill, the notice and a result line: always a word too, so the
/// colour is never the only signal.
enum StatusTone {
    case success, failure, warning, info

    var ink: Color {
        switch self {
        case .success: return Brand.successInk
        case .failure: return Brand.errorInk
        case .warning: return Brand.warningInk
        case .info: return Brand.logsInk
        }
    }

    var container: Color {
        switch self {
        case .success: return Color(BrandTone.successContainer)
        case .failure: return Color(BrandTone.errorContainer)
        case .warning: return Color(BrandTone.warningContainer)
        case .info: return Color(BrandTone.logsContainer)
        }
    }

    var onContainer: Color {
        switch self {
        case .success: return Color(BrandTone.onSuccessContainer)
        case .failure: return Color(BrandTone.onErrorContainer)
        case .warning: return Color(BrandTone.onWarningContainer)
        case .info: return Color(BrandTone.onLogsContainer)
        }
    }

    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// Android's StatusPill: "Delivered", "Failed" in a coloured capsule.
struct StatusPill: View {
    let title: LocalizedStringKey
    let tone: StatusTone

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone.onContainer)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tone.container, in: Capsule())
            .fixedSize()
    }
}

/// A coloured note with a symbol, and an optional action at the end.
struct NoticeBanner<Trailing: View>: View {
    let text: Text
    let tone: StatusTone
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tone.systemImage)
                .accessibilityHidden(true)
            text
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .foregroundStyle(tone.onContainer)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tone.container, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A result under a button: symbol and text in the tone's ink.
struct ResultLine: View {
    let text: Text
    let tone: StatusTone

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: tone.systemImage)
        }
        .font(.footnote)
        .foregroundStyle(tone.ink)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}
