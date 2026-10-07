import Foundation

// An airport's layout from OpenStreetMap (the Overpass API's `out geom` JSON), for the
// airport map: runways, taxiways and stands, aprons, terminals, cargo sheds and other
// buildings, gates, and the roads, which also give routes between them. OSM is mapped by
// volunteers, so it can be out of date or incomplete; the airport's own charts and
// markings take precedence.

nonisolated enum AreaKind: Int, CaseIterable, Sendable {
    case runway, apron, terminal, hangar, cargo, building
}

nonisolated enum LineKind: Int, CaseIterable, Sendable {
    case runway, stopway, taxiway, taxilane, holding, stand, jetBridge, serviceRoad, road
}

nonisolated enum PlaceKind: Int, CaseIterable, Sendable {
    case gate, stand, taxiway, cargo, terminal, hangar, building

    var label: String {
        switch self {
        case .gate: "Gate"
        case .stand: "Stand"
        case .taxiway: "Taxiway"
        case .cargo: "Cargo"
        case .terminal: "Terminal"
        case .hangar: "Hangar"
        case .building: "Building"
        }
    }
}

/// A way's outline or centreline.
nonisolated struct LayoutShape: Sendable {
    var lats: [Double]
    var lons: [Double]
    var label: String?

    var minLat: Double { lats.min() ?? 0 }
    var maxLat: Double { lats.max() ?? 0 }
    var minLon: Double { lons.min() ?? 0 }
    var maxLon: Double { lons.max() ?? 0 }
}

nonisolated struct LayoutArea: Sendable {
    var kind: AreaKind
    var shape: LayoutShape
}

nonisolated struct LayoutLine: Sendable {
    var kind: LineKind
    var shape: LayoutShape
    var widthM: Double?
}

nonisolated struct Place: Sendable, Hashable, Identifiable {
    var kind: PlaceKind
    var label: String
    var lat: Double
    var lon: Double

    var id: String { "\(kind.rawValue):\(label)" }

    var title: String {
        switch kind {
        case .gate, .stand, .taxiway: "\(kind.label) \(label)"
        default: label
        }
    }
}

/// A route along the roads, from where you are to a place.
nonisolated struct Route: Sendable, Hashable {
    var lats: [Double]
    var lons: [Double]
    /// Along the roads, plus the straight bits to and from them.
    var distanceM: Double
    /// No route kept to one-way rules; this one ignores them.
    var ignoresOneWay: Bool
}

