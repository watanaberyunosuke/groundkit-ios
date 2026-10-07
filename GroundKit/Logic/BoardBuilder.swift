import Foundation

// Arrival and departure boards from live ADS-B positions plus each callsign's last 30
// days, ported from the Dive (dives/airport_conditions/index.tsx: placed, boardLive,
// useFeedMemory, buildBoard) so the app and the dashboard agree.
//
// Live ADS-B carries no origin, destination or schedule, so direction and "usual time"
// come from the callsign's history at the airport, and delay is a proxy: the estimated
// arrival (or take-off) against the flight's usual local time.

/// Delay status. Bands follow the 15-minute on-time convention.
nonisolated enum Rag: Sendable, Hashable {
    case green, amber, red, unknown

    init(delay: Double?) {
        guard let delay else { self = .unknown; return }
        self = delay < 15 ? .green : delay < 45 ? .amber : .red
    }

    static func text(delay: Double?) -> String {
        guard let delay else { return "No usual time" }
        if delay < -15 { return "Early \(Int((-delay).rounded())) min" }
        if delay < 15 { return "On time" }
        return "Late \(Int(delay.rounded())) min"
    }
}

nonisolated struct HistoryIndex: Sendable {
    private(set) var byCallsign: [String: [Direction: CallsignHistory]] = [:]

    init(_ rows: [CallsignHistory]) {
        for row in rows { byCallsign[row.callsign, default: [:]][row.dir] = row }
    }

    subscript(callsign: String) -> [Direction: CallsignHistory]? { byCallsign[callsign] }

    func flightIata(_ callsign: String) -> String? {
        byCallsign[callsign]?.values.lazy.compactMap(\.flightNumberIata).first
    }

    func airline(_ callsign: String) -> String? {
        byCallsign[callsign]?.values.lazy.compactMap(\.airlineName).first
    }

    /// Tagged by the API as flown by an all-cargo operator.
    func isFreighter(_ callsign: String) -> Bool {
        byCallsign[callsign]?.values.contains { $0.isFreighter == true } ?? false
    }
}

/// A live aircraft placed relative to the airport.
nonisolated struct PlacedAircraft: Sendable, Identifiable, Hashable {
    enum Kind: Sendable, Hashable {
        case inbound, outbound, ground, other

        /// The API's `dir`.
        init?(api: String?) {
            switch api {
            case "inbound": self = .inbound
            case "outbound": self = .outbound
            case "ground": self = .ground
            case "other": self = .other
            default: return nil
            }
        }
    }

    var aircraft: LiveAircraft
    var kind: Kind
    var other: String?
    var flightIata: String?
    var airline: String?
    var distNm: Double
    /// Inbound and airborne only.
    var etaMin: Double?
    var usual: String?
    var delayMin: Double?
    var rag: Rag
    /// Estimated arrival (inbound) or take-off (outbound).
    var eventAt: Date?

    var label: String { flightIata ?? aircraft.callsign ?? aircraft.icao24 ?? "Unknown" }
    var id: String { aircraft.icao24 ?? label }
}

/// A recognised flight on the live feed, with its direction settled (aircraft on the
/// ground are assigned one from their usual times).
nonisolated struct BoardLive: Sendable, Hashable {
    var callsign: String
    var dir: Direction
    var flightIata: String?
    var airline: String?
    var other: String?
    var usual: String?
    var usualAt: Date?
    var onGround: Bool
    var distNm: Double
    var eventAt: Date?
    var etaMin: Double?
    var rag: Rag
    var statusNote: String?
    var aircraft: LiveAircraft
    /// Tagged by the API (is_freighter). Passenger flights may carry belly cargo too.
    var freighter: Bool
}

/// Direction of each airborne aircraft at the last fix, by transponder address. An arrival
/// stays inbound until it lands, though downwind legs and holds point it away from the
/// airport, and a departure stays outbound. The API cannot do this, as it keeps nothing
/// between calls.
nonisolated struct DirectionMemory: Sendable {
    private(set) var byAircraft: [String: PlacedAircraft.Kind] = [:]

    subscript(icao24: String) -> PlacedAircraft.Kind? { byAircraft[icao24] }

    mutating func remember(_ icao24: String, _ kind: PlacedAircraft.Kind) {
        byAircraft[icao24] = kind == .inbound || kind == .outbound ? kind : nil
    }
}

