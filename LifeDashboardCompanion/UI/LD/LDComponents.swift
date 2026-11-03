import SwiftUI

// The building blocks of gen_all.py (branch P == 'i') in SwiftUI. Each one carries its own outer
// margins, as on the boards, so a screen stacks them in LDScreen without extra padding. Labels
// are LocalizedStringKey so they land in the String Catalog; runtime data goes in as a Text
// built with Text(verbatim:) by the caller.

// MARK: - Screen

/// The ground of every screen. Content starts at the top. `pinned` sits at the bottom above the
/// tab bar while everything fits, and scrolls along once Dynamic Type makes it taller, so nothing
/// clips. `footer` stays fixed under the scrolling part, as in the Preview sheet and onboarding.
/// A Spacer in `content` does nothing: what belongs at the bottom goes in `pinned`.
struct LDScreen<Content: View, Pinned: View, Footer: View>: View {
    private let background: Color
    private let content: Content
    private let pinned: Pinned
    private let footer: Footer

    init(
        background: Color = LDTheme.ground,
        @ViewBuilder content: () -> Content,
        @ViewBuilder pinned: () -> Pinned,
        @ViewBuilder footer: () -> Footer
    ) {
        self.background = background
        self.content = content()
        self.pinned = pinned()
        self.footer = footer()
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                LDPinnedLayout(minHeight: viewport.size.height) {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Pinned.self == EmptyView.self ? 16 : 0)

                    VStack(spacing: 0) {
                        pinned
                    }
                }
                .frame(maxWidth: LDTheme.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .screenshotScrollAnchor()
        }
        // The number pad has no return key of its own to leave a field with.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // In a stack: an EmptyView on its own takes the whole height here, which leaves the
            // viewport 0 high, and `pinned` would no longer pin.
            VStack(spacing: 0) {
                footer
            }
        }
        .background(background.ignoresSafeArea())
    }
}

extension LDScreen where Pinned == EmptyView, Footer == EmptyView {
    init(background: Color = LDTheme.ground, @ViewBuilder content: () -> Content) {
        self.init(background: background, content: content, pinned: { EmptyView() }, footer: { EmptyView() })
    }
}

extension LDScreen where Footer == EmptyView {
    init(background: Color = LDTheme.ground, @ViewBuilder content: () -> Content, @ViewBuilder pinned: () -> Pinned) {
        self.init(background: background, content: content, pinned: pinned, footer: { EmptyView() })
    }
}

extension LDScreen where Pinned == EmptyView {
    init(background: Color = LDTheme.ground, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(background: background, content: content, pinned: { EmptyView() }, footer: footer)
    }
}

private extension View {
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
}

/// The content at the top and the pinned part at the bottom, at least `minHeight` tall. A VStack with
/// a Spacer under `.frame(minHeight:)` gets a fixed height to share out, and shortens text as soon as
/// it does not fit. Here both parts always get the height they ask for, so nothing is cut off and the
/// scroll view takes over.
struct LDPinnedLayout: Layout {
    var minHeight: CGFloat

    private func heights(_ subviews: Subviews, width: CGFloat?) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0,
            height: max(minHeight, heights(subviews, width: proposal.width).reduce(0, +))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = heights(subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let isLast = index == subviews.count - 1 && index > 0
            let top = isLast ? bounds.maxY - sizes[index] : bounds.minY + sizes[..<index].reduce(0, +)
            subview.place(
                at: CGPoint(x: bounds.minX, y: top),
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }
}

/// The buttons under a screen, with the hairline above them. Goes in LDScreen's `footer`; give
/// its LDButtons `inset: 0`.
struct LDFooterBar<Content: View>: View {
    var background: Color = LDTheme.ground
    @ViewBuilder let content: Content

    var body: some View {
        LDFooterLayout(spacing: 8) {
            content
        }
        .padding(.top, 10)
        .padding(.horizontal, LDTheme.cardInset)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            LDHairline()
        }
        .background(background)
    }
}

/// The buttons of LDFooterBar: equal widths while every label fits on one line that way, otherwise
/// in proportion to their labels, otherwise on more lines that each fill the width. So a label only
/// wraps when it is wider than the whole bar, in any language and at any text size.
struct LDFooterLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = idealWidths(subviews)
        let natural = ideal.reduce(0, +) + spacing * CGFloat(max(0, ideal.count - 1))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let lines = Self.lines(ideal: ideal, width: width, spacing: spacing)
        let height = lines.reduce(0) { $0 + lineHeight($1, subviews) } + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for line in Self.lines(ideal: idealWidths(subviews), width: bounds.width, spacing: spacing) {
            let height = lineHeight(line, subviews)
            var leading = bounds.minX
            for (index, width) in line {
                subviews[index].place(
                    at: CGPoint(x: leading, y: top),
                    proposal: ProposedViewSize(width: width, height: height)
                )
                leading += width + spacing
            }
            top += height + spacing
        }
    }

    private func idealWidths(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { ceil($0.sizeThatFits(.unspecified).width) }
    }

    private func lineHeight(_ line: [(index: Int, width: CGFloat)], _ subviews: Subviews) -> CGFloat {
        line.map { subviews[$0.index].sizeThatFits(ProposedViewSize(width: $0.width, height: nil)).height }.max() ?? 0
    }

    /// Which button goes on which line, at what width. Apart from the layout so a test can hold it.
    static func lines(ideal: [CGFloat], width: CGFloat, spacing: CGFloat) -> [[(index: Int, width: CGFloat)]] {
        var lines: [[(index: Int, width: CGFloat)]] = []
        var start = 0
        while start < ideal.count {
            var end = start + 1
            var used = ideal[start]
            while end < ideal.count, used + spacing + ideal[end] <= width {
                used += spacing + ideal[end]
                end += 1
            }
            let count = CGFloat(end - start)
            let room = width - spacing * (count - 1)
            let equal = room / count
            let isEqual = ideal[start..<end].allSatisfy { $0 <= equal }
            let share = (room - ideal[start..<end].reduce(0, +)) / count
            lines.append((start..<end).map { (index: $0, width: isEqual ? equal : ideal[$0] + share) })
            start = end
        }
        return lines
    }
}

