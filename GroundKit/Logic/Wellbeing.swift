import Foundation

// Fatigue and heat-strain checks for the Shift tab, and the shift guidance they sit with.
// Guidance only, not medical advice: rosters, the employer's fatigue and heat procedures,
// and supervisors decide.

/// A stretch of sleep from Health.
nonisolated struct SleepSpan: Sendable, Hashable {
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A finished or running shift; `end` nil while on shift.
nonisolated struct WorkSpan: Sendable, Hashable {
    var start: Date
    var end: Date?
}

/// One fatigue or heat-strain finding, worded for the crew member. Severity is caution or warning.
nonisolated struct Finding: Sendable, Hashable {
    var severity: Severity
    var title: String
    var detail: String
}

private nonisolated let minute: TimeInterval = 60
private nonisolated let hour: TimeInterval = 3_600
private nonisolated let day: TimeInterval = 86_400

/// Fatigue checks for one person, from their sleep and shifts. The sleep checks are the
/// prior sleep/wake model of Dawson and McCulloch (2005), used in ICAO's FRMS manual: at
/// least 5 h sleep in the 24 h before duty, at least 12 h in the 48 h before, and no longer
/// awake than the sleep in those 48 h. Rest and weekly hours follow the EU Working Time
/// Directive (11 h rest a day, 48 h a week).
nonisolated enum Fatigue {
    static let minSleep24h: TimeInterval = 5 * hour
    static let minSleep48h: TimeInterval = 12 * hour
    static let minRest: TimeInterval = 11 * hour
    static let weekHours: TimeInterval = 48 * hour

    struct Summary: Sendable, Hashable {
        /// Sleep in the 24 and 48 h before duty starts (or before now, off shift). Nil without
        /// sleep data: not allowed, or nothing recorded in those 48 h (no tracker worn).
        var sleep24h: TimeInterval?
        var sleep48h: TimeInterval?
        /// Time awake since the last sleep ended, now.
        var awake: TimeInterval?
        /// Rest between the previous shift's end and this one's start (or now, off shift).
        var rest: TimeInterval?
        /// Time worked in the 7 days to now, the running shift included.
        var week: TimeInterval
        var findings: [Finding]
    }

    /// `dutyStart` is the running shift's start, or nil off shift, when the checks are for
    /// a shift starting now.
    static func assess(sleep allSleep: [SleepSpan]?, shifts: [WorkSpan], dutyStart: Date?, now: Date) -> Summary {
        let ref = dutyStart ?? now
        // Nothing recorded at all means no data, not no sleep.
        let sleep = allSleep.flatMap { spans in
            spans.contains { $0.end > ref - 2 * day && $0.start < now } ? spans : nil
        }
        let sleep24 = sleep.map { sleptBetween($0, from: ref - day, to: ref) }
        let sleep48 = sleep.map { sleptBetween($0, from: ref - 2 * day, to: ref) }
        let lastWake = sleep?.filter { $0.start < now }.map { min($0.end, now) }.max()
        let awake = lastWake.map { now.timeIntervalSince($0) }
        let previousEnd = shifts.compactMap(\.end).filter { $0 <= ref }.max()
        let rest = previousEnd.map { ref.timeIntervalSince($0) }
        let week = shifts.reduce(0) { $0 + overlap($1.start, $1.end ?? now, now - 7 * day, now) }

        var findings: [Finding] = []
        if let sleep24, let sleep48 {
            if sleep24 < minSleep24h {
                findings.append(Finding(severity: .warning, title: "Under 5 h sleep in 24 h",
                                        detail: "\(hm(sleep24)) slept in the 24 h before duty. Fatigue risk is high: tell your supervisor and avoid safety-critical tasks."))
            }
            if sleep48 < minSleep48h {
                findings.append(Finding(severity: .warning, title: "Under 12 h sleep in 48 h",
                                        detail: "\(hm(sleep48)) slept in the 48 h before duty."))
            }
            if let awake, awake > sleep48 {
                findings.append(Finding(severity: .caution, title: "Awake longer than you've slept",
                                        detail: "Awake \(hm(awake)), more than the \(hm(sleep48)) slept in 48 h. Take a break before tasks that need full attention."))
            }
        }
        // Off shift, rest is still building up: only a shift starting on it is short of rest.
        if dutyStart != nil, let rest, rest < minRest {
            findings.append(Finding(severity: .caution, title: "Short rest",
                                    detail: "\(hm(rest)) off between shifts, under the usual 11 h."))
        }
        if week > weekHours {
            findings.append(Finding(severity: .caution, title: "Over 48 h this week",
                                    detail: "\(hm(week)) worked in the last 7 days."))
        }
        return Summary(sleep24h: sleep24, sleep48h: sleep48, awake: awake, rest: rest, week: week, findings: findings)
    }

    /// Sleep inside [from, to), counting overlapping spans once.
    static func sleptBetween(_ spans: [SleepSpan], from: Date, to: Date) -> TimeInterval {
        var total: TimeInterval = 0
        var covered = from
        for s in spans.sorted(by: { $0.start < $1.start }) {
            let a = max(s.start, covered)
            let b = min(s.end, to)
            if b > a {
                total += b.timeIntervalSince(a)
                covered = b
            }
        }
        return total
    }

    private static func overlap(_ a0: Date, _ a1: Date, _ b0: Date, _ b1: Date) -> TimeInterval {
        max(0, min(a1, b1).timeIntervalSince(max(a0, b0)))
    }

    /// "7 h 05 min", or "45 min".
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t / minute)
        return m >= 60 ? String(format: "%d h %02d min", m / 60, m % 60) : "\(m) min"
    }
}

