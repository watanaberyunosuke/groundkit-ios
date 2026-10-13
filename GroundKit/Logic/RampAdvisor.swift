import Foundation

// Ramp advisories from the latest METAR, TAF and NOTAMs. Advisory only: ramp closures,
// lightning alerts and wind limits are the airport's and airline's call, and the
// thresholds below are common defaults to be matched to local procedures.

nonisolated enum Severity: Int, Sendable, Comparable, Hashable {
    case info, normal, caution, warning

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

nonisolated struct Advisory: Sendable, Identifiable, Hashable {
    var id: String
    var severity: Severity
    var title: String
    var detail: String
    var symbol: String
}

nonisolated struct RampStatus: Sendable, Hashable {
    /// The worst advisory; `.normal` when there is none above info.
    var severity: Severity
    var advisories: [Advisory]
    var feelsLikeC: Double?
    var heatIndexC: Double?
    var windChillC: Double?

    var headline: String {
        switch severity {
        case .info, .normal: "Normal ops"
        case .caution: "Caution"
        case .warning: "Warning"
        }
    }
}

nonisolated struct RampThresholds: Sendable, Hashable, Codable {
    /// Wind or gust (kt) at which loose equipment and doors need attention.
    var windCautionKt = 25
    /// Wind or gust (kt) at which many operators stop high-loader, stairs and door operations.
    var windWarningKt = 40
    var heatCautionC = 32.0
    var heatWarningC = 41.0
    var windChillCautionC = -10.0
    /// Exposed skin can freeze in 30 minutes or less below about -27 °C wind chill.
    var windChillWarningC = -27.0
    /// About 800 m.
    var lowVisibilitySm = 0.5
    /// METARs are normally half-hourly or hourly.
    var staleMetarMinutes = 90

    static let standard = RampThresholds()
}

nonisolated enum RampAdvisor {
    /// NOTAM categories (from the Q-code) that affect work on the apron.
    static let rampCategories: Set<String> = ["apron", "taxiway", "movement_area", "aerodrome", "lighting", "obstacle"]
    /// For NOTAMs without a Q-line (Australian and US domestic), match the text instead.
    static let rampWords = #"\b(APRON|APN|STAND|STANDS|BAY|BAYS|GATE|TWY|TAXIWAY|PARKING)\b"#

    static func isRampRelevant(_ n: Notam) -> Bool {
        if let category = n.category, rampCategories.contains(category) { return true }
        let text = (n.body ?? n.rawText ?? "").uppercased()
        return n.category == nil && text.matches(rampWords)
    }

    static func evaluate(_ c: Conditions?, notams: [Notam], thresholds t: RampThresholds = .standard,
                         now: Date = .now) -> RampStatus {
        guard let c else {
            return RampStatus(severity: .caution, advisories: [Advisory(
                id: "no-weather", severity: .caution, title: "No weather yet",
                detail: "The latest METAR has not loaded. Check the airport's own weather display.",
                symbol: "icloud.slash")])
        }
        var out: [Advisory] = []
        let wx = (c.wxString ?? "").uppercased()
        let metar = (c.metarRaw ?? "").uppercased()
        let codes = WeatherText.codes(wx)
        func has(_ any: String...) -> Bool { any.contains(where: codes.contains) }

        // Lightning: the biggest single risk on the ramp, through fuel hoses, headset
        // cords to the aircraft and open ground.
        if wx.contains("TS") {
            out.append(Advisory(
                id: "ts", severity: .warning, title: "Thunderstorm \(wx.contains("VCTS") ? "nearby" : "at the airport")",
                detail: "Lightning risk. Expect a ramp freeze: no fuelling, loading or headset to the aircraft while the lightning alert is on. Shelter in a building or vehicle.",
                symbol: "cloud.bolt.rain.fill"))
        } else if metar.matches(#"\d{3}(CB|TCU)\b"#) {
            out.append(Advisory(
                id: "cb", severity: .caution, title: "Storm clouds reported",
                detail: "Cumulonimbus or towering cumulus in the METAR. Thunderstorms can develop quickly; watch for the lightning alert.",
                symbol: "cloud.bolt"))
        }
        if !wx.contains("TS"), c.tafValidTo.map({ $0 > now }) ?? true, let taf = c.tafRaw?.uppercased(), taf.matches(#"(^|\s)(\+|-|VC)?TS(RA|SN|GR|GS|PL|DZ|UP)*(\s|$)"#) {
            let until = c.tafValidTo.map { " (TAF valid to \(LocalTime.hhmm($0, .gmt))Z)" } ?? ""
            out.append(Advisory(
                id: "taf-ts", severity: .caution, title: "Thunderstorms forecast",
                detail: "The TAF includes thunderstorms\(until). Plan for possible ramp freezes.",
                symbol: "cloud.bolt"))
        }

        // Wind: ULDs, dollies, stairs, cones, doors and FOD.
        let wind = max(c.windSpeedKt ?? 0, c.windGustKt ?? 0)
        let windWords = c.windGustKt.map { "gusts \($0) kt" } ?? "\(wind) kt"
        if wind >= t.windWarningKt {
            out.append(Advisory(
                id: "wind", severity: .warning, title: "Strong wind, \(windWords)",
                detail: "Secure ULDs, dollies, stairs and cones. Check aircraft door, high-loader and jet bridge wind limits before use.",
                symbol: "wind"))
        } else if wind >= t.windCautionKt {
            out.append(Advisory(
                id: "wind", severity: .caution, title: "Gusty wind, \(windWords)",
                detail: "Chock and brake equipment, keep doors in hand and watch for FOD and loose cargo nets.",
                symbol: "wind"))
        }

        // Hail: injury risk in the open and damage to aircraft skins and GSE.
        if has("GR", "GS") {
            out.append(Advisory(
                id: "hail", severity: .warning, title: "Hail reported",
                detail: "Shelter in a building or vehicle and protect equipment. Expect hail damage checks before departure.",
                symbol: "cloud.hail.fill"))
        }
        // Squall or funnel cloud: sudden, much stronger wind than the mean.
        if has("SQ", "FC") {
            out.append(Advisory(
                id: "squall", severity: .warning, title: has("FC") ? "Funnel cloud reported" : "Squall reported",
                detail: "Expect sudden strong wind. Secure ULDs, dollies, stairs and cones, and keep clear of open doors.",
                symbol: "tornado"))
        }

        // Ice and snow: slippery apron, de-icing, slower turnarounds. Freezing rain,
        // drizzle or fog glazes everything it touches, so it is a warning.
        if has("FZ") {
            let kind = wx.contains("FZRA") ? "rain" : wx.contains("FZDZ") ? "drizzle" : wx.contains("FZFG") ? "fog" : "precipitation"
            out.append(Advisory(
                id: "ice", severity: .warning, title: "Freezing \(kind)",
                detail: "Ice forms on the apron, stairs, equipment and aircraft. De-icing likely: allow for longer turnarounds and keep clear of de-icing rigs.",
                symbol: "snowflake"))
        } else if has("SN", "PL", "IC", "SG") {
            out.append(Advisory(
                id: "ice", severity: .caution, title: "Ice or snow",
                detail: "Slippery apron and equipment. De-icing likely: allow for longer turnarounds and keep clear of de-icing rigs.",
                symbol: "snowflake"))
        } else if let temp = c.tempC, temp <= 0, has("RA", "DZ") {
            out.append(Advisory(
                id: "ice", severity: .caution, title: "Freezing conditions",
                detail: "Rain at or below 0°C can glaze the apron and equipment.",
                symbol: "thermometer.snowflake"))
        }

        // Dust or sand: eyes, open holds and ULDs.
        if has("DS", "SS", "SA", "DU") {
            out.append(Advisory(
                id: "dust", severity: .caution, title: "Dust or sand",
                detail: "Wear eye protection. Keep holds and doors closed when not loading, and cover ULDs.",
                symbol: "sun.dust"))
        }

        // Heat and cold stress.
        let heat = c.tempC.flatMap { t in c.dewpointC.map { HeatStress.heatIndexC(tempC: t, dewpointC: $0) } }
        let chill = c.tempC.flatMap { t in c.windSpeedKt.map { HeatStress.windChillC(tempC: t, windKt: Double($0)) } }
        if let heat, heat >= t.heatWarningC {
            out.append(Advisory(
                id: "heat", severity: .warning, title: "Extreme heat, feels like \(Int(heat.rounded()))°C",
                detail: "Rotate crews, take shade breaks and drink water every 15 to 20 minutes. Watch each other for heat illness.",
                symbol: "sun.max.trianglebadge.exclamationmark"))
        } else if let heat, heat >= t.heatCautionC {
            out.append(Advisory(
                id: "heat", severity: .caution, title: "Heat stress, feels like \(Int(heat.rounded()))°C",
                detail: "Drink about 250 ml every 20 minutes, even if not thirsty. Take breaks in the shade.",
                symbol: "sun.max"))
        }
        if let chill, chill <= t.windChillWarningC {
            out.append(Advisory(
                id: "cold", severity: .warning, title: "Frostbite risk, wind chill \(Int(chill.rounded()))°C",
                detail: "Exposed skin can freeze in 30 minutes or less. Cover up fully and limit time outside.",
                symbol: "thermometer.snowflake"))
        } else if let chill, chill <= t.windChillCautionC {
            out.append(Advisory(
                id: "cold", severity: .caution, title: "Very cold, wind chill \(Int(chill.rounded()))°C",
                detail: "Wear insulated gloves and cover exposed skin. Warm up between tasks.",
                symbol: "thermometer.snowflake"))
        }

        // Low visibility. LIFR and IFR go by the flight category, as on Android; below that,
        // by the reported visibility or fog.
        let metres = c.visibilitySm.map { Int(($0 * 1609.34 / 50).rounded()) * 50 }
        let visWords = c.visibilitySm == nil ? "Visibility not reported"
            : "Visibility \(WeatherText.visibility(sm: c.visibilitySm, isLowerBound: c.visibilityIsLowerBound))"
        let ceilingWords = c.ceilingFt.map { ", ceiling \($0.formatted()) ft" } ?? ""
        if c.flightCategory == "LIFR" {
            out.append(Advisory(
                id: "vis", severity: .warning, title: "Low visibility (LIFR)",
                detail: "\(visWords)\(ceilingWords). Low visibility procedures may be in force: beacons and lights on, extra care near taxiways and moving aircraft.",
                symbol: "eye.slash"))
        } else if c.flightCategory == "IFR" {
            out.append(Advisory(
                id: "vis", severity: .caution, title: "Reduced visibility (IFR)",
                detail: "\(visWords)\(ceilingWords). Take extra care near taxiways and moving aircraft.",
                symbol: "eye.slash"))
        } else if let metres, let vis = c.visibilitySm, vis < t.lowVisibilitySm || has("FG") {
            out.append(Advisory(
                id: "vis", severity: .caution, title: "Low visibility, about \(metres) m",
                detail: "Low visibility procedures may be in force: beacons and lights on, extra care near taxiways and moving aircraft.",
                symbol: "eye.slash"))
        }

        // Rain: wet, slippery apron and wet bags. Not when ice or hail already covers it.
        if has("RA", "DZ", "UP"), !out.contains(where: { ["ice", "hail"].contains($0.id) }) {
            let heavy = wx.contains("+")
            out.append(Advisory(
                id: "rain", severity: .info, title: heavy ? "Heavy rain" : "Rain",
                detail: "Wet, slippery apron. Keep bags and cargo covered.",
                symbol: heavy ? "cloud.heavyrain" : "cloud.rain"))
        }

        // Information.
        // Old weather can hide a hazard, so a long gap is a caution, not just a note.
        if let age = c.metarAgeMin, age > t.staleMetarMinutes {
            out.append(Advisory(
                id: "stale", severity: age > 3 * t.staleMetarMinutes ? .caution : .info,
                title: "Weather is \(age.formattedAge) old",
                detail: "The latest METAR is older than usual, so the advice here may be out of date. Check the airport's own weather display.",
                symbol: "clock.badge.exclamationmark"))
        }
        let closures = notams.filter { $0.isRunwayClosure == true }.count
        if closures > 0 {
            out.append(Advisory(
                id: "rwy", severity: .info, title: "\(closures) runway closure NOTAM\(closures == 1 ? "" : "s") in force",
                detail: "Expect changed taxi routes and arrival rates.", symbol: "road.lanes"))
        }
        let ramp = notams.filter(isRampRelevant).count
        if ramp > 0 {
            out.append(Advisory(
                id: "ramp-notams", severity: .info, title: "\(ramp) apron or taxiway NOTAM\(ramp == 1 ? "" : "s") in force",
                detail: "See NOTAMs below for closed stands, taxiways and works.", symbol: "exclamationmark.bubble"))
        }

        out.sort { $0.severity > $1.severity }
        return RampStatus(severity: max(out.map(\.severity).max() ?? .normal, .normal), advisories: out,
                          feelsLikeC: HeatStress.feelsLikeC(tempC: c.tempC, dewpointC: c.dewpointC, windKt: c.windSpeedKt),
                          heatIndexC: heat, windChillC: chill)
    }
}

nonisolated enum HeatStress {
    /// NOAA heat index (Rothfusz regression with Steadman's simple formula below 80 °F),
    /// from temperature and dew point. Equals the temperature below about 27 °C.
    static func heatIndexC(tempC: Double, dewpointC: Double) -> Double {
        let rh = relativeHumidity(tempC: tempC, dewpointC: dewpointC)
        let tf = tempC * 9 / 5 + 32
        var hi = 0.5 * (tf + 61 + (tf - 68) * 1.2 + rh * 0.094)
        if (hi + tf) / 2 >= 80 {
            hi = -42.379 + 2.04901523 * tf + 10.14333127 * rh - 0.22475541 * tf * rh
                - 0.00683783 * tf * tf - 0.05481717 * rh * rh + 0.00122874 * tf * tf * rh
                + 0.00085282 * tf * rh * rh - 0.00000199 * tf * tf * rh * rh
            if rh < 13 && (80...112).contains(tf) {
                hi -= (13 - rh) / 4 * sqrt((17 - abs(tf - 95)) / 17)
            } else if rh > 85 && (80...87).contains(tf) {
                hi += (rh - 85) / 10 * ((87 - tf) / 5)
            }
        } else {
            return tempC
        }
        return (hi - 32) * 5 / 9
    }

    /// Environment Canada / NWS wind chill; the temperature itself outside its range
    /// (above 10 °C or wind under 5 km/h).
    static func windChillC(tempC: Double, windKt: Double) -> Double {
        let kmh = windKt * 1.852
        guard tempC <= 10, kmh > 4.8 else { return tempC }
        let v = pow(kmh, 0.16)
        return 13.12 + 0.6215 * tempC - 11.37 * v + 0.3965 * tempC * v
    }

    static func feelsLikeC(tempC: Double?, dewpointC: Double?, windKt: Int?) -> Double? {
        guard let tempC else { return nil }
        if tempC >= 27, let dewpointC { return heatIndexC(tempC: tempC, dewpointC: dewpointC) }
        if tempC <= 10, let windKt { return windChillC(tempC: tempC, windKt: Double(windKt)) }
        return tempC
    }

    /// Magnus formula, percent.
    static func relativeHumidity(tempC: Double, dewpointC: Double) -> Double {
        let a = 17.625, b = 243.04
        return min(100, 100 * exp(a * dewpointC / (b + dewpointC)) / exp(a * tempC / (b + tempC)))
    }
}

extension Int {
    /// "45 min", "2 h 5 min".
    nonisolated var formattedAge: String {
        self < 60 ? "\(self) min" : self % 60 == 0 ? "\(self / 60) h" : "\(self / 60) h \(self % 60) min"
    }
}

extension String {
    nonisolated func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