// MARK: - Text

extension View {
    /// For what is code whatever the language: JSON, addresses, topics, header names. It reads left
    /// to right against the left edge, also on a screen that runs right to left.
    func ldCode() -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight)
    }
}

extension String {
    /// For a Text with " · " in it: the dot stays with the word before it when the line wraps. Where
    /// a word and its dot can be wider than the line, as in a narrow column at the largest text
    /// sizes, use LDSeparatedText.
    var ldKeepingSeparators: String {
        replacingOccurrences(of: " · ", with: "\u{00A0}· ")
    }
}

/// Text with " · " between its parts, in the font and colour around it. A dot only stands between
/// two parts on the same line, so no line starts or ends with one, in any language or at any text size.
struct LDSeparatedText: View {
    private let parts: [String]

    // Padding, not spaces around the dot: spaces shift it towards the word before it in Arabic.
    @ScaledMetric(relativeTo: .footnote) private var dotPadding: CGFloat = 7

    init(_ text: String) {
        parts = text.components(separatedBy: " · ")
    }

    var body: some View {
        LDSeparatedLayout {
            ForEach(parts.indices, id: \.self) { index in
                if index > 0 {
                    Text(verbatim: "·")
                        .padding(.horizontal, dotPadding)
                        .accessibilityHidden(true)
                }
                Text(verbatim: parts[index])
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The subviews of LDSeparatedText: part, dot, part, dot, part.
struct LDSeparatedLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let parts = partWidths(subviews, width: width)
        let lines = Self.lines(parts: parts, dot: dotWidth(subviews), width: width)
        var size = CGSize.zero
        for line in lines {
            let used = line.reduce(0) { $0 + parts[$1] } + dotWidth(subviews) * CGFloat(line.count - 1)
            size.width = max(size.width, used)
            size.height += lineHeight(line, parts, subviews)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = partWidths(subviews, width: bounds.width)
        let dot = dotWidth(subviews)
        // A dot at a line break has no place: it goes out of sight.
        for index in subviews.indices where index % 2 == 1 {
            subviews[index].place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), proposal: .unspecified)
        }
        var top = bounds.minY
        for line in Self.lines(parts: parts, dot: dot, width: bounds.width) {
            var leading = bounds.minX
            for part in line {
                if part != line[0] {
                    subviews[part * 2 - 1].place(at: CGPoint(x: leading, y: top), proposal: .unspecified)
                    leading += dot
                }
                subviews[part * 2].place(
                    at: CGPoint(x: leading, y: top),
                    proposal: ProposedViewSize(width: parts[part], height: nil)
                )
                leading += parts[part]
            }
            top += lineHeight(line, parts, subviews)
        }
    }

    /// A part wider than the line gets the line, and wraps inside it.
    private func partWidths(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: 2).map {
            min(width, ceil(subviews[$0].sizeThatFits(.unspecified).width))
        }
    }

    private func dotWidth(_ subviews: Subviews) -> CGFloat {
        subviews.count > 1 ? ceil(subviews[1].sizeThatFits(.unspecified).width) : 0
    }

    private func lineHeight(_ line: [Int], _ parts: [CGFloat], _ subviews: Subviews) -> CGFloat {
        line.map { subviews[$0 * 2].sizeThatFits(ProposedViewSize(width: parts[$0], height: nil)).height }.max() ?? 0
    }

    /// Which part goes on which line. Apart from the layout so a test can hold it.
    static func lines(parts: [CGFloat], dot: CGFloat, width: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var used: CGFloat = 0
        for (index, part) in parts.enumerated() {
            if let last = lines.indices.last, used + dot + part <= width {
                lines[last].append(index)
                used += dot + part
            } else {
                lines.append([index])
                used = part
            }
        }
        return lines
    }
}

