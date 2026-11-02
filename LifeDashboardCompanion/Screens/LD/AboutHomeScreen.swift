import SwiftUI
import UIKit

/// Every link on About, built on the iOS repository so none can point at the Android app's.
/// The privacy policy has a page of its own, the address App Store Connect has too.
enum AboutLinks {
    static let repository = URL(string: "https://github.com/owen282000/life-dashboard-companion-app-ios")!
    static let repositorySlug = "owen282000/life-dashboard-companion-app-ios"
    static let documentation = URL(string: repository.absoluteString + "#readme")!
    static let changelog = repository.appending(path: "blob/main/CHANGELOG.md")
    static let newIssue = repository.appending(path: "issues/new")
    static let licence = repository.appending(path: "blob/main/LICENSE")
    static let privacy = URL(string: "https://owen282000.github.io/life-dashboard-companion/ios/privacy/")!
    /// The project's website: the setup guides and the other Life Dashboard parts.
    static let website = URL(string: "https://owen282000.com/life-dashboard/ios/")!
    /// Where a buyer with a question writes (P1-24).
    static let support = URL(string: "mailto:owen282000@hotmail.com")!
    /// The App Store page with the review sheet open (P1-28), for anyone who wants to rate it.
    static let rate = URL(string: "https://apps.apple.com/app/id6824075761?action=write-review")!
    /// Only in builds run from source; see the Buy me a coffee row.
    static let tip = URL(string: "https://ko-fi.com/owen282000")!
    /// Where Home's Background App Refresh card sends someone for help with their phone.
    static let troubleshooting = URL(string: "https://owen282000.com/life-dashboard/troubleshooting/")!

    /// The links every build shows.
    static let all = [website, repository, documentation, changelog, newIssue, licence, privacy]
}

/// The other Life Dashboard parts this page points to, next to the links in `AboutLinks`.
private enum AboutFamilyLinks {
    static let stack = URL(string: "https://owen282000.com/life-dashboard/grafana/")!
}

struct AboutHomeScreen: View {
    private enum Variant: String {
        case a, b
    }

    // TEMPORARY: two designs side by side so Owen can compare them on his iPhone. Both stay
    // compiled in Release, so their strings stay in the catalog. Remove the loser and this switch.
    #if DEBUG
    @AppStorage("ld.aboutVariant") private var variant = Variant.a
    #else
    private let variant = Variant.a
    #endif

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var navigator: LDNavigator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    // Easter eggs: tap the line 7 times to make it beat, long-press the version for the stats
    @State private var heartTapCount = 0
    @State private var isBeating = false
    @State private var heartScale: CGFloat = 1.0
    @State private var beatTask: Task<Void, Never>?
    @State private var bpm = 72
    #if DEBUG
    @State private var appliedDebugArguments = false
    #endif

