import Charts
import SwiftUI

/// The first screen: is the ramp safe to work, what is the weather doing, and what is
/// coming in next.
struct NowView: View {
    @Environment(AirportStore.self) private var store
    @Environment(Router.self) private var router
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Clocks(iata: store.airport.iata, timeZone: store.timeZone)
                    RampStatusCard(status: store.rampStatus, error: store.snapshotError)
                    MapCard()
                    if let c = store.conditions { WeatherTiles(c: c, status: store.rampStatus) }
                    NextUpCard(title: "Next arrivals", dir: .inbound, board: store.arrivals) { router.showFlights(.inbound) }
                    NextUpCard(title: "Next departures", dir: .outbound, board: store.departures) { router.showFlights(.outbound) }
                    if let weather = store.snapshot?.weather, weather.count > 1 {
                        WindChart(hours: weather, timeZone: store.timeZone,
                                  cautionKt: store.thresholds.windCautionKt, warningKt: store.thresholds.windWarningKt)
                    }
                    if let c = store.conditions {
                        NotamsCard(all: store.notams, ramp: store.rampNotams, hasFeed: c.notamsInForce != nil,
                                   isAustralian: store.icao.hasPrefix("Y"))
                    }
                    if let c = store.conditions { RawWeatherCard(c: c) }
                    FreshnessFooter()
                }
                .padding()
            }
            .navigationTitle(store.airport.name)
            .navigationBarTitleDisplayMode(.inline)
            .rampToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .refreshable { await store.refresh(force: true) }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

/// Ramp status in one compact row: the level and the main hazard, tap for the details.
/// Warnings open expanded, since their instructions matter.
struct RampStatusCard: View {
    var status: RampStatus?
    /// Why there is no status, so a failed load does not look like a slow one.
    var error: String?
    @State private var expanded: Bool?

    var body: some View {
        let severity = status?.severity ?? .normal
        let hazards = status?.advisories ?? []
        let isOpen = expanded ?? (severity == .warning)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded = !isOpen }
            } label: {
                HStack(spacing: 12) {
                    if status == nil, error != nil {
                        Image(systemName: "exclamationmark.icloud").font(.title2)
                    } else if status == nil {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: severity.symbol).font(.title2)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status?.headline ?? (error == nil ? "Loading weather…" : "Airport data unavailable")).font(.headline)
                        Text(status == nil ? (error ?? summary(hazards)) : summary(hazards))
                            .font(.subheadline)
                            .lineLimit(1)
                            .opacity(0.9)
                    }
                    Spacer(minLength: 0)
                    if !hazards.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.bold))
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(hazards.isEmpty)
            .accessibilityHint(hazards.isEmpty ? "" : isOpen ? "Hides the details" : "Shows the details")

            if isOpen {
                ForEach(hazards) { a in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: a.symbol).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(.subheadline.weight(.semibold))
                            Text(a.detail).font(.footnote)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(a.severity >= .caution ? 0.2 : 0.1), in: .rect(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .foregroundStyle(status == nil ? Color.white : severity.onColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status == nil ? Color.gray.gradient : severity.color.gradient, in: .rect(cornerRadius: 16))
    }

    /// "Thunderstorms forecast +1 more", or the all-clear.
    private func summary(_ hazards: [Advisory]) -> String {
        guard status != nil else { return "Fetching the latest METAR" }
        guard let first = hazards.first else { return "No weather hazards in the latest METAR" }
        return first.title + (hazards.count > 1 ? "  +\(hazards.count - 1) more" : "")
    }
}

struct WeatherTiles: View {
    var c: Conditions
    var status: RampStatus?

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            Tile(title: "Wind",
                 value: WeatherText.wind(dir: c.windDirDeg, variable: c.windVariable, speed: c.windSpeedKt, gust: c.windGustKt),
                 detail: c.windDirDeg.map { "From \(compass($0))" },
                 systemImage: "wind",
                 tint: windTint)
            Tile(title: "Temperature",
                 value: c.tempC.map { "\(Int($0.rounded())) °C" } ?? "–",
                 detail: status?.feelsLikeC.map { "Feels like \(Int($0.rounded())) °C" },
                 systemImage: "thermometer.medium")
            Tile(title: "Weather",
                 value: WeatherText.describe(c.wxString) ?? "No significant weather",
                 detail: c.flightCategory.map { "Flight category \($0)" },
                 systemImage: "cloud.sun")
            Tile(title: "Visibility",
                 value: WeatherText.visibility(sm: c.visibilitySm, isLowerBound: c.visibilityIsLowerBound),
                 detail: c.ceilingFt.map { "Ceiling \($0.formatted()) ft" },
                 systemImage: "eye")
        }
    }

    private var windTint: Color {
        let wind = max(c.windSpeedKt ?? 0, c.windGustKt ?? 0)
        return wind >= 40 ? .red : wind >= 25 ? .orange : .primary
    }

    private func compass(_ deg: Int) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return points[Int((Double(deg) / 45).rounded()) % 8]
    }
}

/// The first few flights on a board, with a link to the full board.
struct NextUpCard: View {
    @Environment(AirportStore.self) private var store
    var title: String
    var dir: Direction
    var board: Board
    var openBoard: () -> Void