/// The large heading: 30/34 bold. Its natural line height is 38, so 2 points are taken off above
/// and below to keep the first baseline where the board has it. Further lines are 4 points taller.
struct LDHeading: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(LDType.heading)
            .tracking(-0.5)
            .foregroundStyle(LDTheme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.horizontal, LDTheme.textInset)
            .padding(.bottom, -2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The small label above a card.
struct LDSectionLabel: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(LDType.sectionLabel)
            .foregroundStyle(LDTheme.muted)
            .lineSpacing(LDType.lineSpacing(size: 14, lineHeight: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.horizontal, LDTheme.textInset)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A line of body text. `size` is 14 by default; the boards also use 13 for footnotes and 16.
struct LDNote: View {
    private let text: Text
    private let color: Color
    private let top: CGFloat
    private let size: CGFloat

    init(_ key: LocalizedStringKey, color: Color = LDTheme.secondary, top: CGFloat = 8, size: CGFloat = 14) {
        self.init(Text(key), color: color, top: top, size: size)
    }

    init(_ text: Text, color: Color = LDTheme.secondary, top: CGFloat = 8, size: CGFloat = 14) {
        self.text = text
        self.color = color
        self.top = top
        self.size = size
    }

    var body: some View {
        text
            .font(LDType.sans(size, relativeTo: size >= 16 ? .callout : size <= 13 ? .footnote : .subheadline))
            .foregroundStyle(color)
            .lineSpacing(LDType.lineSpacing(size: size, lineHeight: size + 6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, top)
            .padding(.horizontal, LDTheme.textInset)
    }
}

/// Fixed vertical space between blocks: `sp(n)` on the boards.
struct LDGap: View {
    let height: CGFloat

    init(_ height: CGFloat) { self.height = height }

    var body: some View {
        Color.clear.frame(height: height).accessibilityHidden(true)
    }
}

// MARK: - Lines

/// The line between rows in a card.
struct LDDivider: View {
    var body: some View {
        LDTheme.divider.frame(height: 1).accessibilityHidden(true)
    }
}

/// The fainter line above a footer and between log rows.
struct LDHairline: View {
    var body: some View {
        LDTheme.hairline.frame(height: 1).accessibilityHidden(true)
    }
}

/// The trailing chevron, following the reading direction.
struct LDChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(LDTheme.muted)
            .accessibilityHidden(true)
    }
}

// MARK: - Press

/// Dims on press and leaves the colours alone: the style for anything tappable that draws itself.
/// A disabled one is dimmed too, as LDButton is.
struct LDPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LDPressBody(configuration: configuration)
    }
}

private struct LDPressBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == LDPressStyle {
    static var ldPress: LDPressStyle { LDPressStyle() }
}

extension View {
    /// Makes a row, tile or destination row push a route on the tab it is on.
    func ldLink(to route: LDRoute) -> some View {
        NavigationLink(value: route) { self }.buttonStyle(.ldPress)
    }

    /// Makes a row, tile or destination row a button.
    func ldButton(action: @escaping () -> Void) -> some View {
        Button(action: action) { self }.buttonStyle(.ldPress)
    }
}

// MARK: - Cards

/// Rows on a tile surface with a line between them. Conditions and ForEach in the content count
/// row by row, so a hidden row never leaves a stray line. `bottom` is space below the card.
struct LDCard<Content: View>: View {
    private let bottom: CGFloat
    private let content: Content

    init(bottom: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.bottom = bottom
        self.content = content()
    }

    var body: some View {
        // Group(subviews:) needs iOS 18; the app supports 17.
        _VariadicView.Tree(LDCardRows()) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ldSurface(radius: LDTheme.cardRadius)
            .padding(.horizontal, LDTheme.cardInset)
            .padding(.bottom, bottom)
    }
}

private struct LDCardRows: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let last = children.last?.id
            ForEach(children) { child in
                child
                if child.id != last {
                    LDDivider()
                }
            }
        }
    }
}

private extension View {
    /// The tile fill, its border and its corners.
    func ldSurface(radius: CGFloat, border: Color = LDTheme.tileBorder) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(LDTheme.tile, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(border, lineWidth: 1) }
    }
}

// MARK: - Rows

/// A row in a card: name, optional subtitle, optional value and a chevron. It draws only; make it
/// tappable with `.ldLink(to:)`, `.ldButton {}`, or put it in your own Link with `.buttonStyle(.ldPress)`.
/// With `showsChevron: false` it is the boards' plain row. `trailing` holds a control or a spinner,
/// in place of the value and the chevron.
struct LDRow: View {
    private let title: Text
    private let subtitle: Text?
    private let value: Text?
    private let valueColor: Color
    private let showsChevron: Bool
    // A stored view, not a generic: AboutLinkRow and others keep an LDRow in a property.
    private let trailing: AnyView?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        _ title: LocalizedStringKey,
        subtitle: Text? = nil,
        value: Text? = nil,
        valueColor: Color = LDTheme.muted,
        showsChevron: Bool = true
    ) {
        self.init(Text(title), subtitle: subtitle, value: value, valueColor: valueColor, showsChevron: showsChevron)
    }

    init(
        _ title: Text,
        subtitle: Text? = nil,
        value: Text? = nil,
        valueColor: Color = LDTheme.muted,
        showsChevron: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.valueColor = valueColor
        self.showsChevron = showsChevron
        self.trailing = nil
    }

    init<Trailing: View>(
        _ title: LocalizedStringKey,
        subtitle: Text? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = Text(title)
        self.subtitle = subtitle
        self.value = nil
        self.valueColor = LDTheme.muted
        self.showsChevron = false
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(LDType.row)
                    .foregroundStyle(LDTheme.text)
                if let subtitle {
                    subtitle
                        .font(LDType.rowSubtitle)
                        .foregroundStyle(LDTheme.muted)
                        .lineSpacing(LDType.lineSpacing(size: 13, lineHeight: 18))
                }
                // Under the name at the accessibility text sizes: side by side, both break mid-word.
                if let value, dynamicTypeSize.isAccessibilitySize {
                    value
                        .font(LDType.value)
                        .foregroundStyle(valueColor)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let value, !dynamicTypeSize.isAccessibilitySize {
                value
                    .font(LDType.value)
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
            }
            if let trailing {
                trailing
            }
            if showsChevron {
                LDChevron()
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(minHeight: subtitle == nil ? 50 : 62)
        .contentShape(Rectangle())
        // A control in `trailing` has to stay reachable on its own.
        .accessibilityElement(children: trailing == nil ? .combine : .contain)
    }
}

/// A row with a system switch in the accent colour.
struct LDToggleRow: View {
    private let title: Text
    private let subtitle: Text?
    @Binding private var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: Text? = nil, isOn: Binding<Bool>) {
        self.init(Text(title), subtitle: subtitle, isOn: isOn)
    }

    init(_ title: Text, subtitle: Text? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(LDType.row)
                    .foregroundStyle(LDTheme.text)
                if let subtitle {
                    subtitle
                        .font(LDType.rowSubtitle)
                        .foregroundStyle(LDTheme.muted)
                        .lineSpacing(LDType.lineSpacing(size: 13, lineHeight: 18))
                }
            }
        }
        .tint(LDTheme.accent)
        .padding(.vertical, 6)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(minHeight: 50)
    }
}

