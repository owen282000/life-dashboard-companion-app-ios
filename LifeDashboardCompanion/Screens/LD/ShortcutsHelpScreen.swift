import SwiftUI

/// How to get a sync at an exact time: a Shortcuts automation that runs the app's action. The
/// app cannot create the automation itself; iOS offers no way to.
struct ShortcutsHelpScreen: View {
    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("Exact times with Shortcuts.")
            LDNote("iOS doesn't let apps sync at a set time, but a Shortcuts automation can run Sync Health Data at the times and days you pick.", top: 6)
            LDGap(12)
            LDCard {
                step(1, "Open Shortcuts and go to Automation.")
                step(2, "Tap + and choose Time of Day.")
                step(3, "Set the time and the days, and choose Run Immediately.")
                step(4, "Tap Next, then add the Sync Health Data action.")
                step(5, "Repeat for each time you want.")
            }
            LDNote("Health data can't be read while your iPhone is locked. If it is locked at that time, that sync sends nothing and the next one catches up.", size: 13)
            LDNote("Automations ignore the schedule in the app, quiet hours included.", size: 13)
            LDGap(14)
            if let url = URL(string: "shortcuts://") {
                Link(destination: url) {
                    Text("Open Shortcuts")
                }
                .buttonStyle(LDButtonStyle(.primary))
                .padding(.horizontal, LDTheme.cardInset)
            }
        }
        .navigationTitle("Shortcuts")
        .ldSheetToolbar(cancel: "Done")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
            Text(text)
        }
        .font(LDType.row)
        .foregroundStyle(LDTheme.text)
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
