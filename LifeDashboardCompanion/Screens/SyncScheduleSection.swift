import SwiftUI
import UIKit

/// The health sync schedule: an interval or fixed times, a weekday filter and quiet hours, as
/// in the Android app. Saves on every change, like the rest of the screen. iOS decides when the
/// app runs in the background, so a fixed time means "not before this time", never "at".
struct SyncScheduleSection: View {
    @Binding var schedule: SyncSchedule
    @Binding var isExpanded: Bool

    @State private var intervalText = ""
    @State private var showAddTime = false
    @State private var showShortcutsHelp = false
    @State private var refreshIsOff = SyncScheduleSection.backgroundRefreshIsOff

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isExpanded {
                Picker("Mode", selection: $schedule.mode) {
                    Text("Every X minutes").tag(SyncMode.interval)
                    Text("Fixed times").tag(SyncMode.times)
                }
                .pickerStyle(.segmented)

                switch schedule.mode {
                case .interval: intervalRow
                case .times: timesList
                }

                Divider()
                DayPicker(days: $schedule.days)
                Divider()
                QuietHoursEditor(window: $schedule.quietWindow)
                Divider()

                if schedule.isNeverRunning { neverRunsWarning }
                if refreshIsOff { refreshOffNote }
                footnote
                Divider()
                shortcutsRow
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .onAppear { intervalText = String(schedule.intervalMinutes) }
        .onChange(of: isExpanded) { _, _ in intervalText = String(schedule.intervalMinutes) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in
            refreshIsOff = SyncScheduleSection.backgroundRefreshIsOff
        }
        .sheet(isPresented: $showAddTime) {
            AddTimeSheet { time in
                schedule.times = Array(Set(schedule.times + [time])).sorted()
            }
        }
        .sheet(isPresented: $showShortcutsHelp) { ShortcutsHelpSheet() }
    }

    private static var backgroundRefreshIsOff: Bool {
        UIApplication.shared.backgroundRefreshStatus != .available
    }

    private var header: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(alignment: .top) {
                Image(systemName: "clock")
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Schedule")
                        .font(.headline)
                    Text(schedule.isNeverRunning ? String(localized: "Never syncs") : schedule.summary)
                        .font(.caption)
                        .foregroundColor(schedule.isNeverRunning ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? Text("Collapse") : Text("Expand"))
    }

