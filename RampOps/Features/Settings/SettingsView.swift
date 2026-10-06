import SwiftUI

struct SettingsView: View {
    @Environment(AirportStore.self) private var store
    @Environment(HealthService.self) private var health
    @Environment(\.dismiss) private var dismiss
    @AppStorage("gloveMode") private var gloveMode = false
    @AppStorage("keepAwake") private var keepAwake = false
    @State private var urlText = ""

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
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
                    if health.isAvailable && !health.hasRequestedAccess {
                        Button("Connect Health") { Task { await health.requestAccess() } }
                    }
                }
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
