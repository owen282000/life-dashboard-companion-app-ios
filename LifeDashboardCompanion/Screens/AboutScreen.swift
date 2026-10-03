import SwiftUI
import UIKit

/// Every link on About, built on the iOS repository so none can point at the Android app's.
enum AboutLinks {
    static let repository = URL(string: "https://github.com/owen282000/life-dashboard-companion-app-ios")!
    static let repositorySlug = "owen282000/life-dashboard-companion-app-ios"
    static let documentation = URL(string: repository.absoluteString + "#readme")!
    static let changelog = repository.appending(path: "blob/main/CHANGELOG.md")
    static let newIssue = repository.appending(path: "issues/new")
    static let licence = repository.appending(path: "blob/main/LICENSE")
    static let privacy = URL(string: repository.absoluteString + "#privacy")!
    /// Only in builds run from source; see the Buy me a coffee row.
    static let tip = URL(string: "https://ko-fi.com/owen282000")!

    /// The links every build shows.
    static let all = [repository, documentation, changelog, newIssue, licence, privacy]
}

struct AboutScreen: View {
    // The tip link is Debug only, but its text stays out of the #if: an export for translation
    // reads a Release build and would drop anything inside it.
    fileprivate static let tipTitle: LocalizedStringKey = "Buy me a coffee"
    fileprivate static let tipSubtitle: LocalizedStringResource = "The app stays free and open source; a coffee keeps releases quick"

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    // Easter eggs: tap the mark 7 times to make it beat, long-press the version pill for stats
    @State private var heartTapCount = 0
    @State private var isBeating = false
    @State private var heartScale: CGFloat = 1.0
    @State private var beatTask: Task<Void, Never>?
    @State private var showNerdStats = false
    @State private var showPrivacyPolicy = false
    @State private var bpm = 72

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var markWidth: CGFloat = 170

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero

