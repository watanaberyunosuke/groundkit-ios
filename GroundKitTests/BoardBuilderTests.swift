import Foundation
import Testing
@testable import GroundKit

/// Sydney at 13:00 local (02:00Z; daylight saving from 4 October 2026).
private let sydney = TimeZone(identifier: "Australia/Sydney")!
private let now = try! Date("2026-10-06T02:00:00Z", strategy: .iso8601)
private let syd = (lat: -33.946, lon: 151.177)

private func history(_ callsign: String, _ dir: Direction, usual: String, days: Int = 10,
                     other: String? = "MEL", iata: String? = nil, freighter: Bool? = nil) -> CallsignHistory {
    let parts = usual.split(separator: ":").compactMap { Double($0) }
    return CallsignHistory(callsign: callsign, dir: dir, other: other, n: days, usualMin: parts[0] * 60 + parts[1],
                           days14: days, flightNumberIata: iata, airlineName: nil, isFreighter: freighter)
}

private func builder(_ rows: [CallsignHistory]) -> BoardBuilder {
    BoardBuilder(lat: syd.lat, lon: syd.lon, timeZone: sydney, history: HistoryIndex(rows),
                 medians: Medians(arrivalTerminalMinutes: 15, departureTerminalMinutes: 10))
}

/// An aircraft `km` north of the airport.
private func aircraft(_ callsign: String, kmNorth: Double, track: Double = 180, speed: Double = 300,
                      onGround: Bool = false, vrate: Double? = nil, dir: String? = nil) -> LiveAircraft {
    LiveAircraft(icao24: callsign.lowercased(), callsign: callsign, lon: syd.lon, lat: syd.lat + kmNorth / 111.2,
                 altFt: onGround ? 0 : 10_000, onGround: onGround, speedKt: onGround ? 0 : speed,
                 trackDeg: track, vrateFpm: vrate, dir: dir)
}

struct LocalTimeTests {
    @Test func wrapsAroundMidnight() {
        #expect(LocalTime.wrap(10 - 1430) == 20)   // 00:10 vs 23:50
        #expect(LocalTime.wrap(1430 - 10) == -20)
        #expect(LocalTime.wrap(0) == 0)
        #expect(LocalTime.wrap(720) == -720)
    }

    @Test func formatsLocalTime() {
        #expect(LocalTime.hhmm(now, sydney) == "13:00")
        #expect(LocalTime.hhmm(now, .gmt) == "02:00")
        #expect(LocalTime.hhmm(minutes: 1439.6) == "00:00")
        #expect(LocalTime.hhmm(minutes: 765) == "12:45")
    }

    @Test func distanceSydneyMelbourne() {
        let km = Geo.distKm(-33.946, 151.177, -37.673, 144.843)
        #expect(abs(km - 705) < 5)
    }
}

/// Direction across live fixes. North of the airport, track 180 points at it and 0 away.
struct DirectionTests {
    private let both = builder([history("QFA1", .inbound, usual: "12:45"), history("QFA1", .outbound, usual: "14:00")])

    @Test func nearTheAirportVerticalRateBeatsHeading() {
        // 20 km out, pointing away (downwind) but descending: an arrival.
        #expect(both.place([aircraft("QFA1", kmNorth: 20, track: 0, vrate: -800)], now: now).first?.kind == .inbound)
        // Pointing at the airport but climbing: a departure.
        #expect(both.place([aircraft("QFA1", kmNorth: 20, track: 180, vrate: 1500)], now: now).first?.kind == .outbound)
        // Level: the heading decides.
        #expect(both.place([aircraft("QFA1", kmNorth: 20, track: 0, vrate: 0)], now: now).first?.kind == .outbound)
    }

    @Test func anArrivalStaysInboundUntilItLands() {
        var directions = DirectionMemory()
        func fix(_ a: LiveAircraft) -> PlacedAircraft.Kind? { both.place([a], now: now, directions: &directions).first?.kind }
        #expect(fix(aircraft("QFA1", kmNorth: 45, track: 180, vrate: -500)) == .inbound)
        // Level on downwind, pointing away: still inbound.
        #expect(fix(aircraft("QFA1", kmNorth: 20, track: 0, vrate: 0)) == .inbound)
        // Go-around: climbing does not make it a departure.
        #expect(fix(aircraft("QFA1", kmNorth: 5, track: 180, vrate: 2000)) == .inbound)
        // Landed, then airborne again later: decided afresh.
        #expect(fix(aircraft("QFA1", kmNorth: 1, onGround: true)) == .ground)
        #expect(fix(aircraft("QFA1", kmNorth: 5, track: 0, vrate: 2000)) == .outbound)
    }

    @Test func aDescentTurnsAnEarlierOutboundIntoInbound() {
        var directions = DirectionMemory()
        func fix(_ a: LiveAircraft) -> PlacedAircraft.Kind? { both.place([a], now: now, directions: &directions).first?.kind }
        // First seen level on downwind, pointing away: taken for a departure...
        #expect(fix(aircraft("QFA1", kmNorth: 20, track: 0, vrate: 0)) == .outbound)
        // ...until it descends on base.
        #expect(fix(aircraft("QFA1", kmNorth: 15, track: 270, vrate: -700)) == .inbound)
    }

    @Test func theAPIDirectionIsUsedWhenPresent() {
        let b = builder([history("QFA1", .inbound, usual: "12:45")])
        // Flying away 300 km out is other traffic by the local rules; the API says inbound.
        #expect(b.place([aircraft("QFA1", kmNorth: 300, track: 0, dir: "inbound")], now: now).first?.kind == .inbound)
        #expect(b.place([aircraft("QFA1", kmNorth: 300, track: 0)], now: now).first?.kind == .other)
    }
}