/// A small label over an editable value, Space Mono by default. `trailing` holds a control such as
/// a reveal button. Keyboard modifiers (`.keyboardType`, `.textInputAutocapitalization`) go on the
/// row from outside. `init(_:value:)` shows a value that cannot be edited. `prompt` is text to
/// translate; `verbatimPrompt` is an example such as an address or a number, which stays out of
/// the String Catalog and out of Markdown.
struct LDFieldRow<Trailing: View>: View {
    private let label: LocalizedStringKey
    private let text: Binding<String>?
    private let value: Text?
    private let promptText: Text?
    private let mono: Bool
    private let isSecure: Bool
    private let isCode: Bool
    private let codePrompt: String?
    private let trailing: Trailing

    @Environment(\.layoutDirection) private var layoutDirection

    /// `isCode: false` is for a field that takes words or a plain number, which follow the language.
    init(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        prompt: LocalizedStringKey? = nil,
        verbatimPrompt: String? = nil,
        mono: Bool = true,
        isSecure: Bool = false,
        isCode: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.label = label
        self.text = text
        self.value = nil
        // Empty rather than nil, or the field repeats the label above it as its placeholder.
        self.promptText = (verbatimPrompt.map { Text(verbatim: $0) } ?? prompt.map { Text($0) } ?? Text(verbatim: ""))
            .foregroundColor(LDTheme.muted)
        self.mono = mono
        self.isSecure = isSecure
        self.isCode = isCode
        self.codePrompt = isCode ? verbatimPrompt : nil
        self.trailing = trailing()
    }