                VStack(spacing: 16) {
                    if showNerdStats {
                        NerdStatsCard()
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                    }

                    Text("Sends your Apple Health data to Home Assistant through the Life Dashboard integration, to your own webhook backend or to an MQTT broker. No cloud in between.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    FeatureCard(title: "Apple Health", systemImage: "heart") {
                        FeatureItem(text: "Steps, distance, calories", systemImage: "figure.walk")
                        FeatureItem(text: "Sleep tracking with stages", systemImage: "moon")
                        FeatureItem(text: "Meditation sessions", systemImage: "figure.mind.and.body")
                        FeatureItem(text: "Heart rate & more", systemImage: "waveform.path.ecg.rectangle")
                    }

                    FeatureCard(title: "Destinations", systemImage: "paperplane", tint: Brand.logs, ink: Brand.logsInk) {
                        FeatureItem(text: "Home Assistant, paired by QR code", systemImage: "qrcode.viewfinder")
                        FeatureItem(text: "Your own webhooks, signed with HMAC", systemImage: "signature")
                        FeatureItem(text: "MQTT with Home Assistant discovery", systemImage: "antenna.radiowaves.left.and.right")
                        FeatureItem(text: "Offline queue with retries", systemImage: "tray.full")
                    }

                    FeatureCard(title: "Privacy & Security", systemImage: "checkmark.shield", tint: Brand.success, ink: Brand.successInk) {
                        FeatureItem(text: "No third-party data sharing", systemImage: "lock")
                        FeatureItem(text: "Secrets stored in the Keychain", systemImage: "key")
                        FeatureItem(text: "Settings stay on your device unless you export them", systemImage: "internaldrive")
                        FeatureItem(text: "Full control over sync settings", systemImage: "slider.horizontal.3")
                    }

                    FeatureCard(title: "Backup & restore", systemImage: "arrow.up.arrow.down.circle") {
                        SettingsBackupSection()
                    }

                    links
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .readableWidth()
            }
        }
        .background(Color(.systemGroupedBackground))
        .screenshotScrollAnchor()
        .navigationDestination(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyScreen()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopBeating() }
        }
        .onDisappear { stopBeating() }
        .onAppear {
            #if DEBUG
            // For screenshots: -ld.nerd YES shows the Nerd Stats, -ld.privacy YES opens the policy.
            showNerdStats = UserDefaults.standard.bool(forKey: "ld.nerd")
            showPrivacyPolicy = UserDefaults.standard.bool(forKey: "ld.privacy")
            #endif
        }
    }

    // MARK: - Hero

    /// The Android app's hero: the mark on the dark brand ground, the same in both appearances.
    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                RadialGradient(colors: [Brand.green.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: min(markWidth, 220) * 0.6)
                    .frame(width: min(markWidth, 220) * 1.2, height: min(markWidth, 220) * 0.9)
                if isBeating {
                    Image(systemName: "heart.fill")
                        .font(.system(size: min(markWidth, 220) * 0.33))
                        .foregroundStyle(Brand.green)
                        .scaleEffect(heartScale)
                } else {
                    BrandMark(glow: true)
                        .frame(width: min(markWidth, 220))
                }
            }
            .frame(height: min(markWidth, 220) * 0.6)
            .contentShape(Rectangle())
            .onTapGesture { handleHeartTap() }
            .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("Life Dashboard")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                Text("Companion")
                    .font(.title3)
                    .foregroundColor(Brand.heroSubtitle)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Group {
                if isBeating {
                    Text("\(bpm) BPM")
                } else {
                    Text("Version \(version)")
                }
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundColor(Brand.green)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Brand.green.opacity(0.18), in: Capsule())
            .contentTransition(.opacity)
            .onLongPressGesture { toggleNerdStats() }
            .accessibilityAction(named: Text("Show Nerd Stats")) { toggleNerdStats() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .padding(.horizontal, 16)
        .background(
            RadialGradient(colors: Brand.ground, center: UnitPoint(x: 0.3, y: 0.25), startRadius: 0, endRadius: 700),
            in: UnevenRoundedRectangle(bottomLeadingRadius: Brand.heroRadius, bottomTrailingRadius: Brand.heroRadius, style: .continuous)
        )
        .environment(\.colorScheme, .dark)
    }

    private func toggleNerdStats() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if reduceMotion {
            showNerdStats.toggle()
        } else {
            withAnimation(.spring(duration: 0.35)) { showNerdStats.toggle() }
        }
    }

    // MARK: - Links

    private var links: some View {
        VStack(spacing: 12) {
            LinkCard(title: "Documentation", subtitle: Text("Setup, webhook payload, MQTT"), systemImage: "doc.text", url: AboutLinks.documentation)
            LinkCard(title: "What's new", subtitle: Text("Changelog for \(version)"), systemImage: "sparkles", url: AboutLinks.changelog)
            LinkCard(title: "Report a problem", subtitle: Text("GitHub issues"), systemImage: "ladybug", url: AboutLinks.newIssue)
            LinkCard(
                title: "View on GitHub",
                subtitle: Text(verbatim: AboutLinks.repositorySlug),
                systemImage: "chevron.left.forwardslash.chevron.right",
                url: AboutLinks.repository
            )
            #if DEBUG
            // Only in builds run from Xcode, the iOS counterpart of the Android app's F-Droid and
            // GitHub builds. An archive for TestFlight or the App Store is a Release build and has
            // no tip link, which App Review would refuse outside the US (guideline 3.1.1).
            LinkCard(
                title: AboutScreen.tipTitle,
                subtitle: Text(AboutScreen.tipSubtitle),
                systemImage: "cup.and.saucer",
                url: AboutLinks.tip
            )
            #endif
            Button {
                showPrivacyPolicy = true
            } label: {
                LinkCardLabel(
                    title: "Privacy policy",
                    subtitle: Text("What the app reads, stores and sends"),
                    systemImage: "hand.raised",
                    trailingSymbol: "chevron.right"
                )
            }
            .buttonStyle(.plain)
            LinkCard(title: "Licence", subtitle: Text(verbatim: "MIT · © 2026 Owen Vogelaar"), systemImage: "scroll", url: AboutLinks.licence)
        }
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

// MARK: - Nerd Stats (hidden behind a long-press on the version pill)

private struct NerdStatsCard: View {
    private let records = UserDefaults.standard.integer(forKey: "stats_lifetime_records")
    private let deliveries = UserDefaults.standard.integer(forKey: "stats_total_deliveries")
    private let largestPayload = UserDefaults.standard.integer(forKey: "stats_largest_payload")
    private let firstSync = UserDefaults.standard.object(forKey: "stats_first_sync") as? Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundColor(Brand.nerdStar)
                    .accessibilityHidden(true)
                Text("Nerd Stats")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("You found the secret")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if deliveries == 0 {
                Text("No syncs yet. Come back when your data has started flowing.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                StatRow(label: "Records delivered", value: Text(records.formatted()))
                StatRow(label: "Successful deliveries", value: Text(deliveries.formatted()))
                if largestPayload > 0 {
                    StatRow(
                        label: "Largest payload",
                        value: Text(ByteCountFormatter.string(fromByteCount: Int64(largestPayload), countStyle: .file))
                    )
                }
                if let firstSync = firstSync {
                    StatRow(label: "Syncing since", value: Text(firstSync.formatted(date: .abbreviated, time: .omitted)))
                    let days = max(1, Calendar.current.dateComponents([.day], from: firstSync, to: Date()).day ?? 1)
                    StatRow(label: "That is", value: Text("\(days) days of quantified you"))
                }
            }
        }
        .cardStyle()
    }
}