    var body: some View {
        LDScreen {
            switch variant {
            case .a: variantA
            case .b: variantB
            }
            versionLine
        } pinned: {
            LDTileGrid {
                LDTile("Help", subtitle: Text("Guide, what's new"), systemImage: LDSymbol.help)
                    .ldLink(to: .aboutHelp)
                LDTile("Support", subtitle: Text("Rate, star on GitHub"), systemImage: LDSymbol.support)
                    .ldLink(to: .aboutSupport)
                LDTile("Privacy", subtitle: Text("No trackers"), systemImage: LDSymbol.privacy)
                    .ldLink(to: .aboutPrivacy)
                LDTile("Open source", subtitle: Text("MIT licence"), systemImage: LDSymbol.openSource)
                    .ldLink(to: .aboutOpenSource)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    variant = variant == .a ? .b : .a
                } label: {
                    Text(verbatim: "A/B: \(variant.rawValue.uppercased())")
                        .font(LDType.mono(13, bold: true))
                }
                .accessibilityLabel(Text(verbatim: "Temporary switch, About variant \(variant.rawValue.uppercased())"))
            }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopBeating() }
        }
        .onDisappear { stopBeating() }
        .onAppear {
            #if DEBUG
            // For screenshots: -ld.nerd YES opens the Nerd Stats, -ld.privacy YES the policy.
            guard !appliedDebugArguments else { return }
            appliedDebugArguments = true
            if UserDefaults.standard.bool(forKey: "ld.nerd") { navigator.push(.aboutNerdStats) }
            if UserDefaults.standard.bool(forKey: "ld.privacy") { navigator.push(.aboutPrivacy) }
            #endif
        }
    }

    // MARK: - Variant A

    @ViewBuilder
    private var variantA: some View {
        LDHeading("Your data goes where you send it.")

        AboutFanRows {
            Button(action: openHomeAssistant) {
                AboutFanRow(
                    title: Text(verbatim: "Home Assistant"),
                    status: homeAssistantStatus,
                    statusColor: homeAssistantStatusColor
                )
            }
            .buttonStyle(.ldPress)
            .ldStaggerRise(0)

            Link(destination: AboutFamilyLinks.stack) {
                AboutFanRow(title: Text(verbatim: "Life Dashboard Stack"), status: Text("Set up the stack"))
            }
            .buttonStyle(.ldPress)
            .ldStaggerRise(1)

            Button {
                navigator.present(.addDestination)
            } label: {
                AboutFanRow(title: Text("Your own server"), status: Text("Webhook or MQTT"))
            }
            .buttonStyle(.ldPress)
            .ldStaggerRise(2)
        }
        .padding(.leading, AboutFan.width(for: dynamicTypeSize))
        .padding(.trailing, 14)
        .background(alignment: .leading) {
            AboutFan(isBeating: isBeating, heartScale: heartScale)
                .frame(width: AboutFan.width(for: dynamicTypeSize))
                .contentShape(Rectangle())
                .onTapGesture { handleHeartTap() }
                .accessibilityHidden(true)
        }
        .padding(.top, 18)

        LDNote("No account and no cloud.")
    }

    // MARK: - Variant B

    @ViewBuilder
    private var variantB: some View {
        AboutVariantBHeading()

        PulseLine()
            .overlay {
                if isBeating {
                    GeometryReader { box in
                        // The dot of the line, at (232, 42) in its 390 wide box.
                        AboutBeatingHeart(scale: heartScale)
                            .position(x: box.size.width * 232 / 390, y: box.size.width * 42 / 390)
                    }
                    // PulseLine mirrors itself in a right-to-left language, so the heart follows.
                    .environment(\.layoutDirection, .leftToRight)
                    .flipsForRightToLeftLayoutDirection(true)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { handleHeartTap() }
            .accessibilityHidden(true)

        LDDestinationRow(Text(verbatim: "Home Assistant"), status: homeAssistantStatus, statusColor: homeAssistantStatusColor)
            .ldButton(action: openHomeAssistant)
            .ldStaggerRise(0)

        Link(destination: AboutFamilyLinks.stack) {
            LDDestinationRow(Text(verbatim: "Life Dashboard Stack"), status: Text("Grafana, AI"))
        }
        .buttonStyle(.ldPress)
        .ldStaggerRise(1)

        LDDestinationRow(Text("Your own server"), status: Text("Webhook or MQTT"))
            .ldButton { navigator.present(.addDestination) }
            .ldStaggerRise(2)
    }

    // MARK: - Home Assistant

    /// The first address the pairing code recognises as Home Assistant's own, decided by the
    /// address as everywhere else in the app.
    private var homeAssistantAddress: String? {
        prefs.healthWebhookUrls.first { PairingLink(url: $0, secret: "", name: nil).looksLikeHomeAssistant }
    }

    private var homeAssistantStatus: Text {
        homeAssistantAddress == nil ? Text("Pair with a code") : Text("Connected")
    }

    private var homeAssistantStatusColor: Color {
        homeAssistantAddress == nil ? LDTheme.muted : LDTheme.accentTextSoft
    }

    private func openHomeAssistant() {
        if let homeAssistantAddress {
            navigator.present(.webhookDestination(address: homeAssistantAddress))
        } else {
            navigator.present(.addDestination)
        }
    }

    // MARK: - Version

    /// 44 high for the long press: the board's 12 above the line is in its own padding.
    private var versionLine: some View {
        Group {
            if isBeating {
                Text("\(bpm) BPM")
                    .font(LDType.mono(13, bold: true))
                    .foregroundStyle(LDTheme.accentTextSoft)
                    .monospacedDigit()
            } else {
                Text("Life Dashboard Companion, version \(version). Made by Owen Vogelaar.")
                    .font(LDType.noteSmall)
                    .foregroundStyle(LDTheme.muted)
                    .lineSpacing(LDType.lineSpacing(size: 13, lineHeight: 18))
            }
        }
        .contentTransition(.opacity)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, LDTheme.textInset)
        .contentShape(Rectangle())
        .onLongPressGesture { openNerdStats() }
        .accessibilityAction(named: Text("Show Nerd Stats")) { openNerdStats() }
    }

    private func openNerdStats() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        navigator.push(.aboutNerdStats)
    }

    // MARK: - Beating heart easter egg

    private func handleHeartTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        heartTapCount += 1
        guard heartTapCount >= 7 else { return }
        heartTapCount = 0
        if isBeating {
            stopBeating()
        } else {
            startBeating()
        }
    }

    private func startBeating() {
        withAnimation { isBeating = true }
        let still = reduceMotion
        beatTask = Task { @MainActor in
            // The heart beats at YOUR pace: use the most recent heart rate measurement
            if let latest = await HealthKitManager.shared.latestHeartRateBPM() {
                bpm = min(max(latest, 30), 200)
            }

            let strong = UIImpactFeedbackGenerator(style: .heavy)
            let soft = UIImpactFeedbackGenerator(style: .light)
            // With Reduce Motion the heart stays still; the haptics still beat.
            let (big, small): (CGFloat, CGFloat) = still ? (1, 1) : (1.18, 1.10)
            while !Task.isCancelled {
                // Lub-dub takes ~0.47s; the pause fills the rest of the cycle for this BPM
                let cycle = 60.0 / Double(bpm)
                let pause = max(0.05, cycle - 0.47)

                strong.impactOccurred()
                withAnimation(.easeOut(duration: 0.12)) { heartScale = big }
                try? await Task.sleep(nanoseconds: 130_000_000)
                withAnimation(.easeIn(duration: 0.10)) { heartScale = 1.0 }
                try? await Task.sleep(nanoseconds: 120_000_000)
                soft.impactOccurred()
                withAnimation(.easeOut(duration: 0.10)) { heartScale = small }
                try? await Task.sleep(nanoseconds: 110_000_000)
                withAnimation(.easeIn(duration: 0.10)) { heartScale = 1.0 }
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }
    }

    private func stopBeating() {
        beatTask?.cancel()
        beatTask = nil
        withAnimation {
            isBeating = false
            heartScale = 1.0
        }
    }
}