    private var font: Font {
        mono ? LDType.monoField : LDType.value
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(LDType.rowSubtitle)
                    .foregroundStyle(LDTheme.muted)
                    // The field below carries this label itself; VoiceOver would say it twice.
                    .accessibilityHidden(text != nil)
                if let text {
                    // A field keeps its prompt on the side of the language, whatever the direction it
                    // is given. An example address is code too, so on a right-to-left screen it is drawn here.
                    let drawnPrompt = layoutDirection == .rightToLeft ? codePrompt : nil
                    Group {
                        if isSecure {
                            SecureField(label, text: text, prompt: drawnPrompt == nil ? promptText : Text(verbatim: ""))
                        } else {
                            TextField(label, text: text, prompt: drawnPrompt == nil ? promptText : Text(verbatim: ""))
                        }
                    }
                    .font(font)
                    .foregroundStyle(LDTheme.text)
                    .tint(LDTheme.accent)
                    // With a prompt of its own a field no longer takes its name from the title above.
                    .accessibilityLabel(Text(label))
                    .overlay(alignment: .leading) {
                        if let drawnPrompt, text.wrappedValue.isEmpty {
                            Text(verbatim: drawnPrompt)
                                .font(font)
                                .foregroundStyle(LDTheme.muted)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityHint(drawnPrompt != nil && text.wrappedValue.isEmpty ? Text(verbatim: drawnPrompt ?? "") : Text(verbatim: ""))
                    .environment(\.layoutDirection, isCode ? .leftToRight : layoutDirection)
                } else if let value {
                    value
                        .font(font)
                        .foregroundStyle(LDTheme.text)
                        .ldCode()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        // A value that cannot be edited reads with its label; a field and a reveal button stay apart.
        .accessibilityElement(children: text == nil ? .combine : .contain)
    }
}

extension LDFieldRow where Trailing == EmptyView {
    init(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        prompt: LocalizedStringKey? = nil,
        verbatimPrompt: String? = nil,
        mono: Bool = true,
        isSecure: Bool = false,
        isCode: Bool = true
    ) {
        self.init(label, text: text, prompt: prompt, verbatimPrompt: verbatimPrompt, mono: mono, isSecure: isSecure, isCode: isCode) { EmptyView() }
    }

    init(_ label: LocalizedStringKey, value: Text, mono: Bool = true) {
        self.label = label
        self.text = nil
        self.value = value
        self.promptText = nil
        self.mono = mono
        self.isSecure = false
        self.isCode = true
        self.codePrompt = nil
        self.trailing = EmptyView()
    }
}

/// A destination on Home: name, status in the soft accent (or `statusColor` for a problem) and a
/// chevron, full width. It draws only, like LDRow. Name and status go under each other when they do
/// not fit side by side, so a large text size never breaks a word in two.
struct LDDestinationRow: View {
    private let name: Text
    private let status: Text
    private let statusColor: Color

    init(_ name: Text, status: Text, statusColor: Color = LDTheme.accentTextSoft) {
        self.name = name
        self.status = status
        self.statusColor = statusColor
    }

    var body: some View {
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    styledName
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    styledStatus
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // One line, smaller if it must: a host name has nowhere to break but mid-word.
                    styledName
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .truncationMode(.middle)
                    styledStatus
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LDChevron()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, LDTheme.textInset)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var styledName: some View {
        name
            .font(LDType.destination)
            .foregroundStyle(LDTheme.text)
    }

    private var styledStatus: some View {
        status
            .font(LDType.destinationStatus)
            .foregroundStyle(statusColor)
    }
}

// MARK: - Segments and chips

/// One choice in LDSegmented.
struct LDSegment<Value: Hashable> {
    let value: Value
    let title: Text

    init(_ value: Value, _ title: LocalizedStringKey) {
        self.value = value
        self.title = Text(title)
    }

    init(_ value: Value, title: Text) {
        self.value = value
        self.title = title
    }
}

/// The boards' segmented control. Each segment is a real button, 44 high with its 38 high pill.
struct LDSegmented<Value: Hashable>: View {
    @Binding private var selection: Value
    private let segments: [LDSegment<Value>]
    private let label: LocalizedStringKey?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `label` is what VoiceOver calls the group: the boards have no visible title on some.
    init(selection: Binding<Value>, segments: [LDSegment<Value>], label: LocalizedStringKey? = nil) {
        _selection = selection
        self.segments = segments
        self.label = label
    }

    var body: some View {
        Group {
            // Under each other at the accessibility text sizes when side by side a word would break.
            if dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) { buttons }
                    VStack(spacing: 2) { buttons }
                }
            } else {
                HStack(spacing: 2) { buttons }
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .ldSurface(radius: 12)
        .padding(.horizontal, LDTheme.cardInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: ""))
    }

    private var buttons: some View {
        ForEach(segments, id: \.value) { segment in
            let selected = segment.value == selection
            Button {
                selection = segment.value
            } label: {
                segment.title
                    .font(LDType.sans(14, selected ? .bold : .medium, relativeTo: .subheadline))
                    .foregroundStyle(selected ? LDTheme.onAccent : LDTheme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(
                        selected ? LDTheme.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.ldPress)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// A pill: selectable, or removable with `LDChip.removable`. `width` gives a fixed width, as the
/// day chips have.
struct LDChip: View {
    private let title: Text
    private let isSelected: Bool
    private let width: CGFloat?
    private let isRemovable: Bool
    private let action: () -> Void

    init(_ title: LocalizedStringKey, isSelected: Bool = false, width: CGFloat? = nil, action: @escaping () -> Void) {
        self.init(Text(title), isSelected: isSelected, width: width, action: action)
    }

    init(_ title: Text, isSelected: Bool = false, width: CGFloat? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.width = width
        self.isRemovable = false
        self.action = action
    }

    private init(removable title: Text, onRemove: @escaping () -> Void) {
        self.title = title
        self.isSelected = false
        self.width = nil
        self.isRemovable = true
        self.action = onRemove
    }

    /// A chip with an x: tapping it removes it.
    static func removable(_ title: Text, onRemove: @escaping () -> Void) -> LDChip {
        LDChip(removable: title, onRemove: onRemove)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                title
                    .font(LDType.sans(14, isSelected ? .bold : .medium, relativeTo: .subheadline))
                    .foregroundStyle(isSelected ? LDTheme.onAccent : LDTheme.text)
                if isRemovable {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LDTheme.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, width == nil ? 14 : 0)
            .frame(minWidth: width, minHeight: 44)
            .background(isSelected ? LDTheme.accent : Color.clear, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isSelected ? LDTheme.accent : LDTheme.ghostBorder, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.ldPress)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isRemovable ? Text("Remove") : Text(verbatim: ""))
    }
}

/// LDChips in rows that wrap, with the boards' side margin.
struct LDChips<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LDFlowLayout(spacing: 6) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LDTheme.textInset)
    }
}

/// Lays its children out left to right and starts a new row when one does not fit.
struct LDFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        )
    }

    /// A chip wider than the row gets the row, and wraps inside it.
    private func fitted(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return ideal.width <= width ? ideal : subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var leading = bounds.minX
            for index in row.indices {
                let size = fitted(subviews[index], width: bounds.width)
                subviews[index].place(
                    at: CGPoint(x: leading, y: top + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                leading += size.width + spacing
            }
            top += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = fitted(subviews[index], width: width)
            let added = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if added > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
                row.width = size.width
            } else {
                row.width = added
            }
            row.indices.append(index)
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty {
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Buttons

enum LDButtonKind {
    case primary, ghost
    /// The boards' danger is amber, not red.
    case danger
}

enum LDButtonSize {
    /// 50 high, 15 text.
    case regular
    /// 44 high, 15 text: the footers of Preview and Delivery.
    case medium
    /// 44 high, 14 text: Sync now and the Logs footer.
    case small

    var height: CGFloat { self == .regular ? 50 : 44 }
    var fontSize: CGFloat { self == .small ? 14 : 15 }
}

/// The capsule look of LDButton, for your own Button, Link, ShareLink or NavigationLink.
struct LDButtonStyle: ButtonStyle {
    let kind: LDButtonKind
    var size: LDButtonSize = .regular
    var fullWidth = true

    init(_ kind: LDButtonKind = .primary, size: LDButtonSize = .regular, fullWidth: Bool = true) {
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        LDButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

private struct LDButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: LDButtonKind
    let size: LDButtonSize
    let fullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        switch kind {
        case .primary: return LDTheme.onAccent
        case .ghost: return LDTheme.text
        case .danger: return LDTheme.warning
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return .clear
        case .ghost: return LDTheme.ghostBorder
        case .danger: return LDTheme.warningDim
        }
    }

    var body: some View {
        configuration.label
            .font(LDType.sans(size.fontSize, kind == .primary ? .bold : .medium, relativeTo: .subheadline))
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: size.height)
            .background(kind == .primary ? LDTheme.accent : Color.clear, in: Capsule())
            .overlay {
                Capsule().strokeBorder(border, lineWidth: 1)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : isEnabled ? 1 : 0.45)
    }
}

/// A capsule button with the boards' side margin of 14 when it is full width. Pass `inset: 0` in a
/// footer. Give it a `route` instead of an action to push that route. `isBusy` shows a spinner next
/// to the title and disables it, for as long as the work runs.
struct LDButton: View {
    private enum Target {
        case action(() -> Void)
        case route(LDRoute)
    }

    private let title: Text
    private let kind: LDButtonKind
    private let size: LDButtonSize
    private let fullWidth: Bool
    private let inset: CGFloat
    private let isBusy: Bool
    private let target: Target

    init(
        _ title: LocalizedStringKey,
        kind: LDButtonKind = .primary,
        size: LDButtonSize = .regular,
        fullWidth: Bool = true,
        inset: CGFloat? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(title: Text(title), kind: kind, size: size, fullWidth: fullWidth, inset: inset, isBusy: isBusy, target: .action(action))
    }

    init(
        _ title: Text,
        kind: LDButtonKind = .primary,
        size: LDButtonSize = .regular,
        fullWidth: Bool = true,
        inset: CGFloat? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(title: title, kind: kind, size: size, fullWidth: fullWidth, inset: inset, isBusy: isBusy, target: .action(action))
    }

    init(
        _ title: LocalizedStringKey,
        kind: LDButtonKind = .primary,
        size: LDButtonSize = .regular,
        fullWidth: Bool = true,
        inset: CGFloat? = nil,
        route: LDRoute
    ) {
        self.init(title: Text(title), kind: kind, size: size, fullWidth: fullWidth, inset: inset, isBusy: false, target: .route(route))
    }

    private init(title: Text, kind: LDButtonKind, size: LDButtonSize, fullWidth: Bool, inset: CGFloat?, isBusy: Bool, target: Target) {
        self.title = title
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
        self.inset = inset ?? (fullWidth ? LDTheme.cardInset : 0)
        self.isBusy = isBusy
        self.target = target
    }

    var body: some View {
        Group {
            switch target {
            case .action(let action):
                Button(action: action) { label }
            case .route(let route):
                NavigationLink(value: route) { label }
            }
        }
        .buttonStyle(LDButtonStyle(kind, size: size, fullWidth: fullWidth))
        .disabled(isBusy)
        .padding(.horizontal, inset)
    }

    private var label: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(kind == .primary ? LDTheme.onAccent : LDTheme.text)
            }
            title
        }
    }
}

