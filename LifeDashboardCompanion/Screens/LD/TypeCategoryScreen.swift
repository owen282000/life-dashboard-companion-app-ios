import SwiftUI

/// The groups of What to send. Every HealthDataType sits in exactly one.
enum LDTypeCategory: String, CaseIterable, Hashable {
    case activity, body, heartAndVitals, sleepAndMind, foodAndDrink, cycleTracking, symptoms, soundAndHabits

    var title: LocalizedStringKey {
        switch self {
        case .activity: return "Activity"
        case .body: return "Body"
        case .heartAndVitals: return "Heart and vitals"
        case .sleepAndMind: return "Sleep and mind"
        case .foodAndDrink: return "Food and drink"
        case .cycleTracking: return "Cycle tracking"
        case .symptoms: return "Symptoms"
        case .soundAndHabits: return "Sound, daylight and habits"
        }
    }

    var types: [HealthDataType] {
        switch self {
        case .activity:
            return [.steps, .distance, .activeCalories, .totalCalories, .exercise]
        case .body:
            return [.weight, .height, .bodyFat, .leanBodyMass]
        case .heartAndVitals:
            return [
                .heartRate, .restingHeartRate, .heartRateVariability, .bloodPressure, .oxygenSaturation,
                .respiratoryRate, .bodyTemperature, .basalBodyTemperature, .bloodGlucose, .vo2Max
            ]
        case .sleepAndMind:
            return [.sleep, .mindfulness]
        case .foodAndDrink:
            return [.hydration, .nutrition]
        case .cycleTracking:
            return [.menstruation, .intermenstrualBleeding, .ovulationTest, .cervicalMucus, .sexualActivity]
        case .symptoms, .soundAndHabits:
            return []
        }
    }

    /// What Apple Health has and the app does not read yet, without a promise: a name leaves this
    /// list when its type is built. Clinical records and fixed traits such as blood type are left
    /// out on purpose.
    var notAvailableYet: [LocalizedStringResource] {
        switch self {
        case .activity:
            return [
                "Activity Rings", "Exercise Minutes", "Move Minutes", "Stand Minutes", "Stand Hours",
                "Flights Climbed", "Wheelchair Pushes", "Swimming Strokes", "Nike Fuel", "Physical Effort",
                "Workout Effort", "Estimated Workout Effort", "Underwater Depth", "Water Temperature",
                "Walking Speed", "Walking Step Length", "Walking Asymmetry", "Double Support Time",
                "Walking Heart Rate", "Stair Ascent Speed", "Stair Descent Speed", "Six-Minute Walk",
                "Walking Steadiness", "Walking Steadiness Events", "Running Speed", "Running Power",
                "Running Stride Length", "Ground Contact Time", "Vertical Oscillation", "Cycling Speed",
                "Cycling Power", "Cycling Cadence", "Functional Threshold Power",
                "Cross-Country Skiing Speed", "Paddle Sports Speed", "Rowing Speed"
            ]
        case .body:
            return ["Body Mass Index", "Waist Circumference"]
        case .heartAndVitals:
            return [
                "ECG", "AFib Burden", "Heart Rate Recovery", "Heart Rate Variability (RMSSD)",
                "High Heart Rate Events", "Low Heart Rate Events", "Irregular Rhythm Events",
                "Low Cardio Fitness Events", "Hypertension Events", "Perfusion Index", "Medication",
                "Insulin Delivery", "Blood Alcohol", "Forced Expiratory Volume", "Forced Vital Capacity",
                "Peak Expiratory Flow", "Inhaler Usage", "Number of Falls", "Electrodermal Activity"
            ]
        case .sleepAndMind:
            return ["State of Mind", "Wrist Temperature During Sleep", "Breathing Disturbances", "Sleep Apnea Events"]
        case .foodAndDrink:
            return ["Alcoholic Drinks"]
        case .cycleTracking:
            return [
                "Contraceptives", "Lactation", "Pregnancy", "Pregnancy Tests", "Progesterone Tests",
                "Infrequent Cycles", "Irregular Cycles", "Prolonged Periods", "Bleeding After Pregnancy",
                "Bleeding During Pregnancy", "Bleeding After Menopause", "Menopausal State"
            ]
        case .symptoms:
            return [
                "Abdominal Cramps", "Acne", "Appetite Changes", "Bladder Incontinence", "Bloating",
                "Breast Pain", "Chest Tightness or Pain", "Chills", "Constipation", "Coughing", "Diarrhea",
                "Dizziness", "Dry Skin", "Fainting", "Fatigue", "Fever", "Body and Muscle Ache", "Hair Loss",
                "Headache", "Heartburn", "Hot Flashes", "Loss of Smell", "Loss of Taste", "Lower Back Pain",
                "Memory Lapse", "Mood Changes", "Nausea", "Night Sweats", "Pelvic Pain",
                "Rapid or Fluttering Heartbeat", "Runny Nose", "Shortness of Breath", "Sinus Congestion",
                "Skipped Heartbeat", "Sleep Changes", "Sore Throat", "Vaginal Dryness", "Vomiting", "Wheezing"
            ]
        case .soundAndHabits:
            return [
                "Time in Daylight", "UV Exposure", "Environmental Sound Levels", "Headphone Audio Levels",
                "Environmental Sound Reduction", "Loud Environment Events", "Loud Headphone Events",
                "Hearing Tests", "Handwashing", "Toothbrushing"
            ]
        }
    }

