import SwiftUI

/// Background chances in Logs, folded like Sync History: every time iOS let the app try to sync on
/// its own, and what came of it. Logs shows what was sent; this shows the chances that sent
/// nothing, and whether iOS woke the app at all.
struct BackgroundChancesSection: View {
    let chances: [BackgroundChance]

    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Text("Background chances")
                Spacer(minLength: 0)
                if let newest = chances.first {
                    Text(verbatim: newest.last.formatted(.dateTime.hour().minute()))
                        .font(LDType.monoValue)
                        .foregroundStyle(LDTheme.muted)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LDTheme.muted)
                    .accessibilityHidden(true)
            }
            .font(LDType.sectionLabel)
            .foregroundStyle(LDTheme.text)
            .frame(minHeight: 44)
            .padding(.horizontal, LDTheme.textInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ldPress)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityHint(isExpanded ? Text("Hides the details") : Text("Shows the details"))

        if isExpanded {
            VStack(alignment: .leading, spacing: 8) {
                Text("Each time iOS let the app sync on its own, and what came of it. If this stays empty for hours while new data comes in, iOS did not wake the app.")
                    .font(LDType.mono(12))
                    .foregroundStyle(LDTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(chances) { chance in
                    BackgroundChanceLine(chance: chance)
                }
            }
            .padding(.horizontal, LDTheme.textInset)
            .padding(.bottom, 10)
        }
    }
}

private struct BackgroundChanceLine: View {
    let chance: BackgroundChance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: Self.moment(chance.last))
                .font(LDType.monoValue)
                .foregroundStyle(LDTheme.muted)
                .fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                LDSeparatedText(triggerLabel + " · " + outcomeLabel)
                    .font(LDType.mono(12, bold: true))
                    .foregroundStyle(isProblem ? LDTheme.warningText : LDTheme.text)
                if chance.count > 1 {
                    Text("\(chance.count) times since \(Self.moment(chance.first))")
                        .font(LDType.mono(12))
                        .foregroundStyle(LDTheme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// A time for today, as the rows of Logs show it, and the day as well before that.
    private static func moment(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The lock and a run cut short are what keep automatic syncs from coming; a failed delivery
    /// has its own row in Logs.
    private var isProblem: Bool {
        chance.outcome == .locked || chance.outcome == .cancelled
    }

    private var triggerLabel: String {
        switch chance.syncTrigger {
        case .observer: return String(localized: "New Apple Health data")
        case .appRefresh: return String(localized: "Background refresh")
        case .processing: return String(localized: "Background processing")
        case .foreground: return String(localized: "App opened")
        case .unlock: return String(localized: "iPhone unlocked")
        case nil: return chance.trigger
        }
    }

    private var outcomeLabel: String {
        switch chance.outcome {
        case .synced: return String(localized: "Synced")
        case .failed: return String(localized: "Sync failed")
        case .notDue: return String(localized: "Not due yet")
        case .notConfigured: return String(localized: "Nothing set up")
        case .locked: return String(localized: "iPhone locked, Health data unreadable")
        case .cancelled: return String(localized: "Out of time, stopped by iOS")
        }
    }
}