struct BoardBuilderTests {
    @Test func inboundAircraftGetsETAAndDelay() throws {
        let b = builder([history("QFA1", .inbound, usual: "12:45", iata: "QF1")])
        let placed = try #require(b.place([aircraft("QFA1", kmNorth: 100)], now: now).first)
        #expect(placed.kind == .inbound)
        #expect(placed.flightIata == "QF1")
        // 7.4 km to the 50 NM ring at 300 kt, plus 15 min inside it.
        let eta = try #require(placed.etaMin)
        #expect(abs(eta - 15.8) < 0.2)
        #expect(LocalTime.hhmm(try #require(placed.eventAt), sydney) == "13:15")
        #expect(placed.delayMin == 30)
        #expect(placed.rag == .amber)
        #expect(Rag.text(delay: placed.delayMin) == "Late 30 min")
    }

    @Test func callsignFlyingAwayIsNotInbound() throws {
        let b = builder([history("QFA1", .inbound, usual: "12:45")])
        let placed = try #require(b.place([aircraft("QFA1", kmNorth: 300, track: 0)], now: now).first)
        #expect(placed.kind == .other)
    }

    @Test func departureStillOnStandIsLate() throws {
        let b = builder([history("VOZ800", .outbound, usual: "12:40", other: "BNE")])
        let placed = b.place([aircraft("VOZ800", kmNorth: 1, onGround: true)], now: now)
        let row = try #require(b.boardLive(placed, now: now).first)
        #expect(row.dir == .outbound)
        #expect(row.rag == .amber)
        #expect(row.statusNote == "Late 20 min")
        let board = b.board(.outbound, live: [row], memory: FeedMemory(), now: now)
        #expect(board.live.first?.status == "Late 20 min")
        #expect(board.live.first?.time.map { LocalTime.hhmm($0, sydney) } == "12:40")
    }

    @Test func freightersAreTaggedFromTheAPI() throws {
        let b = builder([
            history("FDX5150", .inbound, usual: "15:00", freighter: true),
            history("QFA1", .inbound, usual: "15:30", freighter: false),
            history("GTI8", .inbound, usual: "13:10"),
        ])
        let next = b.board(.inbound, live: [], memory: FeedMemory(), now: now).next
        #expect(next.map(\.callsign) == ["GTI8", "FDX5150", "QFA1"])
        #expect(next.map(\.freighter) == [false, true, false])
        // Live: the feed's tag wins, else the callsign's history.
        var tagged = aircraft("GTI8", kmNorth: 100, track: 180)
        tagged.isFreighter = true
        let placed = b.place([tagged, aircraft("QFA1", kmNorth: 100, track: 180)], now: now)
        let live = b.board(.inbound, live: b.boardLive(placed, now: now), memory: FeedMemory(), now: now).live
        #expect(Dictionary(uniqueKeysWithValues: live.map { ($0.callsign, $0.freighter) }) == ["GTI8": true, "QFA1": false])
    }

    @Test func regularFlightsArePredicted() {
        let b = builder([
            history("JST500", .inbound, usual: "15:00", days: 8, other: "OOL"),
            history("RXA1", .inbound, usual: "14:00", days: 3),   // not regular
            history("QFA9", .inbound, usual: "21:00", days: 14),  // beyond 6 hours
            history("VOZ1", .inbound, usual: "11:00", days: 14),  // 2 hours ago, not seen
        ])
        let board = b.board(.inbound, live: [], memory: FeedMemory(), now: now)
        #expect(board.next.map(\.callsign) == ["JST500"])
        #expect(board.next.first.flatMap { $0.time.map { LocalTime.hhmm($0, sydney) } } == "15:00")
        #expect(board.past.map(\.callsign) == ["VOZ1"])
        #expect(board.past.first?.status == "Presumed landed, not seen live")
    }

    @Test func aircraftThatLandsIsRemembered() {
        let b = builder([history("QFA1", .inbound, usual: "13:00")])
        var memory = FeedMemory()
        // Airborne on short final, then on the ground two minutes later.
        let t0 = now, t1 = now.addingTimeInterval(120)
        memory.update(b.boardLive(b.place([aircraft("QFA1", kmNorth: 5)], now: t0), now: t0), at: t0)
        let landed = b.boardLive(b.place([aircraft("QFA1", kmNorth: 2, onGround: true)], now: t1), now: t1)
        memory.update(landed, at: t1)
        let board = b.board(.inbound, live: landed, memory: memory, now: t1)
        #expect(board.live.first?.status == "Landed")
        #expect(board.live.first?.time == t1)

        // Off the feed at the next fix (shut down at the stand): stays on the board as past.
        let t2 = t1.addingTimeInterval(120)
        memory.update([], at: t2)
        let later = b.board(.inbound, live: [], memory: memory, now: t2)
        #expect(later.past.first?.callsign == "QFA1")
        #expect(later.past.first?.status == "Landed")
    }

    @Test func coverageGapFarOutIsNotALanding() {
        let b = builder([history("QFA1", .inbound, usual: "13:30")])
        var memory = FeedMemory()
        memory.update(b.boardLive(b.place([aircraft("QFA1", kmNorth: 400)], now: now), now: now), at: now)
        memory.update([], at: now.addingTimeInterval(120))
        let board = b.board(.inbound, live: [], memory: memory, now: now.addingTimeInterval(120))
        #expect(board.past.isEmpty)
        #expect(board.next.map(\.callsign) == ["QFA1"]) // back to its usual time
    }
}
