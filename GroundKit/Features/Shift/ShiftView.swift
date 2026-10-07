import SwiftData
import SwiftUI

/// The worker's own shift: time on and breaks, fatigue from sleep and rest, heat strain
/// from heart rate, activity, noise and water from Health, weighed against the weather;
/// a summary when it ends; and handover notes for the next crew.
struct ShiftView: View {
    @Environment(AirportStore.self) private var store
    @Environment(HealthService.self) private var health
    @Environment(\.modelContext) private var context
    @Query(sort: \Shift.startedAt, order: .reverse) private var shifts: [Shift]
    @AppStorage("age") private var age = 0
    @State private var confirmEnd = false
    @State private var waterLogged = 0
    @State private var breaksLogged = 0

    private var active: Shift? { shifts.first(where: \.isActive) }
    /// The shift just finished keeps its summary on screen this long, until the next one starts.
    private static let summaryShown: TimeInterval = 12 * 3600

    var body: some View {
        NavigationStack {
            ScrollView {
                TimelineView(.everyMinute) { ctx in
                    VStack(alignment: .leading, spacing: 16) {
                        content(now: ctx.date)
                        HandoverCard()
                        if !shifts.filter({ !$0.isActive }).isEmpty { history }
                        Text("Guidance only, not medical advice. Rosters, your employer's fatigue, heat, cold and noise procedures, and your supervisor decide.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            .navigationTitle("Shift")
            .rampToolbar()
            .task(id: active?.startedAt) { await pollHealth() }
            .refreshable { await health.refresh(since: active?.startedAt) }
            .sensoryFeedback(.success, trigger: waterLogged)
            .sensoryFeedback(.success, trigger: breaksLogged)
            .confirmationDialog("End your shift?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End shift", role: .destructive) { Task { await endShift() } }
            } message: {
                Text("A summary of the shift is kept with it.")
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let feelsLike = store.rampStatus?.feelsLikeC
        let fatigue = Fatigue.assess(sleep: health.sleep, shifts: shifts.map { WorkSpan(start: $0.startedAt, end: $0.endedAt) },
                                     dutyStart: active?.startedAt, now: now)
        if let shift = active {
            if let strain = HeatStrain.assess(health.recentHeartRate, feelsLikeC: feelsLike, age: age > 0 ? age : nil, now: now) {
                FindingBanner(finding: strain)
            }
            clockCard(shift, now: now)
            FatigueCard(summary: fatigue, onDuty: true)
            waterCard(shift: shift, hours: now.timeIntervalSince(shift.startedAt) / 3600, feelsLike: feelsLike, healthMl: health.stats.waterMl)
            healthCard(shift)
            Button("End shift", systemImage: "stop.fill") { confirmEnd = true }
                .buttonStyle(BigButtonStyle(tint: .red, filled: false))
        } else {
            if let last = shifts.first(where: { !$0.isActive }), let end = last.endedAt, last.summary != nil,
               now.timeIntervalSince(end) < Self.summaryShown {
                SummaryCard(shift: last, timeZone: store.timeZone)
            }
            FatigueCard(summary: fatigue, onDuty: false)
            startCard
        }
    }

    private var startCard: some View {
        Card(title: "Not on shift", systemImage: "person.badge.clock") {
            Text("Start a shift to track time on the ramp and breaks, steps, heart rate, noise and water from Health.")
                .foregroundStyle(.secondary)
            Button("Start shift at \(store.airport.iata)", systemImage: "play.fill") {
                context.insert(Shift(airportIcao: store.icao))
            }
            .buttonStyle(BigButtonStyle(tint: .green))
        }
    }

    private func clockCard(_ shift: Shift, now: Date) -> some View {
        let since = shift.workingSince
        return Card(title: "On shift since \(shift.startedAt.hhmm(store.timeZone))", systemImage: "clock") {
            Text(hm(now.timeIntervalSince(shift.startedAt)))
                .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
            Text((shift.breaks.isEmpty ? "No break yet" : "Last break \(since.hhmm(store.timeZone))")
                 + " · working \(hm(now.timeIntervalSince(since)))")
                .font(.body).foregroundStyle(.secondary)
            if ShiftAdvice.breakDue(workingSince: since, now: now) {
                Label("Time for a break and a drink?", systemImage: "cup.and.saucer")
                    .font(.headline).foregroundStyle(.orange)
            }
            Button("Log a break now", systemImage: "cup.and.saucer") {
                shift.breaks.append(.now)
                breaksLogged += 1
            }
            .buttonStyle(BigButtonStyle(tint: .orange, filled: false))
        }
    }

    private func waterCard(shift: Shift, hours: Double, feelsLike: Double?, healthMl: Double?) -> some View {
        let perHour = ShiftAdvice.waterPerHourMl(feelsLikeC: feelsLike)
        let target = ShiftAdvice.waterTargetMl(feelsLikeC: feelsLike, hoursOnShift: hours)
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

    @ViewBuilder
    private func healthCard(_ shift: Shift) -> some View {
        let s = health.stats
        if !health.isAvailable {
            Card(title: "Health", systemImage: "heart") {
                Text("Health isn't available on this device.").foregroundStyle(.secondary)
            }
        } else if !health.hasRequestedAccess {
            Card(title: "Connect Health", systemImage: "heart") {
                Text("Allow GroundKit to read activity, heart rate, sleep and sound levels, and save the water you log.")
                    .foregroundStyle(.secondary)
                Button("Connect Health", systemImage: "heart.fill") {
                    Task {
                        await health.requestAccess()
                        await health.refresh(since: shift.startedAt)
                    }
                }
                .buttonStyle(BigButtonStyle(tint: .pink))
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                Tile(title: "Steps", value: s.steps.map { Int($0).formatted() } ?? "–",
                     detail: s.distanceKm.map { String(format: "%.1f km walked", $0) }, systemImage: "figure.walk")
                Tile(title: "Active energy", value: s.activeKcal.map { "\(Int($0)) kcal" } ?? "–",
                     detail: nil, systemImage: "flame")
                Tile(title: "Heart rate", value: s.heartRateLatest.map { "\(Int($0)) bpm" } ?? "–",
                     detail: heartRates(s.heartRateAverage, s.heartRateMax).map { "Average · peak \($0)" }, systemImage: "heart")
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
    }

    private var history: some View {
        Card(title: "Recent shifts", systemImage: "calendar") {
            ForEach(shifts.filter { !$0.isActive }.prefix(7)) { s in
                HStack {
                    Text(s.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    Text(s.airportIcao).foregroundStyle(.secondary)
                    Spacer()
                    Text(hm(s.duration) + (s.summary?.steps.map { " · \(Int($0).formatted()) steps" } ?? ""))
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

    /// Ends the shift and keeps a summary of it, with Health's latest totals.
    private func endShift() async {
        guard let shift = active else { return }
        let now = Date.now
        await health.refresh(since: shift.startedAt)
        let s = health.stats
        let feelsLike = store.rampStatus?.feelsLikeC
        shift.summary = ShiftSummary(
            steps: s.steps, distanceKm: s.distanceKm, activeKcal: s.activeKcal,
            heartRateAverage: s.heartRateAverage, heartRateMax: s.heartRateMax,
            waterMl: max(shift.waterMl, s.waterMl ?? 0),
            waterTargetMl: ShiftAdvice.waterTargetMl(feelsLikeC: feelsLike, hoursOnShift: now.timeIntervalSince(shift.startedAt) / 3600),
            breaks: shift.breaks.count,
            longestWithoutBreak: ShiftAdvice.longestStretch(start: shift.startedAt, breaks: shift.breaks, end: now),
            // Through assess, so no sleep recorded stays unknown rather than none.
            sleep24h: Fatigue.assess(sleep: health.sleep, shifts: [], dutyStart: shift.startedAt, now: now).sleep24h)
        shift.endedAt = now
    }

    /// Health every 2 minutes while the tab is open: the shift's totals on shift, and sleep
    /// either way, as a check before starting one.
    private func pollHealth() async {
        let start = active?.startedAt
        await health.checkForNewTypes()
        while !Task.isCancelled {
            await health.refresh(since: start)
            try? await Task.sleep(for: .seconds(120))
        }
    }
}

/// "7 h 5 min".
private func hm(_ t: TimeInterval) -> String {
    Duration.seconds(max(0, t)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

/// "112 · 151 bpm", nil when neither is known.
private func heartRates(_ avg: Double?, _ max: Double?) -> String? {
    guard avg != nil || max != nil else { return nil }
    return "\(avg.map { "\(Int($0))" } ?? "–") · \(max.map { "\(Int($0))" } ?? "–") bpm"
}

/// A fatigue or heat-strain finding, coloured and marked by severity.
struct FindingBanner: View {
    var finding: Finding

    var body: some View {
        let tint: Color = finding.severity == .warning ? .red : .orange
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.severity.symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityLabel(finding.severity == .warning ? "Warning" : "Caution")
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.headline).foregroundStyle(tint)
                Text(finding.detail).font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.14), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

/// Sleep before duty (from Health), rest since the last shift and hours this week, with any
/// findings. Before a shift it is a fit-for-duty check.
private struct FatigueCard: View {
    @Environment(HealthService.self) private var health
    var summary: Fatigue.Summary
    var onDuty: Bool

    var body: some View {
        let f = summary
        Card(title: "Fatigue", systemImage: "bed.double") {
            Text(onDuty ? "Sleep in the 24 and 48 h before this shift" : "Before you start: sleep in the last 24 and 48 h")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                Tile(title: "Sleep, 24 h", value: f.sleep24h.map(hm) ?? "–", systemImage: "moon.zzz")
                Tile(title: "Sleep, 48 h", value: f.sleep48h.map(hm) ?? "–", systemImage: "moon.zzz")
                Tile(title: "Awake for", value: f.awake.map(hm) ?? "–", systemImage: "sun.max")
                Tile(title: onDuty ? "Rest before shift" : "Rest since shift", value: f.rest.map(hm) ?? "–", systemImage: "bed.double")
            }
            Text("\(hm(f.week)) worked in the last 7 days.").font(.subheadline).foregroundStyle(.secondary)
            if !f.findings.isEmpty {
                ForEach(f.findings, id: \.self) { FindingBanner(finding: $0) }
            } else if f.sleep24h != nil {
                Label("Sleep and rest look fine.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if health.hasRequestedAccess && f.sleep24h == nil {
                Text("No sleep recorded in Health in the last 48 h. An Apple Watch or a sleep app that saves sleep to Health turns on the sleep checks.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if health.isAvailable && (!health.hasRequestedAccess || health.canAskForMore) {
                Button("Allow sleep from Health for the sleep checks") {
                    Task {
                        await health.requestAccess()
                        await health.refresh(since: nil)
                    }
                }
                .controlSize(.large)
            }
        }
    }
}

/// How the last shift went, from the summary kept when it ended.
private struct SummaryCard: View {
    var shift: Shift
    var timeZone: TimeZone

    var body: some View {
        if let m = shift.summary, let end = shift.endedAt {
            Card(title: "Shift summary", systemImage: "list.clipboard") {
                Text("\(shift.startedAt.hhmm(timeZone))–\(end.hhmm(timeZone)) at \(shift.airportIcao)")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    Tile(title: "On shift", value: hm(end.timeIntervalSince(shift.startedAt)), systemImage: "clock")
                    Tile(title: "Breaks", value: "\(m.breaks)", detail: "Longest stretch \(hm(m.longestWithoutBreak))",
                         systemImage: "cup.and.saucer")
                    Tile(title: "Water", value: "\(Int(m.waterMl.rounded())) ml",
                         detail: m.waterTargetMl.map { "of about \(Int(($0 / 50).rounded(.up)) * 50) ml" }, systemImage: "drop")
                    Tile(title: "Steps", value: m.steps.map { Int($0).formatted() } ?? "–",
                         detail: m.distanceKm.map { String(format: "%.1f km", $0) }, systemImage: "figure.walk")
                    Tile(title: "Heart rate", value: heartRates(m.heartRateAverage, m.heartRateMax) ?? "–",
                         detail: "Average · peak", systemImage: "heart")
                    Tile(title: "Active energy", value: m.activeKcal.map { "\(Int($0)) kcal" } ?? "–", systemImage: "flame")
                }
                ForEach(notes(m), id: \.self) { Text($0).font(.subheadline).foregroundStyle(.orange) }
            }
        }
    }

    private func notes(_ m: ShiftSummary) -> [String] {
        var out: [String] = []
        if let target = m.waterTargetMl, m.waterMl < target * 0.75 {
            out.append("You drank under three quarters of the water target. Rehydrate before your next shift.")
        }
        if m.longestWithoutBreak > ShiftAdvice.breakEvery + 30 * 60 {
            out.append("You worked over 2½ hours without a logged break.")
        }
        if let sleep = m.sleep24h, sleep < Fatigue.minSleep24h {
            out.append("You started on under 5 h sleep. Aim for a full sleep before the next one.")
        }
        return out
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