/// Heat strain from heart rate in the heat. NIOSH's criteria (2016) treat a heart rate
/// sustained for several minutes above 180 minus age as excessive heat strain; with no age
/// set, 40 is assumed (140 bpm). Checked only when it feels like 27 °C or more, where the
/// water target also rises.
nonisolated enum HeatStrain {
    static let defaultAge = 40
    static let heatFromC = 27.0
    /// "Several minutes": the samples must cover at least this long.
    static let sustained: TimeInterval = 5 * minute
    /// How far below the limit counts as getting close.
    static let cautionMarginBpm = 15

    struct Sample: Sendable, Hashable {
        var at: Date
        var bpm: Double
    }

    static func limitBpm(age: Int?) -> Int {
        let a = age.flatMap { (16...80).contains($0) ? $0 : nil } ?? defaultAge
        return 180 - a
    }

    /// Uses the samples from the last `sustained`: their lowest value must be over the
    /// limit, so one spike (lifting a bag) does not count. Nil when there's nothing to say.
    static func assess(_ samples: [Sample], feelsLikeC: Double?, age: Int?, now: Date) -> Finding? {
        guard let feelsLikeC, feelsLikeC >= heatFromC else { return nil }
        let recent = samples.filter { $0.at >= now - sustained && $0.at <= now }.sorted { $0.at < $1.at }
        guard recent.count >= 3, let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= sustained * 3 / 5,
              let floor = recent.map(\.bpm).min() else { return nil }
        let limit = Double(limitBpm(age: age))
        let feels = String(format: "%.0f", feelsLikeC)
        if floor > limit {
            return Finding(severity: .warning, title: "Heat strain: heart rate over \(Int(limit)) bpm",
                           detail: "Your heart rate has stayed over \(Int(limit)) bpm for 5 minutes, and it feels like \(feels) °C. "
                               + "Stop, get into shade or air conditioning, drink water, and tell your supervisor. "
                               + "Confusion, headache, nausea or no sweating are an emergency.")
        }
        if floor > limit - Double(cautionMarginBpm) {
            return Finding(severity: .caution, title: "Heart rate high in the heat",
                           detail: "Over \(Int(limit) - cautionMarginBpm) bpm for 5 minutes, feels like \(feels) °C. Slow down and drink water.")
        }
        return nil
    }
}

/// Plain guidance from the weather and Health data.
nonisolated enum ShiftAdvice {
    /// Water to drink per hour on the ramp: about 250 ml every 20 minutes in heat stress
    /// (common occupational guidance), less otherwise.
    static func waterPerHourMl(feelsLikeC: Double?) -> Double {
        guard let feelsLikeC else { return 300 }
        if feelsLikeC >= 32 { return 750 }
        if feelsLikeC >= 27 { return 500 }
        return 300
    }

    /// What should have been drunk by now: at least one hour's worth, then pro rata.
    static func waterTargetMl(feelsLikeC: Double?, hoursOnShift: Double) -> Double {
        let perHour = waterPerHourMl(feelsLikeC: feelsLikeC)
        return max(perHour, perHour * hoursOnShift)
    }

    /// A break is due after 2 hours of work since the shift started or the last break.
    static let breakEvery: TimeInterval = 2 * hour

    static func breakDue(workingSince: Date, now: Date) -> Bool {
        now.timeIntervalSince(workingSince) >= breakEvery
    }

    /// The longest stretch worked without a logged break.
    static func longestStretch(start: Date, breaks: [Date], end: Date) -> TimeInterval {
        let marks = [start] + breaks.filter { $0 >= start && $0 <= end }.sorted() + [end]
        return zip(marks, marks.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0
    }

    /// Sustained exposure at or above 85 dB(A) calls for hearing protection.
    static let hearingProtectionDb = 85.0
}
