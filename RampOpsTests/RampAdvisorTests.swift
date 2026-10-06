import Foundation
import Testing
@testable import RampOps

private func conditions(wx: String? = nil, metar: String = "METAR YSSY 060200Z 18010KT 9999 FEW030 20/10 Q1015",
                        taf: String? = nil, wind: Int = 10, gust: Int? = nil, temp: Double = 20, dew: Double = 10,
                        vis: Double = 6, visLower: Bool = true, age: Int = 20) -> Conditions {
    Conditions(icao: "YSSY", iata: "SYD", name: "Sydney", lat: -33.946, lon: 151.177, timezone: "Australia/Sydney",
               metarObservedAt: .now, metarRaw: metar, flightCategory: "VFR", windVariable: false, windDirDeg: 180,
               windSpeedKt: wind, windGustKt: gust, visibilitySm: vis, visibilityIsLowerBound: visLower,
               ceilingFt: nil, wxString: wx, tempC: temp, dewpointC: dew, altimeterHpa: 1015, tafIssuedAt: nil,
               tafValidFrom: nil, tafValidTo: nil, tafRaw: taf, notamsInForce: 0, metarAgeMin: age)
}

private func notam(_ category: String?, _ body: String, closure: Bool = false) -> Notam {
    Notam(notamKey: UUID().uuidString, number: "A1/26", qCode: nil, category: category, condition: nil,
          startsAt: nil, endsAt: nil, isPermanent: false, isEstimated: false, schedule: nil, body: body,
          rawText: body, isRunwayClosure: closure)
}

struct RampAdvisorTests {
    @Test func calmDayIsNormal() {
        let status = RampAdvisor.evaluate(conditions(), notams: [])
        #expect(status.severity == .normal)
        #expect(status.advisories.isEmpty)
        #expect(status.headline == "Normal ops")
    }

    @Test func thunderstormIsAWarning() {
        let status = RampAdvisor.evaluate(conditions(wx: "+TSRA"), notams: [])
        #expect(status.severity == .warning)
        #expect(status.advisories.first?.id == "ts")
        #expect(RampAdvisor.evaluate(conditions(wx: "VCTS"), notams: []).advisories.first?.title == "Thunderstorm nearby")
    }

    @Test func stormCloudsAndForecastAreCautions() {
        let cb = RampAdvisor.evaluate(conditions(metar: "METAR YSSY 060200Z 18010KT 9999 FEW030CB 20/10 Q1015"), notams: [])
        #expect(cb.severity == .caution)
        #expect(cb.advisories.map(\.id) == ["cb"])
        let taf = RampAdvisor.evaluate(conditions(taf: "TAF YSSY 060000Z 0600/0706 18010KT 9999 FEW030 TEMPO 0606/0610 VRB20G35KT 3000 TSRA"), notams: [])
        #expect(taf.advisories.map(\.id) == ["taf-ts"])
        // "TS" inside another word is not a thunderstorm.
        #expect(RampAdvisor.evaluate(conditions(taf: "TAF YSSY 060000Z 0600/0706 CAVOK RMK FCST TSTART"), notams: []).advisories.isEmpty)
    }

    @Test func windThresholds() {
        #expect(RampAdvisor.evaluate(conditions(wind: 20, gust: 30), notams: []).severity == .caution)
        #expect(RampAdvisor.evaluate(conditions(wind: 30, gust: 45), notams: []).severity == .warning)
        var custom = RampThresholds.standard
        custom.windWarningKt = 50
        #expect(RampAdvisor.evaluate(conditions(wind: 30, gust: 45), notams: [], thresholds: custom).severity == .caution)
    }

    @Test func heatAndCold() {
        // 35 °C with a 25 °C dew point feels like about 43 °C.
        let hot = RampAdvisor.evaluate(conditions(temp: 35, dew: 25), notams: [])
        #expect(hot.severity == .warning)
        #expect(abs((hot.heatIndexC ?? 0) - 43.3) < 0.5)
        #expect(RampAdvisor.evaluate(conditions(temp: 32, dew: 18), notams: []).severity == .caution)
        // Anchorage in winter: -20 °C in 20 kt.
        let cold = RampAdvisor.evaluate(conditions(wind: 20, temp: -20, dew: -25), notams: [])
        #expect(cold.advisories.contains { $0.id == "cold" && $0.severity == .warning })
        #expect(abs((cold.windChillC ?? 0) - (-33)) < 2)
    }

