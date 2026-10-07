import Foundation
import Observation

/// Airport layouts from OpenStreetMap through the Overpass API (no key), one download per
/// airport kept on the device: layouts change rarely, and the map must work without signal.
/// First the aerodrome's outline gives a box; then everything mapped in the box.
nonisolated struct OverpassClient: Sendable {
    static let servers = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    ].compactMap(URL.init(string:))
    private static let userAgent = "groundkit-ios (github.com/watanaberyunosuke/groundkit-ios)"
    /// About 300 m round the aerodrome, for its access roads.
    private static let marginDeg = 0.003
    static let maxAge: TimeInterval = 30 * 86_400

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "layouts", directoryHint: .isDirectory)
    }

    private static func file(_ icao: String) -> URL { directory.appending(path: "\(icao).json") }

    /// The kept copy, if any; parsing takes a moment, so off the main actor.
    @concurrent static func cached(_ icao: String) async -> AirportLayout? {
        let url = file(icao)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return try? AirportLayout.parse(icao: icao, json: data, fetchedAt: modified)
    }

    static func isStale(_ layout: AirportLayout, now: Date = .now) -> Bool {
        now.timeIntervalSince(layout.fetchedAt) > maxAge
    }

    /// Downloads and keeps the layout around the airport (its reference point as a fallback).
    @concurrent static func download(icao: String, lat: Double, lon: Double) async throws -> AirportLayout {
        let box = try await aerodromeBox(icao) ?? (s: lat - 0.03, w: lon - 0.04, n: lat + 0.03, e: lon + 0.04)
        let m = marginDeg
        let query = """
            [out:json][timeout:90][bbox:\(box.s - m),\(box.w - m),\(box.n + m),\(box.e + m)];
            (
              way["aeroway"~"^(runway|stopway|taxiway|taxilane|holding_position|parking_position|jet_bridge|apron|terminal|hangar)$"];
              node["aeroway"~"^(gate|holding_position)$"];
              way["building"];
              way["highway"~"^(service|motorway|trunk|primary|secondary|tertiary|unclassified)$"];
            );
            out geom qt;
            """
        let json = try await overpass(query)
        let layout = try AirportLayout.parse(icao: icao, json: json, fetchedAt: .now)
        if layout.isEmpty { throw OverpassError.empty(icao) }
        var dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Re-downloadable, so kept out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        try json.write(to: file(icao), options: .atomic)
        return layout
    }

    private static func aerodromeBox(_ icao: String) async throws -> (s: Double, w: Double, n: Double, e: Double)? {
        let json = try await overpass("[out:json][timeout:25];nwr[\"aeroway\"=\"aerodrome\"][\"icao\"=\"\(icao)\"];out bb;")
        let elements = (try JSONSerialization.jsonObject(with: json) as? [String: Any])?["elements"] as? [[String: Any]] ?? []
        return elements
            .compactMap { $0["bounds"] as? [String: Double] }
            .compactMap { b -> (s: Double, w: Double, n: Double, e: Double)? in
                guard let s = b["minlat"], let w = b["minlon"], let n = b["maxlat"], let e = b["maxlon"] else { return nil }
                return (s, w, n, e)
            }
            .max { ($0.n - $0.s) * ($0.e - $0.w) < ($1.n - $1.s) * ($1.e - $1.w) }
    }

    /// POSTs a query to the main Overpass server, then the mirrors when it is busy.
    private static func overpass(_ query: String) async throws -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        var last: Error = OverpassError.unavailable
        for server in servers {
            var request = URLRequest(url: server, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw OverpassError.status(status, server.host() ?? "") }
                // A busy server can answer 200 with an HTML error page.
                guard data.first(where: { !" \n\r\t".utf8.contains($0) }) == UInt8(ascii: "{") else {
                    throw OverpassError.busy(server.host() ?? "")
                }
                return data
            } catch {
                last = error
            }
        }
        throw last
    }
}

nonisolated enum OverpassError: LocalizedError {
    case empty(String), status(Int, String), busy(String), unavailable

    var errorDescription: String? {
        switch self {
        case .empty(let icao): "OpenStreetMap has no layout mapped for \(icao)"
        case .status(let code, let host): "Overpass \(code) from \(host)"
        case .busy(let host): "Overpass busy at \(host)"
        case .unavailable: "Overpass unavailable"
        }
    }
}

/// The selected airport's layout for the map: the kept copy at once, downloaded when
/// missing or a month old.
@Observable
final class LayoutStore {
    private(set) var icao: String?
    private(set) var layout: AirportLayout?
    private(set) var isLoading = false
    private(set) var error: String?
    private var task: Task<Void, Never>?

    func show(_ airport: Airport) {
        if icao == airport.icao && (isLoading || layout != nil) { return }
        load(airport, force: false)
    }

    func retry(_ airport: Airport) { load(airport, force: true) }

    private func load(_ airport: Airport, force: Bool) {
        task?.cancel()
        if icao != airport.icao {
            icao = airport.icao
            layout = nil
        }
        isLoading = true
        error = nil
        task = Task {
            let kept = await OverpassClient.cached(airport.icao)
            guard !Task.isCancelled else { return }
            if let kept { layout = kept }
            if let kept, !force, !OverpassClient.isStale(kept) {
                isLoading = false
                return
            }
            do {
                let fresh = try await OverpassClient.download(icao: airport.icao, lat: airport.lat, lon: airport.lon)
                guard !Task.isCancelled else { return }
                layout = fresh
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