/// Text in the soft accent as a button, as Add destination and Skip setup on the boards.
struct LDTextButton: View {
    private let title: Text
    private let color: Color
    private let action: () -> Void

    init(_ title: LocalizedStringKey, color: Color = LDTheme.accentTextSoft, action: @escaping () -> Void) {
        self.title = Text(title)
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            title
                .font(LDType.sectionLabel)
                .foregroundStyle(color)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ldPress)
    }
}

// MARK: - Banner

/// The warning card. `actions` holds LDBannerActions and may stay empty.
struct LDBanner<Actions: View>: View {
    private let title: Text
    private let message: Text?
    private let actions: Actions

    init(_ title: LocalizedStringKey, message: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.init(Text(title), message: message, actions: actions)
    }

    init(_ title: Text, message: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LDTheme.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            title
                .font(LDType.sans(15, .bold, relativeTo: .subheadline))
                .foregroundStyle(LDTheme.warning)
            if let message {
                message
                    .font(LDType.note)
                    .foregroundStyle(LDTheme.warningBody)
                    .lineSpacing(LDType.lineSpacing(size: 14, lineHeight: 20))
                    .padding(.top, 2)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, Actions.self == EmptyView.self ? 12 : 4)
        .background(LDTheme.warningSurface, in: shape)
        .overlay { shape.strokeBorder(LDTheme.warningBorder, lineWidth: 1) }
        .padding(.top, 10)
        .padding(.horizontal, LDTheme.cardInset)
    }
}

