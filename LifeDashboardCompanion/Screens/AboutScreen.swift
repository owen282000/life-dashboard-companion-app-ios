import SwiftUI
import UIKit

struct AboutScreen: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    // Easter eggs: tap the heart 7 times to make it beat, long-press the version pill for stats
    @State private var heartTapCount = 0
    @State private var isBeating = false
    @State private var heartScale: CGFloat = 1.0
    @State private var beatTask: Task<Void, Never>?
    @State private var showNerdStats = false
    @State private var bpm = 72

    private let gradient = LinearGradient(
        colors: [
            Color(red: 0.35, green: 0.34, blue: 0.84),
            Color(red: 0.20, green: 0.51, blue: 0.98)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard

                if showNerdStats {
                    NerdStatsCard()
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                Text("Syncs your Apple Health data to your own webhook endpoints for automated life tracking.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                AboutSectionCard(icon: "heart.fill", tint: .pink, title: "Apple Health") {
                    FeatureRow(icon: "figure.walk", text: "Steps, distance, calories")
                    FeatureRow(icon: "bed.double.fill", text: "Sleep tracking with stages")
                    FeatureRow(icon: "brain.head.profile", text: "Meditation sessions")
                    FeatureRow(icon: "waveform.path.ecg", text: "Heart rate, vitals & more")
                }

                AboutSectionCard(icon: "bolt.horizontal.fill", tint: .blue, title: "Webhooks") {
                    FeatureRow(icon: "arrow.triangle.branch", text: "Multiple endpoints at once")
                    FeatureRow(icon: "signature", text: "HMAC payload signing")
                    FeatureRow(icon: "tray.full.fill", text: "Offline queue with retries")
                    FeatureRow(icon: "clock.arrow.circlepath", text: "Background sync via HealthKit")
                }

                AboutSectionCard(icon: "shield.fill", tint: .green, title: "Privacy & Security") {
                    FeatureRow(icon: "lock.fill", text: "No third-party data sharing")
                    FeatureRow(icon: "key.fill", text: "Secrets stored in the Keychain")
                    FeatureRow(icon: "internaldrive.fill", text: "Settings stay on your device")
                }

                VStack(spacing: 10) {
                    LinkCard(
                        icon: "chevron.left.forwardslash.chevron.right",
                        title: "View on GitHub",
                        subtitle: "owen282000/life-dashboard-companion-app-ios",
                        url: "https://github.com/owen282000/life-dashboard-companion-app-ios"
                    )
                    LinkCard(
                        icon: "candybarphone",
                        title: "Android companion app",
                        subtitle: "Health Connect & Screen Time",
                        url: "https://github.com/owen282000/life-dashboard-companion-app"
                    )
                    LinkCard(
                        icon: "doc.text",
                        title: "MIT License",
                        subtitle: "Free and open source",
                        url: "https://github.com/owen282000/life-dashboard-companion-app-ios/blob/main/LICENSE"
                    )
                }

                Text("Made by Owen Vogelaar for the self-hosted\nand quantified self community.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
            }
            .padding()
        }
    }

    private var headerCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 84, height: 84)
                Image(systemName: isBeating ? "heart.fill" : "heart.text.square.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
            }
            .scaleEffect(heartScale)
            .accessibilityHidden(true)
            .onTapGesture { handleHeartTap() }

            VStack(spacing: 2) {
                Text("Life Dashboard")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("Companion")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.8))
            }

            Text(isBeating ? "\(bpm) BPM" : "Version \(version)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.2))
                .clipShape(Capsule())
                .contentTransition(.opacity)
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(duration: 0.35)) { showNerdStats.toggle() }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(gradient)
        .cornerRadius(16)
        .onDisappear { stopBeating() }
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
        beatTask = Task { @MainActor in
            // The heart beats at YOUR pace: use the most recent heart rate measurement
            if let latest = await HealthKitManager.shared.latestHeartRateBPM() {
                bpm = min(max(latest, 30), 200)
            }

            let strong = UIImpactFeedbackGenerator(style: .heavy)
            let soft = UIImpactFeedbackGenerator(style: .light)
            while !Task.isCancelled {
                // Lub-dub takes ~0.47s; the pause fills the rest of the cycle for this BPM
                let cycle = 60.0 / Double(bpm)
                let pause = max(0.05, cycle - 0.47)

                strong.impactOccurred()
                withAnimation(.easeOut(duration: 0.12)) { heartScale = 1.18 }
                try? await Task.sleep(nanoseconds: 130_000_000)
                withAnimation(.easeIn(duration: 0.10)) { heartScale = 1.0 }
                try? await Task.sleep(nanoseconds: 120_000_000)
                soft.impactOccurred()
                withAnimation(.easeOut(duration: 0.10)) { heartScale = 1.10 }
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
                    .foregroundColor(.yellow)
                Text("Nerd Stats")
                    .font(.headline)
                Spacer()
                Text("You found the secret")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if deliveries == 0 {
                Text("No syncs yet. Come back when your data has started flowing.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                StatRow(label: "Records delivered", value: records.formatted())
                StatRow(label: "Successful deliveries", value: deliveries.formatted())
                if largestPayload > 0 {
                    StatRow(
                        label: "Largest payload",
                        value: ByteCountFormatter.string(fromByteCount: Int64(largestPayload), countStyle: .file)
                    )
                }
                if let firstSync = firstSync {
                    StatRow(label: "Syncing since", value: firstSync.formatted(date: .abbreviated, time: .omitted))
                    let days = max(1, Calendar.current.dateComponents([.day], from: firstSync, to: Date()).day ?? 1)
                    StatRow(label: "That is", value: "\(days) day\(days == 1 ? "" : "s") of quantified you")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }
}

// MARK: - Components

private struct AboutSectionCard<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 17))
                            .foregroundColor(tint)
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

private struct LinkCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray5))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(16)
        }
    }
}