    @Test func iceAndLowVisibility() {
        #expect(RampAdvisor.evaluate(conditions(wx: "-FZDZ", temp: -1, dew: -2), notams: []).advisories.contains { $0.id == "ice" })
        let fog = RampAdvisor.evaluate(conditions(wx: "FG", vis: 0.12, visLower: false), notams: [])
        #expect(fog.advisories.contains { $0.id == "vis" && $0.title == "Low visibility, about 200 m" })
    }

    @Test func staleWeatherAndNotamsAreInformation() {
        let status = RampAdvisor.evaluate(conditions(age: 130), notams: [
            notam("apron", "APRON C STANDS 21-25 CLOSED"),
            notam(nil, "STAND 12 CLOSED DUE WIP"),
            notam("navaid", "VOR U/S"),
            notam("runway", "RWY 16R/34L CLSD", closure: true),
        ])
        #expect(status.severity == .normal)
        #expect(Set(status.advisories.map(\.id)) == ["stale", "rwy", "ramp-notams"])
        #expect(status.advisories.first { $0.id == "ramp-notams" }?.title == "2 apron or taxiway NOTAMs in force")
        #expect(status.advisories.first { $0.id == "stale" }?.title == "Weather is 2 h 10 min old")
    }

    @Test func missingWeatherIsACaution() {
        #expect(RampAdvisor.evaluate(nil, notams: []).severity == .caution)
    }
}

struct WeatherTextTests {
    @Test func describesWeatherGroups() {
        #expect(WeatherText.describe("-SHRA BR") == "Light rain showers, mist")
        #expect(WeatherText.describe("VCTS") == "Thunderstorm nearby")
        #expect(WeatherText.describe("+TSRA") == "Heavy thunderstorm with rain")
        #expect(WeatherText.describe("-FZDZ") == "Light freezing drizzle")
        #expect(WeatherText.describe("BLSN") == "Blowing snow")
        #expect(WeatherText.describe(nil) == nil)
        #expect(WeatherText.describe("") == nil)
    }

    @Test func windAndVisibility() {
        #expect(WeatherText.wind(dir: 90, variable: false, speed: 15, gust: 28) == "090° 15 kt, gusts 28")
        #expect(WeatherText.wind(dir: nil, variable: true, speed: 3, gust: nil) == "Variable 3 kt")
        #expect(WeatherText.wind(dir: 0, variable: false, speed: 0, gust: nil) == "Calm")
        #expect(WeatherText.visibility(sm: 6, isLowerBound: true) == "10 km or more")
        #expect(WeatherText.visibility(sm: 0.5, isLowerBound: false) == "800 m")
        #expect(WeatherText.visibility(sm: 4, isLowerBound: false) == "6 km")
    }
}