/// A row on the About pages that leaves the app, for a web page or the mail app.
struct AboutLinkRow: View {
    private let row: LDRow
    private let url: URL

    init(_ title: LocalizedStringKey, subtitle: Text? = nil, value: Text? = nil, url: URL) {
        row = LDRow(title, subtitle: subtitle, value: value)
        self.url = url
    }

    var body: some View {
        Link(destination: url) { row }
            .buttonStyle(.ldPress)
    }
}

// MARK: - Variant B heading

/// 46/50 on the board, tighter than the font's natural line height, so the lines overlap by the
/// difference. Three texts rather than one with line breaks, which `lineSpacing` cannot tighten.
private struct AboutVariantBHeading: View {
    @ScaledMetric(relativeTo: .largeTitle) private var overlap: CGFloat = 46 * 1.276 - 50

    var body: some View {
        VStack(alignment: .leading, spacing: -overlap) {
            Text("No account.")
            Text("No cloud.")
            Text("No trackers.")
        }
        .font(LDType.sans(46, .bold, relativeTo: .largeTitle))
        .tracking(-1.2)
        .foregroundStyle(LDTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8 - overlap / 2)
        .padding(.bottom, -overlap / 2)
        .padding(.horizontal, LDTheme.textInset)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Fan

private struct AboutBeatingHeart: View {
    let scale: CGFloat

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 30))
            .foregroundStyle(LDTheme.accent)
            .scaleEffect(scale)
    }
}

/// The heartbeat that branches to the three rows beside it. Each part is drawn up to where
/// `progress` has reached `window`, so SwiftUI interpolates one number and the parts follow each
/// other: first the beat, then the branches. Scaled by the width it gets; the three rows are
/// equally tall, which puts the branch ends at 1/6, 3/6 and 5/6 of whatever height they take.
private struct AboutFanShape: Shape {
    enum Branch {
        case top, middle, bottom

        var heightFraction: CGFloat {
            switch self {
            case .top: return 1 / 6
            case .middle: return 3 / 6
            case .bottom: return 5 / 6
            }
        }
    }

    enum Part {
        case beat, hub
        case branch(Branch), tip(Branch)
    }

    /// The board's size: viewBox 176 by 192 with the hub at (110, 96).
    static let boardWidth: CGFloat = 176
    static let hubX: CGFloat = 110
    private static let boardMiddle: CGFloat = 96

    let part: Part
    let window: ClosedRange<Double>
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let span = window.upperBound - window.lowerBound
        let local = min(1, max(0, (progress - window.lowerBound) / span))
        guard local > 0 else { return Path() }