    #if DEBUG
    /// A type added to HealthDataType without a category could not be switched on anywhere.
    static func assertCoversEveryType() {
        let listed = allCases.flatMap(\.types)
        assert(
            listed.count == Set(listed).count && Set(listed) == Set(HealthDataType.allCases),
            "Every HealthDataType must sit in exactly one LDTypeCategory"
        )
    }
    #endif
}

/// Switching types on and off, for every page of What to send.
@MainActor
enum WhatToSendSelection {
    /// One type's switch: switching on asks iOS for that type alone.
    static func binding(for type: HealthDataType, prefs: PreferencesManager) -> Binding<Bool> {
        Binding(
            get: { prefs.healthEnabledDataTypes.contains(type) },
            set: { enabled in
                if enabled {
                    prefs.healthEnabledDataTypes.insert(type)
                    Task {
                        try? await HealthKitManager.shared.requestAuthorization(for: [type])
                    }
                } else {
                    prefs.healthEnabledDataTypes.remove(type)
                }
                changed()
            }
        )
    }

    /// A preset: iOS is asked once, for the types it brings in.
    static func apply(_ types: Set<HealthDataType>, prefs: PreferencesManager) async {
        let added = types.subtracting(prefs.healthEnabledDataTypes)
        prefs.healthEnabledDataTypes = types
        changed()
        try? await HealthKitManager.shared.requestAuthorization(for: added)
    }

    /// Reconfigure observer queries for changed data types, and the background tasks, which the
    /// first type (or the last one gone) starts or stops.
    private static func changed() {
        BackgroundSyncManager.shared.reconfigureObservers()
        BackgroundSyncManager.shared.replan()
    }
}

struct TypeCategoryScreen: View {
    let category: LDTypeCategory

    @ObservedObject private var prefs = PreferencesManager.shared

    var body: some View {
        let types = category.types
        LDScreen {
            LDHeading(category.title)
            if category == .cycleTracking {
                LDNote("This only goes to your own destinations.", top: 4)
            } else if !types.isEmpty {
                LDNote(Text("\(types.filter(prefs.healthEnabledDataTypes.contains).count) of \(types.count) selected."), top: 4)
            }
            LDGap(12)
            if !types.isEmpty {
                LDCard {
                    ForEach(types) { type in
                        LDToggleRow(Text(type.displayName), isOn: WhatToSendSelection.binding(for: type, prefs: prefs))
                    }
                }
                .ldStaggerRise(0)
                LDGap(10)
            }
            NotAvailableYetCard(names: category.notAvailableYet, startsOpen: types.isEmpty)
                .ldStaggerRise(1)
        }
        .navigationTitle("What to send")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The types of a category that the app cannot send yet: names only, nothing to switch, so it does
/// not read as a broken control.
private struct NotAvailableYetCard: View {
    let names: [LocalizedStringResource]
    @State private var isOpen: Bool

    init(names: [LocalizedStringResource], startsOpen: Bool) {
        self.names = names
        _isOpen = State(initialValue: startsOpen)
    }

    var body: some View {
        LDCard {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Not available yet")
                        .font(LDType.row)
                        .foregroundStyle(LDTheme.text)
                    Spacer(minLength: 0)
                    Text(verbatim: names.count.formatted())
                        .font(LDType.row)
                        .foregroundStyle(LDTheme.muted)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LDTheme.muted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.ldPress)
            .accessibilityValue(isOpen ? Text("Expanded") : Text("Collapsed"))
            if isOpen {
                Text(verbatim: names.map { String(localized: $0) }.formatted(.list(type: .and, width: .narrow)))
                    .font(LDType.rowSubtitle)
                    .foregroundStyle(LDTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
    }
}
