import SwiftUI
import UIKit

/// The health sync schedule: an interval or fixed times, a weekday filter and quiet hours. Saves
/// on every change, and PreferencesManager tells the background sync about it. iOS decides when
/// the app runs in the background, so a fixed time means "not before this time", never "at".
struct WhenToSendScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var navigator: LDNavigator
    @EnvironmentObject private var pairing: PairingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var intervalText = ""
    @State private var showAddTime = false
    @State private var editingQuietEnd: QuietEnd?
    @State private var refreshIsOff = WhenToSendScreen.backgroundRefreshIsOff

    private enum QuietEnd { case from, until }

    private var schedule: SyncSchedule { prefs.healthSyncSchedule }

    private static var backgroundRefreshIsOff: Bool {
        UIApplication.shared.backgroundRefreshStatus != .available
    }

    var body: some View {
        LDScreen {
            LDHeading(schedule.cadenceHeading)
            LDGap(14)
            LDSegmented(selection: $prefs.healthSyncSchedule.mode, segments: [
                LDSegment(SyncMode.interval, "Every X minutes"),
                LDSegment(SyncMode.times, "Fixed times"),
            ])
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mode")

            switch schedule.mode {
            case .interval: intervalSection
            case .times: timesSection
            }

            LDSectionLabel("Days")
            dayChips
            LDSectionLabel("Limits")
            quietHoursCard

            if schedule.isNeverRunning {
                LDBanner("Never syncs", message: Text("These settings never sync. Add a time, a day, or shorten the quiet hours."))
            }
            if refreshIsOff {
                LDBanner("Background App Refresh is off, so background syncs can come later.") {
                    LDBannerAction("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            LDNote("iOS decides when the app may sync in the background, so syncs can come later than set. Health data can't be read while your iPhone is locked.", size: 13)
            LDNote("Sync Now and Shortcuts ignore this schedule.", top: 4, size: 13)
            LDGap(8)
            LDCard {
                LDRow("Need an exact time?", value: Text("Shortcuts"))
                    .ldButton { navigator.present(.shortcutsHelp) }
            }
        }
        .navigationTitle("When to send")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { intervalText = String(schedule.intervalMinutes) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in
            refreshIsOff = WhenToSendScreen.backgroundRefreshIsOff
        }
        .sheet(isPresented: $showAddTime) {
            AddTimeSheet { time in
                prefs.healthSyncSchedule.times = Array(Set(schedule.times + [time])).sorted()
            }
        }
        // A pairing link needs the root sheet, which cannot show over this one.
        .onChange(of: pairing.incoming) { _, _ in showAddTime = false }
    }

    // MARK: - Interval

    @ViewBuilder private var intervalSection: some View {
        LDSectionLabel("Sync Interval")
        LDCard {
            LDFieldRow("Minutes between syncs", text: $intervalText, prompt: "60")
                .keyboardType(.numberPad)
                .onChange(of: intervalText) { _, text in
                    if let minutes = Int(text), minutes >= SyncSchedule.minIntervalMinutes {
                        prefs.healthSyncSchedule.intervalMinutes = minutes
                    }
                }
        }
        if (Int(intervalText) ?? 0) < SyncSchedule.minIntervalMinutes {
            LDNote(Text("Min \(SyncSchedule.minIntervalMinutes) minutes"), color: LDTheme.warning, size: 13)
        } else {
            LDNote(Text("The minimum is \(SyncSchedule.minIntervalMinutes) minutes."), size: 13)
        }
    }

    // MARK: - Times

    @ViewBuilder private var timesSection: some View {
        let times = Array(Set(schedule.times)).sorted()
        LDSectionLabel("Sync times")
        if times.isEmpty {
            LDNote("No times yet. Add one to start syncing.", top: 0)
        } else {
            LDChips {
                ForEach(times, id: \.self) { time in
                    LDChip.removable(Text(verbatim: time.formatted)) {
                        prefs.healthSyncSchedule.times.removeAll { $0 == time }
                    }
                }
            }
        }
        LDGap(8)
        LDButton("Add a time", kind: .ghost, size: .medium) { showAddTime = true }
        LDNote("Each time syncs once, at the first chance iOS gives after it.", size: 13)
    }

    // MARK: - Days

    /// All seven on one line, as on the board: a tighter gap on a narrow phone, wrapping only
    /// when the text size leaves no other way.
    private var dayChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { dayChipButtons }
            HStack(spacing: 2) { dayChipButtons }
            LDFlowLayout(spacing: 6) { dayChipButtons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LDTheme.textInset)
    }

    private var dayChipButtons: some View {
        ForEach(Weekday.allCases, id: \.self) { day in
            let isOn = schedule.days.contains(day)
            LDChip(Text(verbatim: day.initial), isSelected: isOn, width: 44) {
                if isOn {
                    prefs.healthSyncSchedule.days.remove(day)
                } else {
                    prefs.healthSyncSchedule.days.insert(day)
                }
            }
            .accessibilityLabel(day.fullName)
        }
    }

    // MARK: - Quiet hours

    private var quietHoursCard: some View {
        LDCard {
            LDToggleRow("Quiet hours", subtitle: Text("Never sync between these times"), isOn: Binding(
                get: { schedule.quietWindow != nil },
                set: { isOn in
                    editingQuietEnd = nil
                    prefs.healthSyncSchedule.quietWindow = isOn
                        ? QuietWindow(from: TimeOfDay(hour: 23, minute: 0), to: TimeOfDay(hour: 7, minute: 0))
                        : nil
                }
            ))
            if let window = schedule.quietWindow {
                quietRow("From", label: "Quiet hours from", time: window.from, end: .from)
                if editingQuietEnd == .from {
                    quietWheel("Quiet hours from", selection: Binding(
                        get: { window.from.referenceDate },
                        set: {
                            prefs.healthSyncSchedule.quietWindow = QuietWindow(
                                from: TimeOfDay(date: $0),
                                to: schedule.quietWindow?.to ?? window.to
                            )
                        }
                    ))
                }
                quietRow("Until", label: "Quiet hours until", time: window.to, end: .until)
                if editingQuietEnd == .until {
                    quietWheel("Quiet hours until", selection: Binding(
                        get: { window.to.referenceDate },
                        set: {
                            prefs.healthSyncSchedule.quietWindow = QuietWindow(
                                from: schedule.quietWindow?.from ?? window.from,
                                to: TimeOfDay(date: $0)
                            )
                        }
                    ))
                }
            }
        }
    }

    private func quietRow(_ title: LocalizedStringKey, label: LocalizedStringKey, time: TimeOfDay, end: QuietEnd) -> some View {
        LDRow(title, value: Text(verbatim: time.formatted), valueColor: LDTheme.accentTextSoft, showsChevron: false)
            .ldButton {
                withAnimation(reduceMotion ? nil : LDMotion.enter()) {
                    editingQuietEnd = editingQuietEnd == end ? nil : end
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(Text(verbatim: time.formatted))
    }

    private func quietWheel(_ label: LocalizedStringKey, selection: Binding<Date>) -> some View {
        DatePicker(label, selection: selection, displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
    }
}

private struct AddTimeSheet: View {
    let onAdd: (TimeOfDay) -> Void

    @State private var time = TimeOfDay(hour: 8, minute: 0).referenceDate

    var body: some View {
        NavigationStack {
            LDScreen(background: LDTheme.sheet) {
                DatePicker("Sync time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .navigationTitle("Add a time")
            .ldSheetToolbar(confirm: "Add", onConfirm: { onAdd(TimeOfDay(date: time)) })
        }
        .tint(LDTheme.accentText)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(LDTheme.sheet)
    }
}

private extension SyncSchedule {
    /// What the schedule does, as the heading says it. Takes what the schedule itself goes by: the
    /// interval as it is used, and only the times outside the quiet window, which are skipped.
    var cadenceHeading: Text {
        if isNeverRunning { return Text("Never syncs") }
        switch mode {
        case .interval:
            return Text("Every \(effectiveIntervalMinutes) minutes.")
        case .times:
            let running = Set(times).filter { time in quietWindow?.contains(time) != true }
            return running.count == 1 ? Text("Once a day.") : Text("\(running.count) times a day.")
        }
    }
}

private extension Weekday {
    /// Calendar's symbols start on Sunday; Weekday starts on Monday.
    var initial: String {
        let index = ((Weekday.allCases.firstIndex(of: self) ?? 0) + 1) % 7
        return Calendar.current.veryShortStandaloneWeekdaySymbols[index]
    }
}