        let scale = rect.width / Self.boardWidth
        let middle = rect.midY
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: middle + (y - Self.boardMiddle) * scale)
        }
        func dot(_ center: CGPoint, radius: CGFloat) -> Path {
            let radius = radius * scale * local
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }

        switch part {
        case .beat:
            // The board's M0 96H36l8-20 12 44 10-30 5 9h33 ends 3 points low; this one ends on
            // the hub's centre line, the way the big heartbeat line does.
            var line = Path()
            line.move(to: point(0, 96))
            for (x, y) in [(36, 96), (44, 76), (56, 120), (66, 90), (71, 96), (104, 96)] as [(CGFloat, CGFloat)] {
                line.addLine(to: point(x, y))
            }
            return stroked(line.trimmedPath(from: 0, to: local), width: 4)
        case .hub:
            return dot(point(Self.hubX, 96), radius: 7)
        case .branch(let branch):
            // M110 96C138 96 134 y 166 y, with y the height of that row's centre.
            let end = CGPoint(x: rect.minX + 166 * scale, y: rect.minY + rect.height * branch.heightFraction)
            var line = Path()
            line.move(to: point(Self.hubX, 96))
            line.addCurve(
                to: end,
                control1: point(138, 96),
                control2: CGPoint(x: rect.minX + 134 * scale, y: end.y)
            )
            return stroked(line.trimmedPath(from: 0, to: local), width: 3)
        case .tip(let branch):
            return dot(CGPoint(x: rect.minX + 166 * scale, y: rect.minY + rect.height * branch.heightFraction), radius: 4)
        }
    }

    private func stroked(_ path: Path, width: CGFloat) -> Path {
        path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// The fan in its colours, drawn in on appear. Off with Reduce Motion.
private struct AboutFan: View {
    let isBeating: Bool
    let heartScale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0

    /// Narrower at accessibility text sizes, so the rows keep room for their text.
    static func width(for size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? 96 : AboutFanShape.boardWidth
    }

    var body: some View {
        let shown = reduceMotion ? 1 : progress
        ZStack {
            AboutFanShape(part: .beat, window: 0...0.5, progress: shown).fill(LDTheme.accent)
            AboutFanShape(part: .branch(.top), window: 0.54...0.9, progress: shown).fill(LDTheme.accent)
            AboutFanShape(part: .branch(.middle), window: 0.54...0.9, progress: shown).fill(LDTheme.accent)
            AboutFanShape(part: .branch(.bottom), window: 0.54...0.9, progress: shown).fill(LDTheme.accentDim)
            AboutFanShape(part: .hub, window: 0.48...0.56, progress: shown).fill(LDTheme.accent)
            AboutFanShape(part: .tip(.top), window: 0.88...1, progress: shown).fill(LDTheme.accent)
            AboutFanShape(part: .tip(.middle), window: 0.88...1, progress: shown).fill(LDTheme.accent)
            AboutFanShape(part: .tip(.bottom), window: 0.88...1, progress: shown).fill(LDTheme.accentDim)

            if isBeating {
                GeometryReader { box in
                    AboutBeatingHeart(scale: heartScale)
                        .position(x: box.size.width * AboutFanShape.hubX / AboutFanShape.boardWidth, y: box.size.height / 2)
                }
                .transition(.opacity)
            }
        }
        // Drawn in fixed coordinates, then mirrored as a whole so it still runs towards the rows.
        .environment(\.layoutDirection, .leftToRight)
        .flipsForRightToLeftLayoutDirection(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2)) { progress = 1 }
        }
        .onDisappear { progress = 0 }
    }
}

/// A row beside the fan: 15/20 bold over 13/18, with the chevron.
private struct AboutFanRow: View {
    let title: Text
    let status: Text
    var statusColor: Color = LDTheme.accentTextSoft

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(LDType.sans(15, .bold, relativeTo: .subheadline))
                    .foregroundStyle(LDTheme.text)
                status
                    .font(LDType.rowSubtitle)
                    .foregroundStyle(statusColor)
                    .lineSpacing(LDType.lineSpacing(size: 13, lineHeight: 18))
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            LDChevron()
        }
        .frame(maxWidth: .infinity, minHeight: AboutFanRows.rowHeight, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Stacks the rows at one height, the tallest one's, so the fan's branches always end on their
/// centres, also when Dynamic Type wraps one of them.
private struct AboutFanRows: Layout {
    static let rowHeight: CGFloat = 64

    private func height(_ subviews: Subviews, width: CGFloat?) -> CGFloat {
        let proposal = ProposedViewSize(width: width, height: nil)
        return subviews.map { $0.sizeThatFits(proposal).height }.max() ?? Self.rowHeight
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0,
            height: height(subviews, width: proposal.width) * CGFloat(subviews.count)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowHeight = height(subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + rowHeight * CGFloat(index)),
                proposal: ProposedViewSize(width: bounds.width, height: rowHeight)
            )
        }
    }
}
