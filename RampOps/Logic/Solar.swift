import Foundation

/// Where the sun is at an airport, for the Sunset appearance: dark from sunset to sunrise
/// there, whatever the phone's own setting. The Astronomical Almanac's low-precision
/// formulae, good to about 0.01° (a minute or so of sunrise time) for decades either side
/// of 2000.
nonisolated enum Solar {
    /// Sunrise and sunset are when the sun's centre is 0.833° below the horizon (refraction plus its radius).
    static let sunsetDeg = -0.833

    /// The sun's altitude above the horizon in degrees, without refraction.
    static func elevationDeg(lat: Double, lon: Double, at date: Date) -> Double {
        let r = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0 // days since J2000.0
        let meanLon = norm(280.460 + 0.9856474 * n)
        let g = norm(357.528 + 0.9856003 * n) * r
        let eclLon = (meanLon + 1.915 * sin(g) + 0.020 * sin(2 * g)) * r
        let obliquity = (23.439 - 0.0000004 * n) * r
        let ra = atan2(cos(obliquity) * sin(eclLon), cos(eclLon))
        let dec = asin(sin(obliquity) * sin(eclLon))
        let gmstDeg = norm((18.697374558 + 24.06570982441908 * n) * 15)
        let hourAngle = (gmstDeg + lon) * r - ra
        return asin(sin(lat * r) * sin(dec) + cos(lat * r) * cos(dec) * cos(hourAngle)) / r
    }

    static func isDark(lat: Double, lon: Double, at date: Date) -> Bool {
        elevationDeg(lat: lat, lon: lon, at: date) < sunsetDeg
    }

    /// The next sunrise or sunset after `date`, to the minute, or nil if there is none in
    /// the next two days (polar day or night).
    static func nextChange(lat: Double, lon: Double, after date: Date) -> Date? {
        let darkNow = isDark(lat: lat, lon: lon, at: date)
        var t = date
        while t < date + 2 * 86_400 {
            let next = t + step
            if isDark(lat: lat, lon: lon, at: next) != darkNow {
                var lo = t, hi = next
                while hi.timeIntervalSince(lo) > 60 {
                    let mid = lo + hi.timeIntervalSince(lo) / 2
                    if isDark(lat: lat, lon: lon, at: mid) == darkNow { lo = mid } else { hi = mid }
                }
                return hi
            }
            t = next
        }
        return nil
    }

    private static func norm(_ deg: Double) -> Double {
        let x = deg.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    private static let step: TimeInterval = 10 * 60
}
