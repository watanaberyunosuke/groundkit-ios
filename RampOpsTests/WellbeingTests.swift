import Foundation
import Testing
@testable import RampOps

private func at(_ iso: String, _ zone: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    f.timeZone = TimeZone(identifier: zone)
    return f.date(from: iso)!
}

private func near(_ expected: Date, _ actual: Date?, minutes: Double) -> Bool {
    guard let actual else { return false }
    return abs(actual.timeIntervalSince(expected)) <= minutes * 60
}

private let h: TimeInterval = 3_600
private let day: TimeInterval = 86_400

struct SolarTests {
    @Test func sunriseAndSunsetMatchPublishedTimes() {
        // Hong Kong Observatory, 21 June 2026: sunrise 05:39, sunset 19:11.
        let (lat, lon) = (22.308, 113.918)
        let morning = at("2026-06-21T03:00", "Asia/Hong_Kong")
        #expect(Solar.isDark(lat: lat, lon: lon, at: morning))
        let sunrise = Solar.nextChange(lat: lat, lon: lon, after: morning)
        #expect(near(at("2026-06-21T05:39", "Asia/Hong_Kong"), sunrise, minutes: 3))
        #expect(!Solar.isDark(lat: lat, lon: lon, at: sunrise! + 5 * 60))
        #expect(near(at("2026-06-21T19:11", "Asia/Hong_Kong"), Solar.nextChange(lat: lat, lon: lon, after: sunrise! + 60), minutes: 3))

        // London Heathrow at the winter solstice: sunrise about 08:04, sunset about 15:54.
        let dawn = Solar.nextChange(lat: 51.47, lon: -0.4543, after: at("2026-12-21T00:00", "Europe/London"))
        #expect(near(at("2026-12-21T08:05", "Europe/London"), dawn, minutes: 4))
        #expect(near(at("2026-12-21T15:54", "Europe/London"), Solar.nextChange(lat: 51.47, lon: -0.4543, after: dawn! + 60), minutes: 4))
    }

    @Test func polarNightHasNoSunrise() {
        // Svalbard in mid-December: the sun stays down.
        let t = at("2026-12-15T12:00", "UTC")
        #expect(Solar.isDark(lat: 78.246, lon: 15.466, at: t))
        #expect(Solar.nextChange(lat: 78.246, lon: 15.466, after: t) == nil)
    }
}

struct FatigueTests {
    private let start = Date(timeIntervalSince1970: 100 * day) // duty starts

    private func span(_ from: TimeInterval, _ to: TimeInterval) -> SleepSpan {
        SleepSpan(start: start + from, end: start + to)
    }

    @Test func priorSleepWakeChecks() {
        // 7 h last night, 7 h the night before: fine.
        let rested = [span(-9 * h, -2 * h), span(-33 * h, -26 * h)]
        let ok = Fatigue.assess(sleep: rested, shifts: [], dutyStart: start, now: start + h)
        #expect(ok.sleep24h == 7 * h)
        #expect(ok.sleep48h == 14 * h)
        #expect(ok.awake == 3 * h)
        #expect(ok.findings.isEmpty)

        // 4 h last night and 6 h before: both sleep rules fail.
        let short = [span(-6 * h, -2 * h), span(-32 * h, -26 * h)]
        let bad = Fatigue.assess(sleep: short, shifts: [], dutyStart: start, now: start + h)
        #expect(bad.findings.map(\.title) == ["Under 5 h sleep in 24 h", "Under 12 h sleep in 48 h"])
        #expect(bad.findings.allSatisfy { $0.severity == .warning })

        // Late in a long duty: awake longer than the 14 h slept in 48 h.
        let late = Fatigue.assess(sleep: rested, shifts: [], dutyStart: start, now: start + 13 * h)
        #expect(late.findings.map(\.title) == ["Awake longer than you've slept"])

        // No sleep access, or nothing recorded (no tracker): unknown, not "no sleep".
        #expect(Fatigue.assess(sleep: nil, shifts: [], dutyStart: start, now: start + h).findings.isEmpty)
        let untracked = Fatigue.assess(sleep: [], shifts: [], dutyStart: start, now: start + h)
        #expect(untracked.sleep24h == nil)
        #expect(untracked.findings.isEmpty)
        // Only an old night, outside the 48 h: also unknown.
        #expect(Fatigue.assess(sleep: [span(-80 * h, -72 * h)], shifts: [], dutyStart: start, now: start + h).sleep48h == nil)
    }

