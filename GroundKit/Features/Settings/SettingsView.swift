import SwiftUI

struct SettingsView: View {
    @Environment(AirportStore.self) private var store
    @Environment(HealthService.self) private var health
    @Environment(\.dismiss) private var dismiss
    @AppStorage("gloveMode") private var gloveMode = false
    @AppStorage("keepAwake") private var keepAwake = false
    @AppStorage("appearance") private var appearance = Appearance.auto
    @AppStorage("age") private var age = 0
    @State private var urlText = ""

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                AccountSection()
                Section("Airport") {
                    Picker("Airport", selection: Binding(get: { store.icao }, set: { store.select($0) })) {
                        ForEach(store.airports.sorted { $0.iata < $1.iata }) { Text("\($0.iata)  \($0.name)").tag($0.icao) }
                    }
                }
                Section {
                    Toggle("Glove mode (larger text and buttons)", isOn: $gloveMode)
                    Toggle("Keep screen on", isOn: $keepAwake)
                } header: {
                    Text("On the ramp")
                } footer: {
                    Text("Keep screen on suits a tablet mounted in a tug or the ops room; it uses more battery.")
                }
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(appearance.note(for: store.airport, at: .now))
                }
                Section {
                    Stepper {
                        LabeledContent("Age", value: age == 0 ? "Not set" : "\(age)")
                    } onIncrement: {
                        age = age == 0 ? 40 : min(80, age + 1)
                    } onDecrement: {
                        // 0 is "not set": step in and out of it from the adult range.
                        age = age <= 16 ? 0 : age - 1
                    }
                } header: {
                    Text("Heat strain")
                } footer: {
                    Text("Your age sets the heart-rate limit for heat-strain warnings on the Shift tab: 180 minus your age, sustained for 5 minutes in the heat (NIOSH). Without it, \(HeatStrain.limitBpm(age: nil)) bpm is used. Kept on this device only.")
                }
                Section {
                    Stepper("Caution at \(store.thresholds.windCautionKt) kt", value: $store.thresholds.windCautionKt, in: 15...60, step: 5)
                    Stepper("Warning at \(store.thresholds.windWarningKt) kt", value: $store.thresholds.windWarningKt,
                            in: store.thresholds.windCautionKt...80, step: 5)
                    Button("Restore defaults") { store.thresholds = .standard }
                } header: {
                    Text("Wind limits (wind or gust)")
                } footer: {
                    Text("Set these to your airline's limits for doors, stairs, high-loaders and jet bridges.")
                }
                Section("Sync and Health") {
                    LabeledContent("iCloud", value: Persistence.iCloudAvailable ? "Turnarounds and notes sync" : "Signed out: saved on this device")
                    LabeledContent("Health", value: !health.isAvailable ? "Not available" : health.hasRequestedAccess ? "Connected" : "Not connected")
                    if health.isAvailable && (!health.hasRequestedAccess || health.canAskForMore) {
                        Button(health.hasRequestedAccess ? "Allow sleep from Health" : "Connect Health") {
                            Task { await health.requestAccess() }
                        }
                    }
                }
                .task { await health.checkForNewTypes() }
                Section {
                    TextField("API base URL", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyURL)
                    Button("Use default") {
                        urlText = APIClient.defaultBaseURL.absoluteString
                        applyURL()
                    }
                } header: {
                    Text("Data source")
                } footer: {
                    Text("Weather, NOTAMs and flight history from the aviation data pipeline (MotherDuck, refreshed hourly). Live positions from adsb.lol (ODbL) or the OpenSky Network. Not an official source: advisory only.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        applyURL()
                        dismiss()
                    }
                }
            }
            .onAppear { urlText = store.baseURL.absoluteString }
        }
    }

    private func applyURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true,
              url != store.baseURL else { return }
        store.baseURL = url
        Task { await store.refresh(force: true) }
    }
}


/// Light or dark. Auto follows the phone. Sunset is dark from sunset to sunrise at the
/// selected airport, for crews whose phones stay light through a night shift.
enum Appearance: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case sunset = "Sunset"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    func colorScheme(for airport: Airport, at date: Date) -> ColorScheme? {
        switch self {
        case .auto: nil
        case .sunset: Solar.isDark(lat: airport.lat, lon: airport.lon, at: date) ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }

    /// What it does; for Sunset, when it next switches at the airport.
    func note(for airport: Airport, at date: Date) -> String {
        switch self {
        case .auto:
            return "Auto follows your phone's appearance setting. Sunset goes dark at sunset at the airport instead."
        case .light, .dark:
            return "Dark is easier on the eyes on night shifts."
        case .sunset:
            let dark = Solar.isDark(lat: airport.lat, lon: airport.lon, at: date)
            let next = Solar.nextChange(lat: airport.lat, lon: airport.lon, after: date)
            let when = switch (next, dark) {
            case (nil, true): "The sun stays down there for now."
            case (nil, false): "The sun stays up there for now."
            case (let t?, true): "Sunrise \(LocalTime.hhmm(t, airport.timeZone)) local."
            case (let t?, false): "Sunset \(LocalTime.hhmm(t, airport.timeZone)) local."
            }
            return "Dark from sunset to sunrise at \(airport.iata). " + when
        }
    }
}