private struct StatRow: View {
    let label: LocalizedStringKey
    let value: Text

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout())
        layout {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer()
            }
            value
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Components

/// Android's FeatureCard: an icon tile and a title over a few lines, or over a section.
private struct FeatureCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = Brand.green
    var ink: Color = Brand.ink
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemName: systemImage, tint: tint, ink: ink)
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .cardStyle()
    }
}

private struct FeatureItem: View {
    let text: LocalizedStringKey
    let systemImage: String

    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 22

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundColor(.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

/// Android's TapCard: one card per link, with an arrow for the web and a chevron for a page.
private struct LinkCardLabel: View {
    let title: LocalizedStringKey
    let subtitle: Text
    let systemImage: String
    var trailingSymbol = "arrow.up.right"

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                subtitle
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: trailingSymbol)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .cardStyle(padding: 14)
        .contentShape(Rectangle())
    }
}

private struct LinkCard: View {
    let title: LocalizedStringKey
    let subtitle: Text
    let systemImage: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            LinkCardLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Privacy policy

/// The privacy policy as the Android app shows it in the app, written for what the iPhone app
/// does: it reads Apple Health and writes nothing to it, and its health data stays out of backups.
struct PrivacyPolicyScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Life Dashboard Companion is a self-hosting tool. It reads health data on this iPhone and sends it only to servers you set up yourself. The developer never receives, stores or sees any of your data.")
                    .font(.body)
                    .foregroundColor(.secondary)

                PolicySection(title: "What the app reads", systemImage: "eye", text: "Apple Health data, only for the types you switch on and only after you allow them in the Health access sheet. With Backfill, also older records for the range you pick. When you delete a record in Apple Health, the next sync reports its id so your server can remove it too. The camera is used only by the pairing scanner, while that screen is open: frames are decoded on the phone and are never stored or sent.")
                PolicySection(title: "What the app writes", systemImage: "square.and.pencil", text: "Nothing. The app only asks Apple Health for read access.")
                PolicySection(title: "Where it goes", systemImage: "paperplane", text: "Only to the destinations you enter or pair: your own webhook URLs, the Life Dashboard integration in your own Home Assistant, and your own MQTT broker. The app contacts no other server. There are no analytics, no crash reporting services and no advertising SDKs. Besides the types you switch on, each payload carries the app version, and each record the name of the app or device that wrote it, which on an iPhone often includes your name. MQTT is unencrypted unless you switch on TLS. States are published retained, so the broker keeps the latest value of each sensor even after you switch MQTT off in the app: clear the topics on the broker if you stop using it.")
                PolicySection(title: "What stays on this iPhone", systemImage: "internaldrive", text: "Your settings, with secrets in the iOS Keychain. Sync progress, so each record is sent once. A log of the last 100 deliveries, which you can clear, and payloads that could not be delivered yet, at most 700, until they arrive or a server has turned them down for a week. Your settings and the sync progress are part of your iPhone backup, like other app data. The log and the undelivered payloads are not: they stay on this iPhone, and a restored or new iPhone starts without them. Deleting the app removes all of it, but iOS can keep the secrets in the Keychain: clear them in the app first if you want them gone. Exports are files you create yourself and hand to the share sheet or the Files app, where the app you pick keeps its own copy. A settings export without secrets still contains your webhook URLs, which can work as a password, so share it with care.")
                PolicySection(title: "Your control", systemImage: "slider.horizontal.3", text: "Everything is opt-in and reversible: which types are read, where they go and how often. Turning off access in the Health app stops the matching reads immediately.")
                PolicySection(title: "Contact", systemImage: "envelope", text: "Questions about privacy: open an issue on GitHub or email the developer at the address on the GitHub profile.")

                LinkCard(
                    title: "Read the full privacy policy",
                    subtitle: Text("Privacy in the README on GitHub"),
                    systemImage: "hand.raised",
                    url: AboutLinks.privacy
                )
            }
            .padding(16)
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .screenshotScrollAnchor()
        .navigationTitle("Privacy policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PolicySection: View {
    let title: LocalizedStringKey
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(systemName: systemImage, tint: Brand.success, ink: Brand.successInk)
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }
}
