import Foundation

nonisolated struct APIError: LocalizedError, Sendable {
    var status: Int
    var detail: String

    var errorDescription: String? { "HTTP \(status): \(detail)" }
}

/// The aviation project's Vercel API: the same backend the web dashboard uses.
nonisolated struct APIClient: Sendable {
    static let defaultBaseURL = URL(string: "https://groundkit-dashboard.harrydatahub.com")!

    var baseURL: URL
    var session: URLSession = .shared

    /// `/api/snapshot/<icao>`, with the raw body so it can be cached for offline use.
    @concurrent func snapshot(icao: String) async throws -> (Snapshot, Data) {
        let data = try await get("api/snapshot/\(icao)")
        return (try JSON.decoder().decode(Snapshot.self, from: data), data)
    }

    /// `/api/live/<icao>`: aircraft within 500 NM from OpenSky or adsb.lol.
    @concurrent func live(icao: String) async throws -> LiveFeed {
        try JSON.decoder().decode(LiveFeed.self, from: try await get("api/live/\(icao)"))
    }

    /// `/api/tracks/<icao>`: paths of tracked flights over the last 3 days, for the map.
    @concurrent func tracks(icao: String) async throws -> [TrackLine] {
        try JSON.decoder().decode(TracksResponse.self, from: try await get("api/tracks/\(icao)")).tracks
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // FastAPI errors are {"detail": "..."}.
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            throw APIError(status: status, detail: detail ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return data
    }
}

/// The last snapshot per airport on disk, so the app opens with data in a dead spot.
nonisolated enum SnapshotCache {
    private static var directory: URL {
        URL.cachesDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
    }

    static func load(_ icao: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(icao).json")) else { return nil }
        return try? JSON.decoder().decode(Snapshot.self, from: data)
    }

    static func save(_ data: Data, for icao: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "\(icao).json"), options: .atomic)
    }
}
