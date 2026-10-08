import Foundation
import Testing
@testable import GroundKit

struct OffBlockTests {
    private let hkg = TimeZone(identifier: "Asia/Hong_Kong")!

    private func at(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = hkg
        return f.date(from: iso)!
    }

    // The same cases as the Android app's TurnaroundTest.
    @Test func offBlockTimeIsTodayOrTomorrowAtTheAirport() {
        let now = at("2026-10-08T14:00")
        #expect(OffBlock.at(hour: 14, minute: 45, in: hkg, now: now) == at("2026-10-08T14:45"))
        // Slightly in the past stays today (a late departure), not tomorrow.
        #expect(OffBlock.at(hour: 13, minute: 30, in: hkg, now: now) == at("2026-10-08T13:30"))
        // 23:30 picking 00:15 means after midnight.
        #expect(OffBlock.at(hour: 0, minute: 15, in: hkg, now: at("2026-10-08T23:30")) == at("2026-10-09T00:15"))
    }
}
