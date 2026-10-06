import Foundation

// The JSON the Vercel API serves (motherduck-aviation-data-analysis, api/index.py).
// Keys arrive in snake_case and are decoded with .convertFromSnakeCase, so `days_14`
// becomes `days14` and `flight_number_iata` becomes `flightNumberIata`.

/// One airport's state from `/api/snapshot/<icao>`, refreshed hourly by the pipeline and
/// edge-cached for 10 minutes.
nonisolated struct Snapshot: Codable, Sendable {
    var generatedAt: Date
    var airports: [Airport]
    var conditions: Conditions?
    var weather: [HourlyWeather]
    var notams: [Notam]
    var medians: Medians
    var history: [CallsignHistory]
}

nonisolated struct Airport: Codable, Sendable, Hashable, Identifiable {
    var icao: String
    var iata: String
    var name: String
    var timezone: String
    var lat: Double
    var lon: Double
    var notamSource: String?

    var id: String { icao }
    var timeZone: TimeZone { TimeZone(identifier: timezone) ?? .gmt }

    /// The seven airports the warehouse covers, so the picker works before the first fetch.
    static let known: [Airport] = [
        Airport(icao: "EHAM", iata: "AMS", name: "Amsterdam Schiphol", timezone: "Europe/Amsterdam", lat: 52.309, lon: 4.764),
        Airport(icao: "PANC", iata: "ANC", name: "Anchorage Ted Stevens", timezone: "America/Anchorage", lat: 61.179, lon: -149.993),
        Airport(icao: "YBBN", iata: "BNE", name: "Brisbane", timezone: "Australia/Brisbane", lat: -27.384, lon: 153.117),
        Airport(icao: "VHHH", iata: "HKG", name: "Hong Kong International", timezone: "Asia/Hong_Kong", lat: 22.309, lon: 113.915),
        Airport(icao: "YMML", iata: "MEL", name: "Melbourne Tullamarine", timezone: "Australia/Melbourne", lat: -37.673, lon: 144.843),
        Airport(icao: "WSSS", iata: "SIN", name: "Singapore Changi", timezone: "Asia/Singapore", lat: 1.359, lon: 103.989),
        Airport(icao: "YSSY", iata: "SYD", name: "Sydney Kingsford Smith", timezone: "Australia/Sydney", lat: -33.946, lon: 151.177),
    ]
}

/// fct_airport_conditions: the latest METAR (decoded and raw), TAF and NOTAM count.
nonisolated struct Conditions: Codable, Sendable {
    var icao: String
    var iata: String
    var name: String
    var lat: Double
    var lon: Double
    var timezone: String
    var metarObservedAt: Date?
    var metarRaw: String?
    var flightCategory: String?
    var windVariable: Bool?
    var windDirDeg: Int?
    var windSpeedKt: Int?
    var windGustKt: Int?
    var visibilitySm: Double?
    var visibilityIsLowerBound: Bool?
    var ceilingFt: Int?
    var wxString: String?
    var tempC: Double?
    var dewpointC: Double?
    var altimeterHpa: Double?
    var tafIssuedAt: Date?
    var tafValidFrom: Date?
    var tafValidTo: Date?
    var tafRaw: String?
    /// Nil where the airport has no NOTAM feed (unknown, not zero).
    var notamsInForce: Int?
    var metarAgeMin: Int?
}

/// fct_airport_weather_hourly, the last 24 hours.
nonisolated struct HourlyWeather: Codable, Sendable, Identifiable {
    var hourUtc: Date
    var observedAt: Date?
    var flightCategory: String?
    var windDirDeg: Int?
    var windVariable: Bool?
    var windSpeedKt: Int?
    var windGustKt: Int?
    var visibilitySm: Double?
    var ceilingFt: Int?
    var wxString: String?
    var hasThunderstorm: Bool?
    var hasPrecipitation: Bool?
    var tempC: Double?
    var dewpointC: Double?

    var id: Date { hourUtc }
}

/// fct_notams rows in force at the airport.
nonisolated struct Notam: Codable, Sendable, Identifiable, Hashable {
    var notamKey: String
    var number: String?
    var qCode: String?
    /// From the Q-code subject; nil without an ICAO Q-line (Australian and US domestic).
    var category: String?
    var condition: String?
    var startsAt: Date?
    var endsAt: Date?
    var isPermanent: Bool?
    var isEstimated: Bool?
    var schedule: String?
    var body: String?
    var rawText: String?
    var isRunwayClosure: Bool?

    var id: String { notamKey }
}

/// Median minutes inside the 50 NM terminal area over 30 days; nil until data builds up.
nonisolated struct Medians: Codable, Sendable {
    var arrivalTerminalMinutes: Double?
    var departureTerminalMinutes: Double?
}

/// A callsign seen arriving (`inbound`) or departing (`outbound`) in the last 30 days.
nonisolated struct CallsignHistory: Codable, Sendable, Hashable {
    var callsign: String
    var dir: Direction
    /// Usual origin (inbound) or destination (outbound), IATA where known.
    var other: String?
    var n: Int
    /// Usual local time of day, minutes after midnight.
    var usualMin: Double
    /// Local days seen out of the last 14.
    var days14: Int
    var flightNumberIata: String?
    var airlineName: String?
}

nonisolated enum Direction: String, Codable, Sendable, Hashable {
    case inbound, outbound
}

/// `/api/live/<icao>`: aircraft within 500 NM, edge-cached for 2 minutes.
nonisolated struct LiveFeed: Codable, Sendable {
    var time: Int
    var source: String
    var aircraft: [LiveAircraft]
    var failed: [String]?

    var at: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
}

nonisolated struct LiveAircraft: Codable, Sendable, Hashable {
    var icao24: String?
    var callsign: String?
    var lon: Double
    var lat: Double
    var altFt: Double?
    var onGround: Bool
    var speedKt: Double?
    var trackDeg: Double?
    var vrateFpm: Double?
    /// The API's direction for this fix: inbound, outbound, ground or other; nil if it had none.
    var dir: String? = nil
}

/// `/api/tracks/<icao>`: observed arrival and departure paths over the last 3 days.
nonisolated struct TracksResponse: Codable, Sendable {
    var tracks: [TrackLine]
}

nonisolated struct TrackLine: Codable, Sendable, Hashable {
    /// "arrival" or "departure".
    var role: String
    var label: String?
    var departureIata: String?
    var arrivalIata: String?
    /// [lat, lon] pairs in time order.
    var points: [[Double]]
}

nonisolated enum JSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // The API sends ISO 8601 with an offset ("2026-10-04T01:30:00+10:00").
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return decoder
    }
}