extension LDBanner where Actions == EmptyView {
    init(_ title: LocalizedStringKey, message: Text? = nil) {
        self.init(title, message: message) { EmptyView() }
    }

    init(_ title: Text, message: Text? = nil) {
        self.init(title, message: message) { EmptyView() }
    }
}

/// An action inside an LDBanner.
struct LDBannerAction: View {
    private let title: Text
    private let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = Text(title)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            title
                .font(LDType.sans(14, .bold, relativeTo: .subheadline))
                .foregroundStyle(LDTheme.warningText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ldPress)
    }
}

// MARK: - Technical values

/// One line of LDKeyValueList.
struct LDKeyValue {
    let key: LocalizedStringKey
    let value: Text
    var color: Color = LDTheme.text
    /// An address or an identifier, not words: see `ldCode()`.
    var isCode = false

    init(_ key: LocalizedStringKey, _ value: Text, color: Color = LDTheme.text, isCode: Bool = false) {
        self.key = key
        self.value = value
        self.color = color
        self.isCode = isCode
    }
}

/// Labels on the left, values in Space Mono on the right, on a card. A grid gives every label the
/// width of the longest, so none breaks in the middle of a word. At the accessibility text sizes
/// the value goes under its label.
struct LDKeyValueList: View {
    let items: [LDKeyValue]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ items: [LDKeyValue]) {
        self.items = items
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                columns
            }
        }
        .ldSurface(radius: LDTheme.cardRadius)
        .padding(.top, 4)
        .padding(.horizontal, LDTheme.cardInset)
    }

    private var columns: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                GridRow {
                    keyText(items[index])
                        .padding(.vertical, 7)
                        .padding(.leading, 14)
                        .accessibilityHidden(true)
                    valueText(items[index])
                        .padding(.vertical, 7)
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // A grid row has no element of its own to combine the two in.
                        .accessibilityLabel(Text(items[index].key))
                        .accessibilityValue(items[index].value)
                }
                if index < items.count - 1 {
                    LDDivider()
                }
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    keyText(items[index])
                    valueText(items[index])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .accessibilityElement(children: .combine)
                if index < items.count - 1 {
                    LDDivider()
                }
            }
        }
    }

    private func keyText(_ item: LDKeyValue) -> some View {
        Text(item.key)
            .font(LDType.rowSubtitle)
            .foregroundStyle(LDTheme.muted)
    }

    @ViewBuilder
    private func valueText(_ item: LDKeyValue) -> some View {
        let value = item.value
            .font(LDType.monoValue)
            .foregroundStyle(item.color)
            .textSelection(.enabled)
        if item.isCode {
            value.ldCode()
        } else {
            value
        }
    }
}

/// Text as it is, in Space Mono on a card. Long lines scroll sideways, or wrap with `wraps`: a
/// stored payload is compact JSON, one line of up to 12,000 characters. `selectable: false` is for
/// a payload, where a Copy button is what keeps it on this iPhone: a text selection goes through
/// the general pasteboard, which is shared with other devices. Left to right in every language.
struct LDCodeBlock: View {
    let text: String
    var color: Color = LDTheme.inactive
    var wraps = false
    var selectable = true

    var body: some View {
        Group {
            if wraps {
                code
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    code
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .multilineTextAlignment(.leading)
        .environment(\.layoutDirection, .leftToRight)
        .ldSurface(radius: LDTheme.cardRadius)
        .padding(.horizontal, LDTheme.cardInset)
    }

    @ViewBuilder
    private var code: some View {
        let plain = Text(verbatim: text)
            .font(LDType.monoValue)
            .foregroundStyle(color)
        if selectable {
            plain
                .textSelection(.enabled)
                .padding(14)
        } else {
            plain
                .padding(14)
        }
    }
}

/// The 8 high bar of a running backfill. `value` runs from 0 to 1.
struct LDProgressBar: View {
    let value: Double

    var body: some View {
        let clamped = min(1, max(0, value))
        ProgressView(value: clamped)
            .progressViewStyle(LDProgressBarStyle())
            .accessibilityValue(Text(clamped, format: .percent))
            .padding(.horizontal, LDTheme.textInset)
    }
}

private struct LDProgressBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(LDTheme.progressTrack)
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { track in
                    Capsule()
                        .fill(LDTheme.accent)
                        .frame(width: track.size.width * (configuration.fractionCompleted ?? 0))
                }
            }
    }
}

// MARK: - Options

/// A card to pick, with a radio circle or a check square. It is a real button.
struct LDOption: View {
    enum Mark { case radio, check }

