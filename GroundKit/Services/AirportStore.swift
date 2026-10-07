import Foundation
import Observation

/// The selected airport's snapshot, live traffic and the boards and ramp status built
/// from them. One instance for the app, shared through the environment.
@Observable
final class AirportStore {
    /// The live feed is edge-cached for 2 minutes, so polling faster gains nothing.
    static let refreshInterval: Duration = .seconds(120)
    /// The snapshot changes at most hourly and is edge-cached for 10 minutes.
    static let snapshotMaxAge: TimeInterval = 5 * 60

    private(set) var icao: String
    private(set) var snapshot: Snapshot?
    private(set) var snapshotFetchedAt: Date?
    private(set) var snapshotIsCached = false
    private(set) var live: LiveFeed?
    /// Paths of tracked flights for the map; empty when the API has none.
    private(set) var tracks: [TrackLine] = []
    private(set) var snapshotError: String?
    private(set) var liveError: String?
    private(set) var isRefreshing = false

    private(set) var placed: [PlacedAircraft] = []
    private(set) var arrivals: Board = .empty
    private(set) var departures: Board = .empty
    private(set) var rampStatus: RampStatus?

    var thresholds: RampThresholds {
        didSet {
            saveThresholds()
            rebuild()
        }
    }

    var baseURL: URL {
        didSet { UserDefaults.standard.set(baseURL.absoluteString, forKey: Keys.baseURL) }
    }

    private var memory = FeedMemory()
    private var directions = DirectionMemory()
    private var api: APIClient { APIClient(baseURL: baseURL) }

    private enum Keys {
        static let airport = "airport"
        static let baseURL = "apiBaseURL"
        static let thresholds = "rampThresholds"
    }

    init(defaults: UserDefaults = .standard) {
        icao = defaults.string(forKey: Keys.airport) ?? "VHHH"
        baseURL = defaults.string(forKey: Keys.baseURL).flatMap(URL.init(string:)) ?? APIClient.defaultBaseURL
        thresholds = defaults.data(forKey: Keys.thresholds)
            .flatMap { try? JSONDecoder().decode(RampThresholds.self, from: $0) } ?? .standard
        loadCached()
    }

    // MARK: Derived

    var airports: [Airport] { snapshot?.airports ?? Airport.known }
    var airport: Airport { airports.first { $0.icao == icao } ?? Airport.known.first { $0.icao == icao } ?? Airport.known[0] }
    var timeZone: TimeZone { airport.timeZone }
    var conditions: Conditions? { snapshot?.conditions }
    var notams: [Notam] { snapshot?.notams ?? [] }
    var rampNotams: [Notam] { notams.filter(RampAdvisor.isRampRelevant) }

    // MARK: Actions

    func select(_ icao: String) {
        guard icao != self.icao else { return }
        self.icao = icao
        UserDefaults.standard.set(icao, forKey: Keys.airport)
        snapshot = nil
        live = nil
        tracks = []
        memory = FeedMemory()
        directions = DirectionMemory()
        snapshotError = nil
        liveError = nil
        loadCached()
        Task { await refresh(force: true) }
    }

    /// Polls while the calling task lives (the root view's `.task`).
    func autoRefresh() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let icao = icao, api = api
        let needSnapshot = force || snapshotIsCached
            || snapshotFetchedAt.map { Date.now.timeIntervalSince($0) > Self.snapshotMaxAge } ?? true

        async let snapshotResult: Result<(Snapshot, Data), Error>? = needSnapshot ? capture { try await api.snapshot(icao: icao) } : nil
        async let liveResult = capture { try await api.live(icao: icao) }
        async let tracksResult: Result<[TrackLine], Error>? = needSnapshot ? capture { try await api.tracks(icao: icao) } : nil
        let (s, l, t) = await (snapshotResult, liveResult, tracksResult)
        guard icao == self.icao else { return } // the airport changed while loading

        switch s {
        case .success(let (snap, data))?:
            snapshot = snap
            snapshotFetchedAt = .now
            snapshotIsCached = false
            snapshotError = nil
            SnapshotCache.save(data, for: icao)
        case .failure(let error)?:
            snapshotError = error.localizedDescription
        case nil:
            break
        }
        // Tracks only decorate the map, so a failure keeps the last ones without an error.
        if case .success(let lines)? = t { tracks = lines }
        switch l {
        case .success(let feed):
            live = feed
            liveError = nil
        case .failure(let error):
            liveError = error.localizedDescription
        }
        rebuild()
    }

    /// The board entry for an aircraft on the map, or a plain one for traffic that is not
    /// a regular flight here.
    func entry(for p: PlacedAircraft) -> BoardEntry {
        if let e = (arrivals.live + departures.live).first(where: { $0.aircraft == p.aircraft }) { return e }
        return BoardEntry(
            phase: .live, dir: p.kind == .outbound ? .outbound : .inbound,
            callsign: p.aircraft.callsign ?? p.aircraft.icao24?.uppercased() ?? "Unknown",
            flightIata: p.flightIata, airline: p.airline, other: p.other, usual: p.usual, time: nil,
            timeIsApprox: false, status: p.aircraft.onGround ? "On the ground" : "Not a regular flight here",
            rag: .unknown, onGround: p.aircraft.onGround, distNm: p.distNm, etaMin: nil, aircraft: p.aircraft,
            freighter: p.aircraft.isFreighter == true)
    }

    private func capture<T: Sendable>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private func loadCached() {
        if let cached = SnapshotCache.load(icao) {
            snapshot = cached
            snapshotIsCached = true
            snapshotFetchedAt = cached.generatedAt
        }
        rebuild()
    }

    private func saveThresholds() {
        if let data = try? JSONEncoder().encode(thresholds) {
            UserDefaults.standard.set(data, forKey: Keys.thresholds)
        }
    }

    /// Recomputes the boards and ramp status after new data.
    private func rebuild() {
        rampStatus = snapshot.map { RampAdvisor.evaluate($0.conditions, notams: $0.notams, thresholds: thresholds) }
        guard let snapshot else {
            placed = []
            arrivals = .empty
            departures = .empty
            return
        }
        let builder = BoardBuilder(lat: airport.lat, lon: airport.lon, timeZone: timeZone,
                                   history: HistoryIndex(snapshot.history), medians: snapshot.medians)
        let now = live?.at ?? .now
        placed = builder.place(live?.aircraft ?? [], now: now, directions: &directions)
        let rows = builder.boardLive(placed, now: now)
        if let at = live?.at { memory.update(rows, at: at) }
        arrivals = builder.board(.inbound, live: rows, memory: memory, now: now)
        departures = builder.board(.outbound, live: rows, memory: memory, now: now)
    }
}