struct DecodingTests {
    /// The shape /api/snapshot serves (abridged from a real response).
    @Test func decodesSnapshot() throws {
        let json = """
        {"generated_at": "2026-10-06T02:35:27+00:00",
         "airports": [{"icao": "YSSY", "iata": "SYD", "name": "Sydney Kingsford Smith", "timezone": "Australia/Sydney",
                       "lat": -33.946, "lon": 151.177, "notam_source": null}],
         "conditions": {"icao": "YSSY", "iata": "SYD", "name": "Sydney Kingsford Smith", "lat": -33.946, "lon": 151.177,
           "timezone": "Australia/Sydney", "metar_observed_at": "2026-10-04T01:30:00+10:00",
           "metar_raw": "METAR YSSY 031530Z AUTO 29008KT 9999 // SCT094 15/14 Q1017", "flight_category": "VFR",
           "wind_variable": false, "wind_dir_deg": 290, "wind_speed_kt": 8, "wind_gust_kt": null, "visibility_sm": 6.0,
           "visibility_is_lower_bound": true, "ceiling_ft": null, "wx_string": null, "temp_c": 15.0, "dewpoint_c": 14.0,
           "altimeter_hpa": 1017.0, "taf_issued_at": null, "taf_valid_from": null, "taf_valid_to": null, "taf_raw": null,
           "notams_in_force": null, "metar_age_min": 2945},
         "weather": [], "notams": [],
         "medians": {"arrival_terminal_minutes": null, "departure_terminal_minutes": 9.5},
         "history": [{"callsign": "QFA044", "dir": "inbound", "other": null, "n": 1, "usual_min": 361.0, "days_14": 1,
                      "flight_number_iata": "QF44", "airline_name": "Qantas"}]}
        """
        let s = try JSON.decoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(s.conditions?.windDirDeg == 290)
        #expect(s.conditions?.metarObservedAt == (try Date("2026-10-03T15:30:00Z", strategy: .iso8601)))
        #expect(s.conditions?.notamsInForce == nil)
        #expect(s.medians.departureTerminalMinutes == 9.5)
        #expect(s.history.first?.days14 == 1)
        #expect(s.history.first?.dir == .inbound)
        #expect(s.history.first?.flightNumberIata == "QF44")
    }

    @Test func decodesLiveFeed() throws {
        let json = """
        {"time": 1791254029, "source": "adsb.lol", "failed": ["OpenSky: HTTP 429"], "aircraft": [
          {"icao24": "7c0461", "callsign": "JST773", "lon": 141.5, "lat": -35.8, "alt_ft": 35000, "on_ground": false,
           "speed_kt": 450, "track_deg": 118.21, "vrate_fpm": 0},
          {"icao24": "7c6dda", "callsign": null, "lon": 151.1, "lat": -33.9, "alt_ft": 0, "on_ground": true,
           "speed_kt": null, "track_deg": null, "vrate_fpm": null}]}
        """
        let feed = try JSON.decoder().decode(LiveFeed.self, from: Data(json.utf8))
        #expect(feed.aircraft.count == 2)
        #expect(feed.aircraft[0].altFt == 35000)
        #expect(feed.aircraft[1].onGround)
        #expect(feed.failed == ["OpenSky: HTTP 429"])
    }
}

struct RampAdvisorTimeTests {
    @Test func expiredTafIsIgnored() {
        var c = conditionsWithTaf()
        c.tafValidTo = Date.now.addingTimeInterval(-3600)
        #expect(RampAdvisor.evaluate(c, notams: []).advisories.isEmpty)
        c.tafValidTo = Date.now.addingTimeInterval(3600)
        #expect(RampAdvisor.evaluate(c, notams: []).advisories.map(\.id) == ["taf-ts"])
    }

    @Test func veryOldWeatherIsACaution() {
        var c = conditionsWithTaf()
        c.tafRaw = nil
        c.metarAgeMin = 120
        #expect(RampAdvisor.evaluate(c, notams: []).severity == .normal)
        c.metarAgeMin = 300
        #expect(RampAdvisor.evaluate(c, notams: []).severity == .caution)
    }

    private func conditionsWithTaf() -> Conditions {
        Conditions(icao: "VHHH", iata: "HKG", name: "Hong Kong", lat: 22.3, lon: 113.9, timezone: "Asia/Hong_Kong",
                   metarObservedAt: .now, metarRaw: "METAR VHHH 060230Z 10007KT 9999 FEW020 28/22 Q1010",
                   flightCategory: "VFR", windVariable: false, windDirDeg: 100, windSpeedKt: 7, windGustKt: nil,
                   visibilitySm: 6, visibilityIsLowerBound: true, ceilingFt: nil, wxString: nil, tempC: 26,
                   dewpointC: 20, altimeterHpa: 1010, tafIssuedAt: nil, tafValidFrom: nil, tafValidTo: nil,
                   tafRaw: "TAF VHHH 060500Z 0606/0712 10010KT 9999 FEW020 TEMPO 0606/0610 TSRA", notamsInForce: 3,
                   metarAgeMin: 20)
    }
}