/// What the feed has shown of each flight since the app started, so flights that landed
/// or flew out of range stay on the board for a few hours.
nonisolated struct FeedMemory: Sendable {
    struct Remembered: Sendable {
        var row: BoardLive
        var lastAt: Date
        var goneAt: Date?
        var landedAt: Date?
    }

    private(set) var byCallsign: [String: Remembered] = [:]

    mutating func update(_ rows: [BoardLive], at: Date) {
        for row in rows {
            let old = byCallsign[row.callsign]
            // Airborne inbound at the last fix, on the ground here now: it landed in between.
            let landed = row.dir == .inbound && row.onGround && old.map { !$0.row.onGround } == true
            byCallsign[row.callsign] = Remembered(row: row, lastAt: at, goneAt: nil,
                                                  landedAt: landed ? at : old?.landedAt)
        }
        // Not in this fix: it left the feed (landed and shut down, or out of range).
        for (key, m) in byCallsign where m.lastAt < at && m.goneAt == nil {
            byCallsign[key]?.goneAt = at
        }
        // Nothing older than the board shows is needed.
        let cutoff = at.addingTimeInterval(-(BoardBuilder.pastHours + 1) * 3600)
        byCallsign = byCallsign.filter { $0.value.lastAt >= cutoff }
    }

    func landedAt(_ callsign: String) -> Date? { byCallsign[callsign]?.landedAt }
}

nonisolated struct BoardEntry: Sendable, Identifiable, Hashable {
    enum Phase: Sendable, Hashable { case live, next, past }

    var phase: Phase
    var dir: Direction
    var callsign: String
    var flightIata: String?
    var airline: String?
    var other: String?
    var usual: String?
    /// Estimated, observed or usual time; nil when unknown.
    var time: Date?
    var timeIsApprox: Bool
    var status: String
    var rag: Rag
    var onGround: Bool
    var distNm: Double?
    var etaMin: Double?
    var aircraft: LiveAircraft?
    /// Tagged by the API (is_freighter). Passenger flights may carry belly cargo too.
    var freighter: Bool = false

    var id: String { "\(phase)|\(dir)|\(callsign)" }
    var label: String { flightIata ?? callsign }
}

nonisolated struct Board: Sendable {
    /// On the live feed now: airborne within 500 NM, or on the ground at the airport.
    var live: [BoardEntry] = []
    /// Regular flights not yet seen, by usual time, next 6 hours.
    var next: [BoardEntry] = []
    /// Landed or departed in the last 3 hours, or presumed to have.
    var past: [BoardEntry] = []

    var isEmpty: Bool { live.isEmpty && next.isEmpty && past.isEmpty }
    static let empty = Board()
}