    private var intervalRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Interval")
                        .font(.subheadline)
                    Text("Minutes between syncs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                TextField("60", text: $intervalText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Sync Interval")
                    .onChange(of: intervalText) { _, text in
                        if let minutes = Int(text), minutes >= SyncSchedule.minIntervalMinutes {
                            schedule.intervalMinutes = minutes
                        }
                    }
                Text("min")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            if (Int(intervalText) ?? 0) < SyncSchedule.minIntervalMinutes {
                Text("Min \(SyncSchedule.minIntervalMinutes) minutes")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var timesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync times")
                .font(.subheadline)
            if schedule.times.isEmpty {
                Text("No times yet. Add one to start syncing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(schedule.times, id: \.self) { time in
                    HStack(spacing: 4) {
                        Text(time.formatted)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Button {
                            schedule.times.removeAll { $0 == time }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove \(time.formatted)"))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray5))
                    .cornerRadius(10)
                }
            }
            Button {
                showAddTime = true
            } label: {
                Label("Add a time", systemImage: "plus")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            Text("Each time syncs once, at the first chance iOS gives after it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var neverRunsWarning: some View {
        Label("These settings never sync. Add a time, a day, or shorten the quiet hours.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.red)
    }

    private var refreshOffNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Background App Refresh is off, so background syncs can come later.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("iOS decides when the app may sync in the background, so syncs can come later than set. Health data can't be read while your iPhone is locked.")
            Text("Sync Now and Shortcuts ignore this schedule.")
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private var shortcutsRow: some View {
        Button {
            showShortcutsHelp = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Need an exact time?")
                        .font(.subheadline)
                    Text("Use a Shortcuts automation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Mon to Sun, Monday first like the schedule and the Android app.
private struct DayPicker: View {
    @Binding var days: Set<Weekday>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Days")
                .font(.subheadline)
            HStack(spacing: 6) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    let isOn = days.contains(day)
                    Button {
                        if isOn { days.remove(day) } else { days.insert(day) }
                    } label: {
                        Text(day.shortName)
                            .font(.caption)
                            .fontWeight(isOn ? .semibold : .regular)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(isOn ? .accentColor : .secondary)
                            .background(isOn ? Color.accentColor.opacity(0.18) : Color(.systemGray5))
                            .cornerRadius(9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.fullName)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }
}

private struct QuietHoursEditor: View {
    @Binding var window: QuietWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { window != nil },
                set: { isOn in
                    window = isOn ? QuietWindow(from: TimeOfDay(hour: 23, minute: 0), to: TimeOfDay(hour: 7, minute: 0)) : nil
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quiet hours")
                        .font(.subheadline)
                    Text("Never sync between these times")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let current = window {
                DatePicker("From", selection: Binding(
                    get: { current.from.referenceDate },
                    set: { window = QuietWindow(from: TimeOfDay(date: $0), to: window?.to ?? current.to) }
                ), displayedComponents: .hourAndMinute)
                .font(.subheadline)
                .accessibilityLabel("Quiet hours from")
                DatePicker("Until", selection: Binding(
                    get: { current.to.referenceDate },
                    set: { window = QuietWindow(from: window?.from ?? current.from, to: TimeOfDay(date: $0)) }
                ), displayedComponents: .hourAndMinute)
                .font(.subheadline)
                .accessibilityLabel("Quiet hours until")
            }
        }
    }
}

private struct AddTimeSheet: View {
    let onAdd: (TimeOfDay) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time = TimeOfDay(hour: 8, minute: 0).referenceDate

    var body: some View {
        NavigationStack {
            DatePicker("Sync time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding()
                .navigationTitle("Add a time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            onAdd(TimeOfDay(date: time))
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

/// How to get a sync at an exact time: a Shortcuts automation that runs the app's action. The
/// app cannot create the automation itself; iOS offers no way to.
struct ShortcutsHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("iOS doesn't let apps sync at a set time, but a Shortcuts automation can run Sync Health Data at the times and days you pick.")
                    VStack(alignment: .leading, spacing: 10) {
                        step(1, "Open Shortcuts and go to Automation.")
                        step(2, "Tap + and choose Time of Day.")
                        step(3, "Set the time and the days, and choose Run Immediately.")
                        step(4, "Tap Next, then add the Sync Health Data action.")
                        step(5, "Repeat for each time you want.")
                    }
                    Label("Health data can't be read while your iPhone is locked. If it is locked at that time, that sync sends nothing and the next one catches up.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("Automations ignore the schedule in the app, quiet hours included.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if let url = URL(string: "shortcuts://") {
                        Link(destination: url) {
                            Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            .navigationTitle("Fixed times with Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundColor(.secondary)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The line under Sync Now: why automatic syncs are waiting right now, or when and where they go.
/// It never names a next sync time, since iOS picks that moment.
struct ScheduleStatusLine: View {
    let schedule: SyncSchedule
    let webhookCount: Int

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(ScheduleStatusLine.text(schedule: schedule, webhookCount: webhookCount, now: context.date, timeZone: .autoupdatingCurrent))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// No destination first (then "Sync Now still works" would not be true), then why automatic
    /// syncs are held, then the schedule itself. MQTT is not named: only Sync Now publishes it.
    nonisolated static func text(schedule: SyncSchedule, webhookCount: Int, now: Date, timeZone: TimeZone) -> String {
        let cadence = schedule.summary
        guard webhookCount > 0 else {
            return String(localized: "\(cadence), no destination yet")
        }
        switch schedule.hold(at: now, timeZone: timeZone) {
        case .never:
            return String(localized: "Automatic syncs are off. Sync Now still works.")
        case .quiet(let until):
            return String(localized: "Quiet hours until \(until.formatted). Sync Now still works.")
        case .dayOff:
            return String(localized: "No automatic syncs today. Sync Now still works.")
        case nil:
            return webhookCount == 1
                ? String(localized: "\(cadence) to 1 webhook")
                : String(localized: "\(cadence) to \(webhookCount) webhooks")
        }
    }
}

// MARK: - Display helpers

extension SyncSchedule {
    /// "Every 60 min · Mon Tue Wed · quiet 23:00 to 07:00", or "After 08:00, 21:00 · ..." for
    /// fixed times: "after", because iOS runs a time at its first chance, not on the minute.
    var summary: String {
        var parts: [String] = []
        switch mode {
        case .interval:
            parts.append(String(localized: "Every \(intervalMinutes) min"))
        case .times:
            let sorted = Array(Set(times)).sorted()
            parts.append(sorted.isEmpty
                ? String(localized: "No sync times yet")
                : String(localized: "After \(sorted.map(\.formatted).joined(separator: ", "))"))
        }
        if days.count < Weekday.allCases.count {
            parts.append(Weekday.allCases.filter(days.contains).map(\.shortName).joined(separator: " "))
        }
        if let quiet = quietWindow, quiet.from != quiet.to {
            parts.append(String(localized: "quiet \(quiet.from.formatted) to \(quiet.to.formatted)"))
        }
        return parts.joined(separator: " · ")
    }
}

extension Weekday {
    /// Calendar's symbols start on Sunday; Weekday starts on Monday.
    private var symbolIndex: Int { ((Weekday.allCases.firstIndex(of: self) ?? 0) + 1) % 7 }

    var shortName: String { Calendar.current.shortStandaloneWeekdaySymbols[symbolIndex] }

    var fullName: String { Calendar.current.standaloneWeekdaySymbols[symbolIndex] }
}

extension TimeOfDay {
    init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    /// This time on a fixed day without clock changes, for pickers and formatting only; today
    /// would turn 02:30 into 03:30 on the night summer time starts.
    var referenceDate: Date {
        Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
    }

    /// "23:00" or "11:00 PM", as the user's locale writes it.
    var formatted: String { referenceDate.formatted(date: .omitted, time: .shortened) }
}