nonisolated struct AirportLayout: Sendable {
    var icao: String
    var fetchedAt: Date
    var areas: [LayoutArea]
    var lines: [LayoutLine]
    var places: [Place]
    /// Runway holding points mapped as single points.
    var holdingPoints: [(lat: Double, lon: Double)]
    fileprivate var roads: RoadGraph

    /// The airfield's extent, for fitting the map: roads run on for miles, so they don't count.
    var bounds: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? {
        let airfield = areas.filter { $0.kind != .building }.map(\.shape)
            + lines.filter { [.runway, .stopway, .taxiway, .taxilane].contains($0.kind) }.map(\.shape)
        guard let minLat = airfield.map(\.minLat).min(), let maxLat = airfield.map(\.maxLat).max(),
              let minLon = airfield.map(\.minLon).min(), let maxLon = airfield.map(\.maxLon).max() else { return nil }
        return (minLat, minLon, maxLat, maxLon)
    }

    var isEmpty: Bool { areas.isEmpty && lines.isEmpty }

    /// Places whose label or kind matches `query`, best matches first.
    func search(_ query: String, limit: Int = 40) -> [Place] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return Array(places.sorted(by: Self.placeOrder).prefix(limit)) }
        let ranked: [(Int, Place)] = places.compactMap { p in
            let label = p.label.lowercased()
            let title = p.title.lowercased()
            if label == q || title == q { return (0, p) }
            if label.hasPrefix(q) || title.hasPrefix(q) { return (1, p) }
            if title.contains(q) || p.kind.label.lowercased().contains(q) { return (2, p) }
            return nil
        }
        return ranked
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : Self.placeOrder($0.1, $1.1) }
            .prefix(limit)
            .map(\.1)
    }

    func route(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> Route? {
        roads.route(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon)
    }

    // MARK: Parsing

    private static func placeOrder(_ a: Place, _ b: Place) -> Bool {
        a.kind != b.kind ? a.kind.rawValue < b.kind.rawValue : naturalKey(a.label) < naturalKey(b.label)
    }

    /// "A12" before "A100".
    private static func naturalKey(_ s: String) -> String {
        var out = "", digits = ""
        for ch in s {
            if ch.isASCII && ch.isNumber {
                digits.append(ch)
            } else {
                if !digits.isEmpty { out += String(repeating: "0", count: max(0, 6 - digits.count)) + digits; digits = "" }
                out.append(ch)
            }
        }
        if !digits.isEmpty { out += String(repeating: "0", count: max(0, 6 - digits.count)) + digits }
        return out
    }

    private static let cargoWords = "cargo|freight|logistic|express|air ?mail|courier|dhl|fedex|ups|hactl|tnt|forwarder|貨|货|物流"
    private static let onewayYes: Set<String> = ["yes", "true", "1"]
    private static let skipService: Set<String> = ["parking_aisle", "emergency_access"]

    private static func isCargo(_ s: String) -> Bool {
        s.range(of: cargoWords, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// From an Overpass API response (`out geom`) for the airport's area.
    static func parse(icao: String, json: Data, fetchedAt: Date) throws -> AirportLayout {
        let root = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let elements = root?["elements"] as? [[String: Any]] ?? []
        var areas: [LayoutArea] = []
        var lines: [LayoutLine] = []
        var places: [Place] = []
        var placeKeys = Set<String>()
        var roads = RoadGraph.Builder()
        var taxiways: [String: (length: Double, place: Place)] = [:]
        var taxiwayOrder: [String] = []
        var holds: [(lat: Double, lon: Double)] = []

        func addPlace(_ kind: PlaceKind, _ label: String?, _ lat: Double, _ lon: Double) {
            guard let l = label?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty else { return }
            let p = Place(kind: kind, label: l, lat: lat, lon: lon)
            if placeKeys.insert(p.id).inserted { places.append(p) }
        }

        for e in elements {
            guard let tags = e["tags"] as? [String: Any] else { continue }
            func tag(_ k: String) -> String? {
                guard let v = tags[k] else { return nil }
                let s = "\(v)"
                return s.isEmpty ? nil : s
            }
            let aeroway = tag("aeroway")
            let label = tag("ref") ?? tag("name:en") ?? tag("name")

            if e["type"] as? String == "node" {
                guard let lat = number(e["lat"]), let lon = number(e["lon"]) else { continue }
                if aeroway == "gate" { addPlace(.gate, tag("ref") ?? tag("name"), lat, lon) }
                if aeroway == "holding_position" { holds.append((lat, lon)) }
                continue
            }
            guard let geom = e["geometry"] as? [Any], geom.count >= 2 else { continue }
            let points = geom.compactMap { $0 as? [String: Any] }
            guard points.count == geom.count else { continue }
            let lats = points.compactMap { number($0["lat"]) }
            let lons = points.compactMap { number($0["lon"]) }
            guard lats.count == geom.count, lons.count == geom.count else { continue }
            let closed = lats.first == lats.last && lons.first == lons.last && lats.count > 3
            let shape = LayoutShape(lats: lats, lons: lons, label: label)
            let mid = lats.count / 2
            let width = tag("width").flatMap { Double($0.split(separator: " ").first ?? "") }

            switch aeroway {
            case "runway":
                if closed && tag("area") == "yes" { areas.append(LayoutArea(kind: .runway, shape: shape)) }
                else { lines.append(LayoutLine(kind: .runway, shape: shape, widthM: width)) }
            case "stopway":
                lines.append(LayoutLine(kind: .stopway, shape: shape, widthM: width))
            case "taxiway", "taxilane":
                lines.append(LayoutLine(kind: aeroway == "taxiway" ? .taxiway : .taxilane, shape: shape, widthM: width))
                // One search result per taxiway, at its longest piece.
                if let ref = tag("ref") {
                    let len = length(lats, lons)
                    if len > (taxiways[ref]?.length ?? 0) {
                        if taxiways[ref] == nil { taxiwayOrder.append(ref) }
                        taxiways[ref] = (len, Place(kind: .taxiway, label: ref, lat: lats[mid], lon: lons[mid]))
                    }
                }
            case "holding_position":
                lines.append(LayoutLine(kind: .holding, shape: shape, widthM: nil))
            case "parking_position":
                lines.append(LayoutLine(kind: .stand, shape: shape, widthM: nil))
                addPlace(.stand, tag("ref") ?? tag("name"), lats[mid], lons[mid])
            case "jet_bridge":
                lines.append(LayoutLine(kind: .jetBridge, shape: shape, widthM: nil))
            case "apron":
                if closed { areas.append(LayoutArea(kind: .apron, shape: shape)) }
            case "terminal":
                if closed {
                    let cargo = isCargo(tags.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                    areas.append(LayoutArea(kind: cargo ? .cargo : .terminal, shape: shape))
                    addPlace(cargo ? .cargo : .terminal, tag("name:en") ?? tag("name"), centre(lats), centre(lons))
                }
            case "hangar":
                if closed {
                    areas.append(LayoutArea(kind: .hangar, shape: shape))
                    addPlace(.hangar, tag("name:en") ?? tag("name") ?? tag("ref"), centre(lats), centre(lons))
                }
            default:
                if let building = tag("building"), closed {
                    let name = tag("name:en") ?? tag("name")
                    let cargo = building == "warehouse" || name.map(isCargo) == true || isCargo(tag("operator") ?? "")
                    areas.append(LayoutArea(kind: cargo ? .cargo : .building, shape: shape))
                    addPlace(cargo ? .cargo : .building, name, centre(lats), centre(lons))
                } else if let highway = tag("highway") {
                    if tag("service").map(skipService.contains) == true || tag("access") == "no" {
                        lines.append(LayoutLine(kind: .serviceRoad, shape: shape, widthM: nil))
                        continue
                    }
                    lines.append(LayoutLine(kind: highway == "service" ? .serviceRoad : .road, shape: shape, widthM: nil))
                    let nodes = (e["nodes"] as? [Any])?.compactMap { number($0).map(Int64.init) } ?? []
                    if nodes.count == lats.count {
                        let oneway = tag("oneway")
                        let isYes = oneway.map(onewayYes.contains) == true
                        roads.addWay(ids: nodes, lats: lats, lons: lons,
                                     forward: oneway != "-1",
                                     backward: (!isYes && oneway != "-1" && tag("junction") != "roundabout") || oneway == "-1")
                    }
                }
            }
        }
        for ref in taxiwayOrder {
            if let p = taxiways[ref]?.place, placeKeys.insert(p.id).inserted { places.append(p) }
        }
        // Small buildings under the big ones, so names and taxiways stay readable.
        let sortedAreas = areas.enumerated()
            .sorted { $0.element.kind != $1.element.kind ? $0.element.kind.rawValue < $1.element.kind.rawValue : $0.offset < $1.offset }
            .map(\.element)
        return AirportLayout(icao: icao, fetchedAt: fetchedAt, areas: sortedAreas, lines: lines, places: places,
                             holdingPoints: holds, roads: roads.build())
    }

    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: d
        case let i as Int: Double(i)
        case let i as Int64: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    private static func centre(_ xs: [Double]) -> Double { ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2 }

    private static func length(_ lats: [Double], _ lons: [Double]) -> Double {
        (1..<lats.count).reduce(0) { $0 + Geo.metres(lats[$1 - 1], lons[$1 - 1], lats[$1], lons[$1]) }
    }
}

extension Geo {
    /// Metres between two nearby points (equirectangular: fine across an airport).
    nonisolated static func metres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let k = Double.pi / 180 * 6_371_008.8
        let x = (lon2 - lon1) * k * cos((lat1 + lat2) / 2 * Double.pi / 180)
        let y = (lat2 - lat1) * k
        return (x * x + y * y).squareRoot()
    }
}

/// The road network as a graph of OSM nodes, for routes.
nonisolated struct RoadGraph: Sendable {
    private var lat: [Double]
    private var lon: [Double]
    /// Per node: the nodes reachable in one step, and whether each step is against a one-way.
    private var next: [[(node: Int, againstOneWay: Bool)]]

    /// How far from a road a route may start or end.
    static let snapM = 400.0
    /// Off-road legs cost double, so routes keep to the roads where they can.
    private static let offRoad = 2.0

    struct Builder {
        private var index: [Int64: Int] = [:]
        private var lat: [Double] = []
        private var lon: [Double] = []
        private var edges: [[(node: Int, againstOneWay: Bool)]] = []

        private mutating func node(_ id: Int64, _ la: Double, _ lo: Double) -> Int {
            if let i = index[id] { return i }
            lat.append(la)
            lon.append(lo)
            edges.append([])
            index[id] = lat.count - 1
            return lat.count - 1
        }

        mutating func addWay(ids: [Int64], lats: [Double], lons: [Double], forward: Bool, backward: Bool) {
            for i in 1..<ids.count {
                let a = node(ids[i - 1], lats[i - 1], lons[i - 1])
                let b = node(ids[i], lats[i], lons[i])
                if a == b { continue }
                edges[a].append((b, !forward))
                edges[b].append((a, !backward))
            }
        }

        func build() -> RoadGraph { RoadGraph(lat: lat, lon: lon, next: edges) }
    }

    var size: Int { lat.count }

    /// The shortest route by road, keeping to one-way rules if possible. It starts from the
    /// road nodes near `from` and ends at the one near `to` that gives the shortest total,
    /// so a gap in the map near either end doesn't stop it.
    func route(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> Route? {
        guard size > 0 else { return nil }
        return search(fromLat, fromLon, toLat, toLon, oneWay: true)
            ?? search(fromLat, fromLon, toLat, toLon, oneWay: false)
    }

    private func search(_ fromLat: Double, _ fromLon: Double, _ toLat: Double, _ toLon: Double, oneWay: Bool) -> Route? {
        var dist = [Double](repeating: .infinity, count: size)
        var prev = [Int](repeating: -1, count: size)
        var queue = MinHeap()
        for (n, d) in nearest(fromLat, fromLon) {
            dist[n] = d * Self.offRoad
            queue.push(dist[n], n)
        }
        if queue.isEmpty { return nil }
        while let (d, n) = queue.pop() {
            if d > dist[n] { continue }
            for step in next[n] {
                if oneWay && step.againstOneWay { continue }
                let m = step.node
                let nd = d + Geo.metres(lat[n], lon[n], lat[m], lon[m])
                if nd < dist[m] {
                    dist[m] = nd
                    prev[m] = n
                    queue.push(nd, m)
                }
            }
        }
        guard let end = nearest(toLat, toLon)
            .filter({ dist[$0.node].isFinite })
            .min(by: { dist[$0.node] + $0.metres * Self.offRoad < dist[$1.node] + $1.metres * Self.offRoad }) else { return nil }
        var path: [Int] = []
        var at = end.node
        while at >= 0 {
            path.append(at)
            at = prev[at]
        }
        path.reverse()
        let lats = [fromLat] + path.map { lat[$0] } + [toLat]
        let lons = [fromLon] + path.map { lon[$0] } + [toLon]
        let along = (1..<lats.count).reduce(0) { $0 + Geo.metres(lats[$1 - 1], lons[$1 - 1], lats[$1], lons[$1]) }
        return Route(lats: lats, lons: lons, distanceM: along, ignoresOneWay: !oneWay)
    }

    /// Road nodes within `snapM` of a point (or the nearest one), with their distances.
    private func nearest(_ la: Double, _ lo: Double) -> [(node: Int, metres: Double)] {
        let all = (0..<size).map { (node: $0, metres: Geo.metres(la, lo, lat[$0], lon[$0])) }
        let near = all.filter { $0.metres <= Self.snapM }
        if !near.isEmpty { return near }
        return all.min(by: { $0.metres < $1.metres }).map { [$0] } ?? []
    }
}

/// A binary min-heap of (distance, node) for Dijkstra.
private nonisolated struct MinHeap {
    private var items: [(Double, Int)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ key: Double, _ value: Int) {
        items.append((key, value))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].0 < items[parent].0 else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < items.count && items[l].0 < items[smallest].0 { smallest = l }
            if r < items.count && items[r].0 < items[smallest].0 { smallest = r }
            if smallest == i { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return top
    }
}
