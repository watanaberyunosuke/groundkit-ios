import Foundation

/// Plain words for METAR codes, for people who don't read METARs every day.
nonisolated enum WeatherText {
    private static let descriptors: [String: String] = [
        "MI": "shallow", "PR": "partial", "BC": "patches of", "DR": "low drifting",
        "BL": "blowing", "FZ": "freezing",
    ]
    private static let phenomena: [String: String] = [
        "DZ": "drizzle", "RA": "rain", "SN": "snow", "SG": "snow grains", "IC": "ice crystals",
        "PL": "ice pellets", "GR": "hail", "GS": "small hail", "UP": "precipitation",
        "BR": "mist", "FG": "fog", "FU": "smoke", "VA": "volcanic ash", "DU": "dust",
        "SA": "sand", "HZ": "haze", "PY": "spray", "PO": "dust whirls", "SQ": "squalls",
        "FC": "funnel cloud", "SS": "sandstorm", "DS": "duststorm",
    ]

    /// "-SHRA BR" -> "Light rain showers, mist". Nil for no weather.
    static func describe(_ wx: String?) -> String? {
        guard let wx, !wx.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let parts = wx.split(separator: " ").map { describeGroup(String($0)) }
        guard let first = parts.first else { return nil }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }

    static func describeGroup(_ group: String) -> String {
        var g = Substring(group)
        var intensity: String?
        var nearby = false
        if g.hasPrefix("-") { intensity = "light"; g = g.dropFirst() }
        else if g.hasPrefix("+") { intensity = "heavy"; g = g.dropFirst() }
        if g.hasPrefix("VC") { nearby = true; g = g.dropFirst(2) }

        var showers = false, thunder = false
        var words: [String] = []
        var things: [String] = []
        while g.count >= 2 {
            let code = String(g.prefix(2))
            g = g.dropFirst(2)
            if code == "SH" { showers = true }
            else if code == "TS" { thunder = true }
            else if let d = descriptors[code] { words.append(d) }
            else if let p = phenomena[code] { things.append(p) }
            else { return group } // not a weather group we know: show it as is
        }
        var text: String
        if thunder {
            text = "thunderstorm" + (things.isEmpty ? "" : " with " + things.joined(separator: " and "))
        } else {
            text = (words + [things.joined(separator: " and ")]).filter { !$0.isEmpty }.joined(separator: " ")
            if showers { text = text.isEmpty ? "showers" : text + " showers" }
        }
        if let intensity { text = intensity + " " + text }
        if nearby { text += " nearby" }
        return text
    }

    /// "270° 15 kt, gusts 28" or "Variable 3 kt" or "Calm".
    static func wind(dir: Int?, variable: Bool?, speed: Int?, gust: Int?) -> String {
        guard let speed else { return "–" }
        if speed == 0 && gust == nil { return "Calm" }
        let from = variable == true || dir == nil ? "Variable" : String(format: "%03d°", dir!)
        return "\(from) \(speed) kt" + (gust.map { ", gusts \($0)" } ?? "")
    }

    /// Statute miles to metres, rounded as a METAR would report them.
    static func visibility(sm: Double?, isLowerBound: Bool?) -> String {
        guard let sm else { return "–" }
        let metres = sm * 1609.34
        if isLowerBound == true || metres >= 9999 { return "10 km or more" }
        if metres >= 5000 { return "\(Int((metres / 1000).rounded())) km" }
        return "\(Int((metres / 100).rounded()) * 100) m"
    }
}
