import SwiftData
import SwiftUI

/// The worker's own shift: time on, activity, heart rate, noise and water from Health,
/// weighed against the weather; and handover notes for the next crew.
struct ShiftView: View {
    @Environment(AirportStore.self) private var store
    @Environment(HealthService.self) private var health
    @Environment(\.modelContext) private var context
    @Query(sort: \Shift.startedAt, order: .reverse) private var shifts: [Shift]
    @State private var confirmEnd = false
    @State private var waterLogged = 0

    private var active: Shift? { shifts.first(where: \.isActive) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let shift = active {
                        activeShift(shift)
                    } else {
                        startCard
                    }
                    HandoverCard()
                    if !shifts.filter({ !$0.isActive }).isEmpty { history }
                    Text("Guidance only, not medical advice. Follow your employer's heat, cold and noise procedures.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Shift")
            .rampToolbar()
            .task(id: active?.startedAt) { await pollHealth() }
            .refreshable { if let s = active { await health.refresh(since: s.startedAt) } }
            .sensoryFeedback(.success, trigger: waterLogged)
            .confirmationDialog("End your shift?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End shift", role: .destructive) { active?.endedAt = .now }
            }
        }
    }

    private var startCard: some View {
        Card(title: "Not on shift", systemImage: "person.badge.clock") {
            Text("Start a shift to track time on the ramp, steps, heart rate, noise and water from Health.")
                .foregroundStyle(.secondary)
            Button("Start shift at \(store.airport.iata)", systemImage: "play.fill") {
                context.insert(Shift(airportIcao: store.icao))
            }
            .buttonStyle(BigButtonStyle(tint: .green))
        }
    }

    @ViewBuilder
    private func activeShift(_ shift: Shift) -> some View {
        let s = health.stats
        let feelsLike = store.rampStatus?.feelsLikeC
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let hours = ctx.date.timeIntervalSince(shift.startedAt) / 3600
            Card(title: "On shift since \(shift.startedAt.hhmm(store.timeZone))", systemImage: "clock") {
                Text(Duration.seconds(ctx.date.timeIntervalSince(shift.startedAt))
                    .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                    .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                if hours >= 2 && Int(hours * 60) % 120 < 15 {
                    Label("Time for a break and a drink?", systemImage: "cup.and.saucer")
                        .font(.headline).foregroundStyle(.orange)
                }
            }
            waterCard(shift: shift, hours: hours, feelsLike: feelsLike, healthMl: s.waterMl)
        }
        if !health.isAvailable {
            Card(title: "Health", systemImage: "heart") {
                Text("Health isn't available on this device.").foregroundStyle(.secondary)
            }
        } else if !health.hasRequestedAccess {
            Card(title: "Connect Health", systemImage: "heart") {
                Text("Allow Ramp Ops to read activity, heart rate and sound levels, and save the water you log.")
                    .foregroundStyle(.secondary)
                Button("Connect Health", systemImage: "heart.fill") { Task { await health.requestAccess() ; await health.refresh(since: shift.startedAt) } }
                    .buttonStyle(BigButtonStyle(tint: .pink))
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                Tile(title: "Steps", value: s.steps.map { Int($0).formatted() } ?? "–",
                     detail: s.distanceKm.map { String(format: "%.1f km walked", $0) }, systemImage: "figure.walk")
                Tile(title: "Active energy", value: s.activeKcal.map { "\(Int($0)) kcal" } ?? "–",
                     detail: nil, systemImage: "flame")
                Tile(title: "Heart rate", value: s.heartRateLatest.map { "\(Int($0)) bpm" } ?? "–",
                     detail: s.heartRateAverage.map { "Average \(Int($0)) bpm" }, systemImage: "heart")
                Tile(title: "Noise", value: s.soundAverageDb.map { "\(Int($0)) dB" } ?? "Needs Apple Watch",
                     detail: s.soundMaxDb.map { "Peak \(Int($0)) dB" }, systemImage: "ear.badge.waveform",
                     tint: (s.soundAverageDb ?? 0) >= ShiftAdvice.hearingProtectionDb ? .red : .primary)
            }
            if let db = s.soundAverageDb, db >= ShiftAdvice.hearingProtectionDb {
                Label("Average noise \(Int(db)) dB this shift. Keep hearing protection on near engines and APUs.",
                      systemImage: "ear.trianglebadge.exclamationmark")
                    .font(.headline).foregroundStyle(.red)
            }
            if let error = health.lastError { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        Button("End shift", systemImage: "stop.fill") { confirmEnd = true }
            .buttonStyle(BigButtonStyle(tint: .red, filled: false))
    }

    private func waterCard(shift: Shift, hours: Double, feelsLike: Double?, healthMl: Double?) -> some View {
        let perHour = ShiftAdvice.waterPerHourMl(feelsLikeC: feelsLike)
        let target = max(perHour, perHour * hours)
        let drunk = max(shift.waterMl, healthMl ?? 0)
        return Card(title: "Water", systemImage: "drop.fill") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(drunk)) ml").font(.title.weight(.bold).monospacedDigit())
                Text("of about \(Int(target.rounded(.up) / 50) * 50) ml so far").foregroundStyle(.secondary)
            }
            ProgressView(value: min(drunk / target, 1)).tint(.blue)
            Text(feelsLike.map { "Feels like \(Int($0.rounded())) °C: aim for about \(Int(perHour)) ml an hour." }
                 ?? "Aim for about \(Int(perHour)) ml an hour.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach([250.0, 500.0], id: \.self) { ml in
                    Button("+\(Int(ml)) ml", systemImage: "drop") { Task { await logWater(ml, shift: shift) } }
                        .buttonStyle(BigButtonStyle(tint: .blue))
                }
            }
        }
    }

    private var history: some View {
        Card(title: "Recent shifts", systemImage: "calendar") {
            ForEach(shifts.filter { !$0.isActive }.prefix(7)) { s in
                HStack {
                    Text(s.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    Text(s.airportIcao).foregroundStyle(.secondary)
                    Spacer()
                    Text(Duration.seconds(s.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .monospacedDigit()
                }
                .font(.headline)
            }
        }
    }

    private func logWater(_ ml: Double, shift: Shift) async {
        shift.waterMl += ml
        waterLogged += 1
        if health.isAvailable, await health.logWater(ml: ml) {
            await health.refresh(since: shift.startedAt)
        }
    }

    private func pollHealth() async {
        guard let start = active?.startedAt else { return }
        while !Task.isCancelled {
            await health.refresh(since: start)
            try? await Task.sleep(for: .seconds(120))
        }
    }
}

/// Notes for the next crew at this airport, synced through iCloud.
struct HandoverCard: View {
    @Environment(AirportStore.self) private var store
    @Environment(\.modelContext) private var context
    @Query(sort: \HandoverNote.createdAt, order: .reverse) private var notes: [HandoverNote]
    @State private var draft = ""
    @State private var important = false

    var body: some View {
        let open = notes.filter { $0.airportIcao == store.icao && $0.resolvedAt == nil }
        Card(title: "Handover notes", systemImage: "note.text") {
            if open.isEmpty { Text("No open notes for \(store.airport.iata).").foregroundStyle(.secondary) }
            ForEach(open) { note in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: note.isImportant ? "exclamationmark.circle.fill" : "circle")
                        .foregroundStyle(note.isImportant ? .red : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.text).font(.body)
                        Text(note.createdAt.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { note.resolvedAt = .now }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityLabel("Mark note done")
                }
                Divider()
            }
            TextField("Equipment faults, closed stands, things to watch…", text: $draft, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Important", isOn: $important).fixedSize()
                Spacer()
                Button("Add note") {
                    context.insert(HandoverNote(airportIcao: store.icao, text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                                isImportant: important))
                    draft = ""
                    important = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
