import Foundation

/// Distance, bearing and local-time helpers, as in the Dive (dives/airport_conditions).
nonisolated enum Geo {
    static let terminalKm = 92.6 // 50 NM, as in dbt_project.yml
    static let kmPerNm = 1.852

    static func distKm(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = Double.pi / 180
        let h = pow(sin((la2 - la1) * r / 2), 2)
            + cos(la1 * r) * cos(la2 * r) * pow(sin((lo2 - lo1) * r / 2), 2)
        return 2 * 6371.0088 * asin(sqrt(h))
    }

    /// Initial great-circle bearing from point 1 to point 2, degrees.
    static func bearingDeg(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = Double.pi / 180
        let y = sin((lo2 - lo1) * r) * cos(la2 * r)
        let x = cos(la1 * r) * sin(la2 * r) - sin(la1 * r) * cos(la2 * r) * cos((lo2 - lo1) * r)
        return (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
    }
}

nonisolated enum LocalTime {
    /// Minutes after local midnight in `timeZone`.
    static func minuteOfDay(_ date: Date, _ timeZone: TimeZone) -> Double {
        let c = calendar(timeZone).dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// The signed difference of two times of day wrapped to [-720, 720), so 23:50 vs
    /// 00:10 is -20, not 1420.
    static func wrap(_ minutes: Double) -> Double {
        var x = (minutes + 720).truncatingRemainder(dividingBy: 1440)
        if x < 0 { x += 1440 }
        return x - 720
    }

    /// "HH:MM" for minutes after midnight.
    static func hhmm(minutes: Double) -> String {
        var m = Int(minutes.rounded()) % 1440
        if m < 0 { m += 1440 }
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// 24-hour "HH:MM" in `timeZone`. Aviation never uses a 12-hour clock.
    static func hhmm(_ date: Date, _ timeZone: TimeZone) -> String {
        hhmm(minutes: minuteOfDay(date, timeZone))
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}