nonisolated struct BoardBuilder: Sendable {
    static let pastHours = 3.0
    static let nextHours = 6.0
    /// Seen on at least this many of the last 14 days to be predicted.
    static let regularDays = 7

    var lat: Double
    var lon: Double
    var timeZone: TimeZone
    var history: HistoryIndex
    /// Median minutes inside 50 NM at this airport over 30 days; fallbacks until data builds up.
    var terminalArrMin: Double
    var terminalDepMin: Double

    init(lat: Double, lon: Double, timeZone: TimeZone, history: HistoryIndex, medians: Medians) {
        self.lat = lat
        self.lon = lon
        self.timeZone = timeZone
        self.history = history
        terminalArrMin = medians.arrivalTerminalMinutes ?? 15
        terminalDepMin = medians.departureTerminalMinutes ?? 10
    }

    // MARK: Live aircraft

    func place(_ aircraft: [LiveAircraft], now: Date) -> [PlacedAircraft] {
        var directions = DirectionMemory()
        return place(aircraft, now: now, directions: &directions)
    }

    /// Direction comes from the API (`dir`, for this fix) or, without it, the same rules
    /// here; an airborne aircraft then keeps its direction from earlier fixes until it lands.
    func place(_ aircraft: [LiveAircraft], now: Date, directions: inout DirectionMemory) -> [PlacedAircraft] {
        aircraft.map { a in
            let km = Geo.distKm(a.lat, a.lon, lat, lon)
            let h = a.callsign.flatMap { history[$0] }
            // Angle between the aircraft's track and the bearing to the airport: 0 = heading
            // straight at it, 180 = straight away.
            let bearing = Geo.bearingDeg(a.lat, a.lon, lat, lon)
            let off = abs(((a.trackDeg ?? 0) - bearing + 540).truncatingRemainder(dividingBy: 360) - 180)
            // Beyond 30 NM, history must agree with geometry: a reused callsign flying away is
            // not inbound. Closer in, aircraft manoeuvre on approach and departure, so trust history.
            let near = km < 30 * Geo.kmPerNm
            let hasIn = h?[.inbound] != nil, hasOut = h?[.outbound] != nil
            // Near the airport a clear descent or climb says more than the heading, which
            // turns away from the airport on downwind and in holds.
            let descending = near && (a.vrateFpm ?? 0) <= -300
            let climbing = near && (a.vrateFpm ?? 0) >= 300
            var kind = PlacedAircraft.Kind.other
            if let fromAPI = PlacedAircraft.Kind(api: a.dir) { kind = fromAPI }
            else if a.onGround { kind = km < 8 ? .ground : .other }
            else if hasIn && hasOut { kind = descending ? .inbound : climbing ? .outbound : off < 90 ? .inbound : .outbound }
            else if hasIn && (near || off < 110) { kind = .inbound }
            else if hasOut && (near || off > 70) { kind = .outbound }
            if let id = a.icao24 {
                if !a.onGround, let prev = directions[id], prev == .inbound ? hasIn : hasOut {
                    // An arrival first seen level on downwind, or a departure coming back. A
                    // climb never overrides inbound, so a go-around stays an arrival.
                    kind = prev == .outbound && descending && hasIn ? .inbound : prev
                }
                directions.remember(id, kind)
            }

            let seen: CallsignHistory? = switch kind {
            case .inbound: h?[.inbound]
            case .outbound: h?[.outbound]
            default: nil
            }
            // Minutes between the aircraft and the runway: at current ground speed to / from
            // the 50 NM ring, plus the airport's median time inside it (approach, holding,
            // climb-out), pro rata when already inside. Straight-line time alone reads early.
            let speed = a.speedKt ?? 0
            let terminal = kind == .inbound ? terminalArrMin : terminalDepMin
            let legMin: Double? = speed < 60 ? nil
                : km > Geo.terminalKm ? (km - Geo.terminalKm) / (speed * Geo.kmPerNm) * 60 + terminal
                : terminal * (km / Geo.terminalKm)
            let directional = kind == .inbound || kind == .outbound
            // Inbound: ETA against usual arrival. Outbound: estimated take-off (now minus that
            // time) against usual departure.
            let at = directional ? legMin.map { now.addingTimeInterval((kind == .inbound ? 1 : -1) * $0 * 60) } : nil
            let delay: Double? = if let seen, let at {
                LocalTime.wrap(LocalTime.minuteOfDay(at, timeZone) - seen.usualMin)
            } else { nil }
            return PlacedAircraft(
                aircraft: a, kind: kind, other: seen?.other,
                flightIata: a.callsign.flatMap(history.flightIata),
                airline: a.callsign.flatMap(history.airline),
                distNm: km / Geo.kmPerNm,
                etaMin: kind == .inbound ? legMin : nil,
                usual: seen.map { LocalTime.hhmm(minutes: $0.usualMin) },
                delayMin: delay, rag: Rag(delay: delay), eventAt: at)
        }
    }

    /// Recognised flights on the feed. An aircraft on the ground here is the arrival or
    /// departure whose usual time is nearest now: arrivals up to 3 h after their usual
    /// time (taxiing in, parked with the transponder on), departures within 3 h of theirs.
    func boardLive(_ placed: [PlacedAircraft], now: Date) -> [BoardLive] {
        let nowMin = LocalTime.minuteOfDay(now, timeZone)
        let window = Self.pastHours * 60
        var rows: [BoardLive] = []
        for p in placed {
            guard let callsign = p.aircraft.callsign else { continue }
            func row(_ dir: Direction, other: String?, usual: Double?, rag: Rag, note: String?) -> BoardLive {
                BoardLive(callsign: callsign, dir: dir, flightIata: p.flightIata, airline: p.airline,
                          other: other, usual: usual.map { LocalTime.hhmm(minutes: $0) },
                          usualAt: usual.map { now.addingTimeInterval(LocalTime.wrap($0 - nowMin) * 60) },
                          onGround: p.aircraft.onGround, distNm: p.distNm, eventAt: p.eventAt,
                          etaMin: p.etaMin, rag: rag, statusNote: note, aircraft: p.aircraft,
                          freighter: p.aircraft.isFreighter ?? history.isFreighter(callsign))
            }
            switch p.kind {
            case .inbound, .outbound:
                let dir: Direction = p.kind == .inbound ? .inbound : .outbound
                let note = dir == .inbound || p.delayMin != nil ? Rag.text(delay: p.delayMin) : nil
                rows.append(row(dir, other: p.other, usual: history[callsign]?[dir]?.usualMin, rag: p.rag, note: note))
            case .ground:
                let h = history[callsign]
                let arr = h?[.inbound].map { LocalTime.wrap(nowMin - $0.usualMin) }  // minutes since usual arrival
                let dep = h?[.outbound].map { LocalTime.wrap($0.usualMin - nowMin) } // minutes to usual departure
                let arrOk = arr.map { $0 >= -30 && $0 <= window } ?? false
                let depOk = dep.map { $0 >= -window && $0 <= window } ?? false
                let dir: Direction? = arrOk && (!depOk || abs(arr!) <= abs(dep!)) ? .inbound : depOk ? .outbound : nil
                guard let dir, let seen = h?[dir] else { continue }
                // A departure still on the ground after its usual time is running late.
                let late = dir == .outbound && dep! < 0 ? -dep! : nil
                rows.append(row(dir, other: seen.other, usual: seen.usualMin,
                                rag: dir == .outbound ? Rag(delay: late ?? 0) : .unknown,
                                note: late.flatMap { $0 >= 15 ? "Late \(Int($0.rounded())) min" : nil }))
            case .other:
                continue
            }
        }
        return rows
    }

    // MARK: Boards

    func board(_ dir: Direction, live rows: [BoardLive], memory: FeedMemory, now: Date) -> Board {
        let arriving = dir == .inbound
        var board = Board()
        var placed = Set<String>()

        for r in rows where r.dir == dir {
            placed.insert(r.callsign)
            let landedAt = memory.landedAt(r.callsign)
            // Time shown: ETA (inbound, airborne), landing time seen on the feed (inbound, on
            // the ground), estimated take-off (outbound, airborne) or usual departure (on stand).
            let time: Date?, status: String, approx: Bool
            switch (arriving, r.onGround) {
            case (true, false): (time, status, approx) = (r.eventAt, r.statusNote ?? "Inbound", false)
            case (true, true): (time, status, approx) = (landedAt, landedAt == nil ? "On the ground" : "Landed", true)
            case (false, false):
                (time, status, approx) = (r.eventAt, r.statusNote ?? "Airborne", true)
            case (false, true): (time, status, approx) = (r.usualAt, r.statusNote ?? "On the ground", false)
            }
            board.live.append(BoardEntry(
                phase: .live, dir: dir, callsign: r.callsign, flightIata: r.flightIata, airline: r.airline,
                other: r.other, usual: r.usual, time: time, timeIsApprox: approx,
                status: status, rag: r.rag, onGround: r.onGround, distNm: r.distNm, etaMin: r.etaMin,
                aircraft: r.aircraft, freighter: r.freighter))
        }
        board.live.sort { ($0.time ?? .distantFuture, $0.distNm ?? 0) < ($1.time ?? .distantFuture, $1.distNm ?? 0) }

        // Past: seen, then gone. Inbound flights count as landed only if they were on the
        // ground or inside the terminal area when they went; further out it is a coverage gap.
        let cutoff = now.addingTimeInterval(-Self.pastHours * 3600)
        for m in memory.byCallsign.values {
            let r = m.row
            guard r.dir == dir, let goneAt = m.goneAt, !placed.contains(r.callsign) else { continue }
            if arriving && !r.onGround && r.distNm > Geo.terminalKm / Geo.kmPerNm { continue }
            if !arriving && r.onGround { continue } // switched off at the stand
            let when = arriving ? (m.landedAt ?? r.eventAt ?? goneAt) : (r.eventAt ?? goneAt)
            guard when >= cutoff else { continue }
            placed.insert(r.callsign)
            board.past.append(BoardEntry(
                phase: .past, dir: dir, callsign: r.callsign, flightIata: r.flightIata, airline: r.airline,
                other: r.other, usual: r.usual, time: when, timeIsApprox: true,
                status: arriving ? "Landed" : "Departed, \(r.distNm > 400 ? "out of 500 NM" : "off the feed")",
                rag: .unknown, onGround: r.onGround, distNm: nil, etaMin: nil, aircraft: nil,
                freighter: r.freighter))
        }

        // Not seen: regular flights by their usual time.
        let nowMin = LocalTime.minuteOfDay(now, timeZone)
        for (callsign, h) in history.byCallsign {
            guard let seen = h[dir], seen.days14 >= Self.regularDays, !placed.contains(callsign) else { continue }
            let delta = LocalTime.wrap(seen.usualMin - nowMin)
            guard delta >= -Self.pastHours * 60, delta <= Self.nextHours * 60 else { continue }
            let entry = BoardEntry(
                phase: delta < 0 ? .past : .next, dir: dir, callsign: callsign,
                flightIata: seen.flightNumberIata, airline: seen.airlineName, other: seen.other,
                usual: LocalTime.hhmm(minutes: seen.usualMin), time: now.addingTimeInterval(delta * 60),
                timeIsApprox: false,
                status: delta < 0 ? "Presumed \(arriving ? "landed" : "departed"), not seen live"
                    : arriving ? "Expected, not yet within 500 NM" : "Expected",
                rag: .unknown, onGround: false, distNm: nil, etaMin: nil, aircraft: nil,
                freighter: seen.isFreighter == true)
            if delta < 0 { board.past.append(entry) } else { board.next.append(entry) }
        }
        board.past.sort { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) } // newest first
        board.next.sort { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
        return board
    }
}
