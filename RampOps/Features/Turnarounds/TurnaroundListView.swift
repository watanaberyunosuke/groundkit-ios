import SwiftData
import SwiftUI

struct TurnaroundListView: View {
    @Environment(AirportStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @Query(sort: \Turnaround.createdAt, order: .reverse) private var all: [Turnaround]
    @State private var showClosed = false
    @State private var showNew = false

    var body: some View {
        @Bindable var router = router
        let here = all.filter { $0.airportIcao == store.icao && $0.isClosed == showClosed }
        NavigationStack(path: $router.turnaroundPath) {
            List {
                Picker("Show", selection: $showClosed) {
                    Text("Active").tag(false)
                    Text("Completed").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if here.isEmpty {
                    ContentUnavailableView {
                        Label(showClosed ? "No completed turnarounds" : "No active turnarounds", systemImage: "checklist")
                    } description: {
                        Text(showClosed ? "Closed turnarounds at \(store.airport.iata) appear here."
                             : "Start one from a flight on the Arrivals board, or add one.")
                    } actions: {
                        if !showClosed { Button("New turnaround") { showNew = true }.buttonStyle(.borderedProminent) }
                    }
                }
                ForEach(here) { t in
                    NavigationLink(value: t) { TurnaroundRow(turnaround: t, timeZone: store.timeZone) }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(here[i]) }
                }
            }
            .navigationTitle("Turnarounds")
            .rampToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New turnaround", systemImage: "plus") { showNew = true }
                }
            }
            .navigationDestination(for: Turnaround.self) { TurnaroundDetailView(turnaround: $0) }
            .sheet(isPresented: $showNew) {
                NewTurnaroundView { t in
                    context.insert(t)
                    router.turnaroundPath = [t]
                }
            }
        }
    }
}

struct TurnaroundRow: View {
    var turnaround: Turnaround
    var timeZone: TimeZone

    var body: some View {
        let t = turnaround
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.label).font(.title2.weight(.bold))
                if !t.stand.isEmpty {
                    Text("Stand \(t.stand)")
                        .font(.headline)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.yellow, in: .rect(cornerRadius: 6))
                        .foregroundStyle(.black)
                }
                if t.hasDangerousGoods {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Dangerous goods")
                }
                Spacer()
                if let off = t.targetOffBlock { OffBlockCountdown(target: off, timeZone: timeZone, compact: true) }
            }
            ProgressView(value: t.progress)
                .tint(t.progress >= 1 ? .green : .accentColor)
            Text(t.isClosed ? "Closed \(t.closedAt!.hhmm(timeZone))" : t.nextStep.map { "Next: \($0.title)" } ?? "All steps done")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

/// Minutes to the target off-block time, red once it has passed.
struct OffBlockCountdown: View {
    var target: Date
    var timeZone: TimeZone
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = Int((target.timeIntervalSince(context.date) / 60).rounded(.down))
            let late = minutes < 0
            VStack(alignment: .trailing, spacing: 0) {
                Text(late ? "+\(-minutes) min" : "\(minutes) min")
                    .font((compact ? Font.title3 : .system(size: 40, design: .rounded)).weight(.bold).monospacedDigit())
                    .foregroundStyle(late ? .red : minutes <= 10 ? .orange : .primary)
                Text("off-block \(target.hhmm(timeZone))").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(late ? "\(-minutes) minutes past off-block time" : "\(minutes) minutes to off-block")
        }
    }
}

struct NewTurnaroundView: View {
    @Environment(AirportStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onCreate: (Turnaround) -> Void

    @State private var flight = ""
    @State private var stand = ""
    @State private var registration = ""
    @State private var origin = ""
    @State private var destination = ""
    @State private var hasTarget = true
    @State private var target = Date.now.addingTimeInterval(45 * 60)
    @State private var dangerousGoods = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Flight") {
                    TextField("Flight or callsign (QF1 / QFA1)", text: $flight)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Stand", text: $stand)
                        .textInputAutocapitalization(.characters)
                    TextField("Registration (VH-OQA)", text: $registration)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section("Route") {
                    TextField("From", text: $origin).textInputAutocapitalization(.characters)
                    TextField("To", text: $destination).textInputAutocapitalization(.characters)
                }
                Section {
                    Toggle("Target off-block time", isOn: $hasTarget)
                    if hasTarget {
                        DatePicker("Off-block", selection: $target, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, store.timeZone)
                    }
                    Toggle("Dangerous goods on board", isOn: $dangerousGoods)
                } footer: {
                    Text("Times are \(store.airport.iata) local. Dangerous goods adds the NOTOC step.")
                }
            }
            .navigationTitle("New turnaround")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let code = flight.trimmingCharacters(in: .whitespaces).uppercased()
                        let t = Turnaround(airportIcao: store.icao, callsign: code,
                                           flightIata: code.isEmpty ? nil : code,
                                           origin: origin.isEmpty ? nil : origin.uppercased(),
                                           destination: destination.isEmpty ? nil : destination.uppercased(),
                                           stand: stand.uppercased(), registration: registration.uppercased(),
                                           targetOffBlock: hasTarget ? target : nil)
                        t.hasDangerousGoods = dangerousGoods
                        onCreate(t)
                        dismiss()
                    }
                    .disabled(flight.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