    var body: some View {
        // Still to handle: arrivals in the air, departures on the ground.
        let live = board.live.filter { dir == .inbound ? !$0.onGround : $0.onGround }
        let upcoming = Array((live + board.next).prefix(4))
        Card(title: title, systemImage: dir == .inbound ? "airplane.arrival" : "airplane.departure") {
            if upcoming.isEmpty {
                Text(store.snapshot == nil ? "Loading…" : "Nothing expected in the next \(Int(BoardBuilder.nextHours)) hours.")
                    .foregroundStyle(.secondary)
            }
            ForEach(upcoming) { e in
                HStack(spacing: 12) {
                    Text(e.time?.hhmm(store.timeZone, approx: e.timeIsApprox) ?? "--:--")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 64, alignment: .leading)
                    FlightCode(iata: e.flightIata, callsign: e.callsign)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(e.other ?? "–").font(.headline)
                        if e.phase == .live { StatusPill(rag: e.rag, text: e.status) }
                        else { Text("Expected").font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button(action: openBoard) {
                Label("All \(dir == .inbound ? "arrivals" : "departures")", systemImage: "chevron.right")
            }
            .buttonStyle(BigButtonStyle(filled: false))
        }
    }
}

struct WindChart: View {
    var hours: [HourlyWeather]
    var timeZone: TimeZone
    var cautionKt: Int
    var warningKt: Int

    var body: some View {
        Card(title: "Wind, last 24 hours (kt)", systemImage: "chart.xyaxis.line") {
            Chart {
                ForEach(hours) { h in
                    if let speed = h.windSpeedKt {
                        LineMark(x: .value("Time", h.hourUtc), y: .value("Wind", speed), series: .value("Series", "Wind"))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                    }
                    if let gust = h.windGustKt {
                        PointMark(x: .value("Time", h.hourUtc), y: .value("Gust", gust))
                            .foregroundStyle(.orange)
                            .symbolSize(40)
                    }
                }
                RuleMark(y: .value("Caution", cautionKt))
                    .foregroundStyle(.orange.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("\(cautionKt) kt").font(.caption2).foregroundStyle(.orange)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(LocalTime.hhmm(date, timeZone)) }
                    }
                }
            }
            .chartYScale(domain: 0...max(Double(cautionKt) + 5, Double(hours.compactMap { $0.windGustKt ?? $0.windSpeedKt }.max() ?? 0) + 5))
            .frame(height: 180)
            HStack(spacing: 16) {
                Label("Wind", systemImage: "line.diagonal").foregroundStyle(.blue)
                Label("Gusts", systemImage: "circle.fill").foregroundStyle(.orange)
            }
            .font(.caption)
        }
    }
}

struct NotamsCard: View {
    var all: [Notam]
    var ramp: [Notam]
    var hasFeed: Bool
    var isAustralian: Bool
    @State private var showAll = false
    @State private var expanded: Set<String> = []

    var body: some View {
        let shown = showAll ? all : ramp
        Card(title: "NOTAMs in force", systemImage: "exclamationmark.bubble") {
            if !hasFeed {
                Text(isAustralian
                     ? "No NOTAM feed: Airservices publishes NOTAMs only to registered users. Check NAIPS or your briefing."
                     : "The NOTAM feed for this airport hasn't loaded. Check your briefing.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Show", selection: $showAll) {
                    Text("Apron & taxiway (\(ramp.count))").tag(false)
                    Text("All (\(all.count))").tag(true)
                }
                .pickerStyle(.segmented)
                if shown.isEmpty {
                    Text(showAll ? "None in force." : "No apron or taxiway NOTAMs in force.").foregroundStyle(.secondary)
                }
                ForEach(shown) { n in
                    let isOpen = expanded.contains(n.id)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text((n.category ?? "uncategorised").replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.orange.opacity(0.2), in: .capsule)
                            Text(n.number ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(validity(n)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(isOpen ? (n.rawText ?? n.body ?? "") : (n.body ?? n.rawText ?? ""))
                            .font(.callout.monospaced())
                            .lineLimit(isOpen ? nil : 4)
                    }
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                    .onTapGesture {
                        if isOpen { expanded.remove(n.id) } else { expanded.insert(n.id) }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(isOpen ? "Shows less" : "Shows the full NOTAM")
                    Divider()
                }
            }
        }
    }

    private func validity(_ n: Notam) -> String {
        if n.isPermanent == true { return "Permanent" }
        guard let end = n.endsAt else { return "Until further notice" }
        // NOTAM times are UTC.
        var day = Date.FormatStyle.dateTime.day().month(.abbreviated)
        day.timeZone = .gmt
        return "Until \(end.formatted(day)) \(LocalTime.hhmm(end, .gmt))Z" + (n.isEstimated == true ? " (est)" : "")
    }
}

struct RawWeatherCard: View {
    var c: Conditions

    var body: some View {
        Card(title: "METAR and TAF", systemImage: "text.alignleft") {
            if let metar = c.metarRaw {
                Text(metar).font(.callout.monospaced()).textSelection(.enabled)
                if let age = c.metarAgeMin {
                    Text("Observed \(age.formattedAge) ago").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let taf = c.tafRaw {
                Divider()
                Text(taf).font(.callout.monospaced()).textSelection(.enabled)
            }
        }
    }
}
