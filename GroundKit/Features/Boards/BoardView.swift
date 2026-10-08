import SwiftData
import SwiftUI

/// The Flights tab: arrivals or departures, picked at the top. Each shows the live feed now,
/// expected in the next 6 hours, and the last 3 hours. With `fixedDir`, one board enlarged
/// from Now, with a Done button.
struct BoardView: View {
    @Environment(AirportStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    var fixedDir: Direction? = nil
    @State private var search = ""
    @State private var showPast = false
    @State private var selected: BoardEntry?

    private var dir: Direction { fixedDir ?? router.flightsDir }
    private var board: Board { dir == .inbound ? store.arrivals : store.departures }
    private var arriving: Bool { dir == .inbound }

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            List {
                if fixedDir == nil {
                    Picker("Show", selection: $router.flightsDir) {
                        Text("Arrivals").tag(Direction.inbound)
                        Text("Departures").tag(Direction.outbound)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if board.isEmpty {
                    ContentUnavailableView(
                        store.snapshot == nil ? "Loading flights" : "No flights",
                        systemImage: arriving ? "airplane.arrival" : "airplane.departure",
                        description: Text(store.snapshot == nil ? "Fetching the airport's flights."
                                          : "No regular flights in the next \(Int(BoardBuilder.nextHours)) hours and none on the live feed."))
                }
                let airborne = filtered(board.live.filter { !$0.onGround })
                let ground = filtered(board.live.filter(\.onGround))
                if arriving {
                    section("Inbound now", footer: "ETA from live position and speed, plus this airport's usual time inside 50 NM.", airborne)
                    section("On the ground", footer: nil, ground)
                } else {
                    section("On the ground", footer: "Times are the flight's usual departure; late when still here after it.", ground)
                    section("Just departed", footer: nil, airborne)
                }
                section("Expected, next \(Int(BoardBuilder.nextHours)) hours",
                        footer: "Regular flights by their usual time over the last 30 days. There is no live timetable.",
                        filtered(board.next))
                let past = filtered(board.past)
                if !past.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showPast) {
                            ForEach(past) { row($0) }
                        } label: {
                            Text("Last \(Int(BoardBuilder.pastHours)) hours (\(past.count))").font(.headline)
                        }
                    }
                }
                Section { FreshnessFooter() }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Flight, callsign or airport")
            .navigationTitle(fixedDir == nil ? "Flights" : arriving ? "Arrivals" : "Departures")
            .rampToolbar()
            .toolbar {
                if fixedDir != nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .refreshable { await store.refresh(force: true) }
            .sheet(item: $selected) { FlightDetailView(entry: $0) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, footer: String?, _ rows: [BoardEntry]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row($0) }
            } header: {
                Text("\(title) (\(rows.count))").font(.headline)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func row(_ e: BoardEntry) -> some View {
        Button { selected = e } label: { BoardRow(entry: e, timeZone: store.timeZone) }
            .buttonStyle(.plain)
    }

    private func filtered(_ rows: [BoardEntry]) -> [BoardEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { e in
            [e.flightIata, e.callsign, e.other, e.airline?.uppercased()].contains { $0?.contains(q) == true }
        }
    }
}

struct BoardRow: View {
    var entry: BoardEntry
    var timeZone: TimeZone

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.time?.hhmm(timeZone, approx: entry.timeIsApprox) ?? "--:--")
                    .font(.title2.weight(.bold).monospacedDigit())
                if let eta = entry.etaMin {
                    Text("in \(Int(eta.rounded())) min").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    FlightCode(iata: entry.flightIata, callsign: entry.callsign)
                    if entry.freighter { FreighterTag() }
                    Spacer()
                    Text(entry.other ?? "–").font(.title3.weight(.semibold))
                }
                HStack {
                    if entry.phase == .live {
                        StatusPill(rag: entry.rag, text: entry.status)
                    } else {
                        Text(entry.status).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let dist = entry.distNm, !entry.onGround {
                        Text("\(Int(dist.rounded())) NM").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 64)
        .contentShape(.rect)
        .opacity(entry.phase == .past ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows flight details")
    }
}

struct FlightDetailView: View {
    @Environment(AirportStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var entry: BoardEntry

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.label).font(.system(size: 44, weight: .heavy, design: .rounded))
                        if let airline = entry.airline { Text(airline).font(.title3) }
                        if entry.freighter { FreighterTag() }
                        if let other = entry.other {
                            Text("\(entry.dir == .inbound ? "From" : "To") \(other)")
                                .font(.title2.weight(.semibold))
                        }
                        if entry.phase == .live { StatusPill(rag: entry.rag, text: entry.status) }
                        else { Text(entry.status).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4)
                }
                Section("Times (\(store.airport.iata) local)") {
                    if let time = entry.time {
                        LabeledContent(timeLabel, value: time.hhmm(store.timeZone, approx: entry.timeIsApprox))
                    }
                    if let eta = entry.etaMin { LabeledContent("Minutes to landing", value: "\(Int(eta.rounded()))") }
                    if let usual = entry.usual {
                        LabeledContent(entry.dir == .inbound ? "Usual arrival" : "Usual departure", value: usual)
                    }
                }
                if let a = entry.aircraft {
                    Section("Live position") {
                        if let dist = entry.distNm { LabeledContent("Distance", value: "\(Int(dist.rounded())) NM") }
                        LabeledContent("Altitude", value: a.onGround ? "On the ground" : "\(Int(a.altFt ?? 0).formatted()) ft")
                        if let speed = a.speedKt { LabeledContent("Ground speed", value: "\(Int(speed)) kt") }
                        if let vs = a.vrateFpm, !a.onGround, abs(vs) > 200 {
                            LabeledContent(vs < 0 ? "Descending" : "Climbing", value: "\(Int(abs(vs)).formatted()) ft/min")
                        }
                    }
                }
                Section("Identifiers") {
                    LabeledContent("Callsign", value: entry.callsign)
                    if let hex = entry.aircraft?.icao24 { LabeledContent("Transponder (hex)", value: hex.uppercased()) }
                }
                Section {
                    Button {
                        let t = Turnaround(airportIcao: store.icao, callsign: entry.callsign,
                                           flightIata: entry.flightIata, airline: entry.airline,
                                           origin: entry.dir == .inbound ? entry.other : nil,
                                           destination: entry.dir == .outbound ? entry.other : nil)
                        context.insert(t)
                        dismiss()
                        router.open(t)
                    } label: {
                        Label("Start turnaround", systemImage: "checklist")
                    }
                    .buttonStyle(BigButtonStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Delay compares the estimate with this flight's usual time over the last 30 days; there is no live timetable.")
                }
            }
            .navigationTitle(entry.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var timeLabel: String {
        switch (entry.dir, entry.phase, entry.onGround) {
        case (.inbound, .live, false): "Estimated arrival"
        case (.inbound, _, true), (.inbound, .past, _): "Landed"
        case (.outbound, .live, false), (.outbound, .past, _): "Departed"
        default: "Expected"
        }
    }
}
