import Foundation
import Testing
@testable import RampOps

/// A small airport in Overpass's `out geom` shape: a runway, taxiway K in two pieces, a
/// stand, a gate, a cargo shed, a terminal, and a square of service roads with a one-way
/// side, about 1 km across, near 22.3° N.
private struct Fixture {
    private var nextId: Int64 = 1
    private var nodeIds: [String: Int64] = [:]
    private(set) var elements: [[String: Any]] = []

    private mutating func node(_ p: (Double, Double)) -> Int64 {
        let key = "\(p.0),\(p.1)"
        if let id = nodeIds[key] { return id }
        nextId += 1
        nodeIds[key] = nextId
        return nextId
    }

    mutating func way(_ tags: [String: String], _ pts: (Double, Double)...) {
        let nodes = pts.map { node($0) }
        nextId += 1
        elements.append(["type": "way", "id": nextId, "nodes": nodes, "tags": tags,
                         "geometry": pts.map { ["lat": $0.0, "lon": $0.1] }])
    }

    mutating func gate(_ ref: String, _ lat: Double, _ lon: Double) {
        nextId += 1
        elements.append(["type": "node", "id": nextId, "lat": lat, "lon": lon, "tags": ["aeroway": "gate", "ref": ref]])
    }
}

// Corners of the road square.
private let sw = (22.300, 113.900)
private let se = (22.300, 113.910)
private let ne = (22.309, 113.910)
private let nw = (22.309, 113.900)

private func layout() throws -> AirportLayout {
    var f = Fixture()
    f.way(["aeroway": "runway", "ref": "07L/25R", "width": "60"], (22.310, 113.890), (22.312, 113.930))
    f.way(["aeroway": "taxiway", "ref": "K"], (22.305, 113.890), (22.305, 113.895))
    f.way(["aeroway": "taxiway", "ref": "K"], (22.305, 113.895), (22.305, 113.920))
    f.way(["aeroway": "parking_position", "ref": "N12"], (22.304, 113.905), (22.303, 113.905))
    f.gate("23", 22.3045, 113.906)
    f.way(["building": "yes", "name": "國泰航空貨運站 Cathay Pacific Cargo Terminal"],
          (22.301, 113.901), (22.301, 113.903), (22.302, 113.903), (22.302, 113.901), (22.301, 113.901))
    f.way(["aeroway": "terminal", "name": "Terminal 1"],
          (22.306, 113.906), (22.306, 113.908), (22.307, 113.908), (22.307, 113.906), (22.306, 113.906))
    // South and west sides both ways; the east side one-way northwards; the north side both ways.
    f.way(["highway": "service", "access": "private"], sw, se)
    f.way(["highway": "service", "oneway": "yes"], se, ne)
    f.way(["highway": "service"], ne, nw)
    f.way(["highway": "service"], nw, sw)
    let json = try JSONSerialization.data(withJSONObject: ["elements": f.elements])
    return try AirportLayout.parse(icao: "VTST", json: json, fetchedAt: .now)
}

struct AirportLayoutTests {
    @Test func parsesShapesAndPlaces() throws {
        let l = try layout()
        #expect(!l.isEmpty)
        #expect(Set(l.areas.map(\.kind)) == [.cargo, .terminal])
        #expect(l.lines.first { $0.kind == .runway }?.widthM == 60)
        #expect(l.lines.filter { $0.kind == .serviceRoad }.count == 4)
        // One taxiway K, at its longer piece.
        let k = l.places.filter { $0.kind == .taxiway }
        #expect(k.map(\.title) == ["Taxiway K"])
        #expect(k[0].lon > 113.895)
        #expect(l.places.filter { $0.kind == .stand }.map(\.title) == ["Stand N12"])
        #expect(l.places.filter { $0.kind == .gate }.map(\.title) == ["Gate 23"])
        #expect(l.places.filter { $0.kind == .cargo }.map(\.label) == ["國泰航空貨運站 Cathay Pacific Cargo Terminal"])
        #expect(l.places.first { $0.label == "Terminal 1" }?.kind == .terminal)
    }

    @Test func searchRanksExactMatchesFirst() throws {
        let l = try layout()
        #expect(l.search("23").first?.title == "Gate 23")
        #expect(l.search("n1").first?.title == "Stand N12")
        #expect(l.search("cargo").first?.kind == .cargo)
        #expect(l.search("taxiway").map(\.kind) == [.taxiway])
        #expect(l.search("zzz").isEmpty)
        // Empty query: everything, gates first.
        #expect(l.search("").first?.kind == .gate)
    }

    @Test func routesKeepToOneWayRoads() throws {
        let l = try layout()
        // North-east to south-east: the east side is one-way northwards, so the route goes
        // round the other three sides (about 1 + 1.03 + 1 km).
        let down = try #require(l.route(fromLat: ne.0, fromLon: ne.1, toLat: se.0, toLon: se.1))
        #expect(!down.ignoresOneWay)
        #expect(abs(down.distanceM - (1028 + 1003 + 1028)) <= 30)
        // South-east to north-east may use it directly.
        let up = try #require(l.route(fromLat: se.0, fromLon: se.1, toLat: ne.0, toLon: ne.1))
        #expect(abs(up.distanceM - 1003) <= 15)
        // Starting off the road: the straight leg to it counts.
        let fromStand = try #require(l.route(fromLat: 22.3005, fromLon: 113.905, toLat: nw.0, toLon: nw.1))
        #expect(fromStand.distanceM > 1000)
        #expect(fromStand.lats.first == 22.3005)
    }

    @Test func noRoadsNoRoute() throws {
        let empty = try AirportLayout.parse(icao: "VTST", json: Data(#"{"elements":[]}"#.utf8), fetchedAt: .now)
        #expect(empty.isEmpty)
        #expect(empty.route(fromLat: 22.3, fromLon: 113.9, toLat: 22.31, toLon: 113.91) == nil)
    }
}