    @Test func sleepOverlapsAndWindowEdgesCountOnce() {
        let t0 = Date(timeIntervalSince1970: 0)
        let spans = [SleepSpan(start: t0, end: t0 + 5 * h), SleepSpan(start: t0 + 3 * h, end: t0 + 8 * h),
                     SleepSpan(start: t0 + 20 * h, end: t0 + 30 * h)]
        #expect(Fatigue.sleptBetween(spans, from: t0, to: t0 + 10 * h) == 8 * h)
        #expect(Fatigue.sleptBetween(spans, from: t0 + 2 * h, to: t0 + 26 * h) == 12 * h)
    }

    @Test func restAndWeeklyHours() {
        let now = Date(timeIntervalSince1970: 50 * day)
        let shifts = [
            WorkSpan(start: now - 8 * h, end: nil), // on shift now, after
            WorkSpan(start: now - 26 * h, end: now - 16 * h), // 8 h off: short rest
        ] + (2...6).map { d in WorkSpan(start: now - Double(d) * day - 10 * h, end: now - Double(d) * day) }
        let f = Fatigue.assess(sleep: nil, shifts: shifts, dutyStart: now - 8 * h, now: now)
        #expect(f.rest == 8 * h)
        #expect(f.week == Double(8 + 10 + 5 * 10) * h)
        #expect(f.findings.map(\.title) == ["Short rest", "Over 48 h this week"])
        // Just off shift: rest so far is shown, but isn't a finding until a shift starts on it.
        let off = Fatigue.assess(sleep: nil, shifts: [WorkSpan(start: now - 9 * h, end: now - h)], dutyStart: nil, now: now)
        #expect(off.rest == h)
        #expect(off.findings.isEmpty)
    }
}

struct HeatStrainTests {
    private let now = Date(timeIntervalSince1970: 10 * day)

    private func samples(_ bpm: Double...) -> [HeatStrain.Sample] {
        bpm.enumerated().map { i, b in HeatStrain.Sample(at: now - Double(bpm.count - 1 - i) * 60, bpm: b) }
    }

    @Test func needsSustainedHeartRateInTheHeat() {
        // Age 40: limit 140. Five minutes all over it in 33 °C: warning.
        let high = samples(150, 148, 152, 145, 149, 151)
        #expect(HeatStrain.assess(high, feelsLikeC: 33, age: nil, now: now)?.severity == .warning)
        // The same heart rate in mild weather: nothing.
        #expect(HeatStrain.assess(high, feelsLikeC: 22, age: nil, now: now) == nil)
        // One spike: the lowest reading decides.
        #expect(HeatStrain.assess(samples(100, 98, 160, 102, 99, 101), feelsLikeC: 33, age: nil, now: now) == nil)
        // Close to the limit: caution.
        #expect(HeatStrain.assess(samples(130, 132, 129, 131, 133, 130), feelsLikeC: 33, age: nil, now: now)?.severity == .caution)
        // A 25-year-old's limit is 155, so 150 is only a caution.
        #expect(HeatStrain.limitBpm(age: 25) == 155)
        #expect(HeatStrain.assess(high, feelsLikeC: 33, age: 25, now: now)?.severity == .caution)
        // Too few minutes of data to call it sustained.
        #expect(HeatStrain.assess(samples(150, 150), feelsLikeC: 33, age: nil, now: now) == nil)
    }
}

struct ShiftAdviceTests {
    @Test func breaksAndLongestStretch() {
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(!ShiftAdvice.breakDue(workingSince: t0, now: t0 + 2 * h - 1))
        #expect(ShiftAdvice.breakDue(workingSince: t0, now: t0 + 2 * h))
        #expect(ShiftAdvice.longestStretch(start: t0, breaks: [], end: t0 + 4 * h) == 4 * h)
        #expect(ShiftAdvice.longestStretch(start: t0, breaks: [t0 + 3 * h, t0 + 5 * h], end: t0 + 7 * h) == 3 * h)
    }

    @Test func waterTargetRisesWithHeat() {
        #expect(ShiftAdvice.waterPerHourMl(feelsLikeC: nil) == 300)
        #expect(ShiftAdvice.waterPerHourMl(feelsLikeC: 28) == 500)
        #expect(ShiftAdvice.waterTargetMl(feelsLikeC: 36, hoursOnShift: 2) == 1500)
        #expect(ShiftAdvice.waterTargetMl(feelsLikeC: 20, hoursOnShift: 0.5) == 300)
    }
}