    private let title: Text
    private let subtitle: Text?
    private let isSelected: Bool
    private let mark: Mark
    private let bottom: CGFloat
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        subtitle: Text? = nil,
        isSelected: Bool,
        mark: Mark = .radio,
        bottom: CGFloat = 8,
        action: @escaping () -> Void
    ) {
        self.title = Text(title)
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.mark = mark
        self.bottom = bottom
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                indicator
                VStack(alignment: .leading, spacing: 0) {
                    title
                        .font(LDType.tileTitle)
                        .foregroundStyle(LDTheme.text)
                    if let subtitle {
                        subtitle
                            .font(LDType.rowSubtitle)
                            .foregroundStyle(LDTheme.muted)
                            .lineSpacing(LDType.lineSpacing(size: 13, lineHeight: 18))
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .ldSurface(radius: LDTheme.cardRadius, border: isSelected ? LDTheme.accent : LDTheme.tileBorder)
            .contentShape(RoundedRectangle(cornerRadius: LDTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.ldPress)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .padding(.horizontal, LDTheme.cardInset)
        .padding(.bottom, bottom)
    }

    private var indicator: some View {
        let shape = RoundedRectangle(cornerRadius: mark == .radio ? 12 : 7, style: .continuous)
        return shape
            .fill(isSelected ? LDTheme.accent : Color.clear)
            .overlay { shape.strokeBorder(isSelected ? LDTheme.accent : LDTheme.optionOff, lineWidth: 2) }
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(LDTheme.onAccent)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

// MARK: - Tiles

/// A tile: 26 point icon and chevron on top, title and subtitle at the bottom, 118 high or taller
/// with larger text. It draws only; make it tappable with `.ldLink(to:)` or `.ldButton {}`.
struct LDTile: View {
    private let title: Text
    private let subtitle: Text?
    private let systemImage: String

    init(_ title: LocalizedStringKey, subtitle: Text? = nil, systemImage: String) {
        self.title = Text(title)
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(LDTheme.icon)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                LDChevron()
            }
            Spacer(minLength: 8)
            title
                .font(LDType.tileTitle)
                .foregroundStyle(LDTheme.text)
            if let subtitle {
                subtitle
                    .font(LDType.rowSubtitle)
                    .foregroundStyle(LDTheme.muted)
                    .padding(.top, 1)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity, alignment: .topLeading)
        .ldSurface(radius: LDTheme.tileRadius)
        .contentShape(RoundedRectangle(cornerRadius: LDTheme.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Tiles in two columns with the boards' padding. Goes in LDScreen's `pinned`.
struct LDTileGrid<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            // One column at the accessibility text sizes: "Notifications" is wider than half a phone.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) { content }
            } else {
                LDTwoColumnLayout(spacing: 8) { content }
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, LDTheme.cardInset)
        .padding(.bottom, 14)
    }
}

/// Two equal columns where every cell in a row is as tall as the tallest of that row.
struct LDTwoColumnLayout: Layout {
    var spacing: CGFloat

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        max(0, (width - spacing) / 2)
    }

    private func rowHeights(_ subviews: Subviews, column: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: 2).map { first in
            let cells = subviews[first..<min(first + 2, subviews.count)]
            return cells.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        let heights = rowHeights(subviews, column: columnWidth(width))
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(bounds.width)
        var top = bounds.minY
        for (row, height) in rowHeights(subviews, column: column).enumerated() {
            for cell in 0..<2 where row * 2 + cell < subviews.count {
                subviews[row * 2 + cell].place(
                    at: CGPoint(x: bounds.minX + CGFloat(cell) * (column + spacing), y: top),
                    proposal: ProposedViewSize(width: column, height: height)
                )
            }
            top += height + spacing
        }
    }
}

// MARK: - Sheets

extension View {
    /// The share sheet for a file, open while `url` holds one.
    func shareSheet(for url: Binding<URL?>) -> some View {
        sheet(isPresented: Binding(get: { url.wrappedValue != nil }, set: { if !$0 { url.wrappedValue = nil } })) {
            if let file = url.wrappedValue {
                ShareSheet(activityItems: [file])
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct LDSheetToolbar: ViewModifier {
    let cancel: LocalizedStringKey
    let confirm: LocalizedStringKey?
    let canConfirm: Bool
    let onCancel: (() -> Void)?
    let onConfirm: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .ldSheetBarBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancel) {
                        onCancel?()
                        dismiss()
                    }
                }
                if let confirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirm) {
                            onConfirm?()
                            dismiss()
                        }
                        .disabled(!canConfirm)
                    }
                }
            }
    }
}

extension View {
    /// Scrolled, the bar before iOS 26 takes the ground colour of ContentView's appearance, which
    /// shows as a band on a sheet. iOS 26 has its own edge effect there.
    @ViewBuilder
    func ldSheetBarBackground() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            toolbarBackground(LDTheme.sheet, for: .navigationBar)
        }
    }

    /// The toolbar of a sheet: Cancel on the left, by default, and an optional Save on the right.
    /// Both close the sheet after running their closure. Pass `cancel: "Done"` for a sheet with
    /// nothing to save.
    func ldSheetToolbar(
        cancel: LocalizedStringKey = "Cancel",
        confirm: LocalizedStringKey? = nil,
        canConfirm: Bool = true,
        onCancel: (() -> Void)? = nil,
        onConfirm: (() -> Void)? = nil
    ) -> some View {
        modifier(LDSheetToolbar(cancel: cancel, confirm: confirm, canConfirm: canConfirm, onCancel: onCancel, onConfirm: onConfirm))
    }
}

// MARK: - Symbols

/// The SF Symbols that stand in for the boards' line icons.
enum LDSymbol {
    static let whatToSend = "waveform.path.ecg"
    static let whenToSend = "clock"
    static let notifications = "bell"
    static let more = "slider.vertical.3"
    static let help = "questionmark.circle"
    static let support = "star"
    static let privacy = "checkmark.shield"
    static let openSource = "chevron.left.forwardslash.chevron.right"
}
