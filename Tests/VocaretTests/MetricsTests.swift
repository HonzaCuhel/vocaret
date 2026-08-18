import XCTest
@testable import VocaretCore

final class MetricsTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private func rec(_ date: Date, words: Int, seconds: Double, latency: Double = 0.5) -> DictationRecord {
        DictationRecord(date: date, text: Array(repeating: "slovo", count: words).joined(separator: " "),
                        recordingSeconds: seconds, transcriptionSeconds: latency, model: "test")
    }

    func testWordCountFromText() {
        XCTAssertEqual(DictationRecord(date: Date(), text: "Ahoj, jak se máš?", recordingSeconds: 1, transcriptionSeconds: 0.1, model: "m").wordCount, 4)
        XCTAssertEqual(DictationRecord(date: Date(), text: "  ", recordingSeconds: 1, transcriptionSeconds: 0.1, model: "m").wordCount, 0)
    }

    func testTotalsAndSpeakingSpeed() {
        let now = date(2026, 8, 18, 15)
        let records = [rec(date(2026, 8, 18, 9), words: 120, seconds: 60), rec(date(2026, 8, 17, 9), words: 60, seconds: 60)]
        let stats = DashboardStats.compute(records: records, now: now, calendar: cal)
        XCTAssertEqual(stats.totalWords, 180)
        XCTAssertEqual(stats.wordsToday, 120)
        XCTAssertEqual(stats.averageWPM, 90, accuracy: 0.01) // 180 words / 2 min
        XCTAssertEqual(stats.totalSessions, 2)
    }

    func testTimeSavedAgainstTypingBaseline() {
        // 400 words spoken in 4 min; typing at 40 WPM would take 10 min → saved 6 min.
        let now = date(2026, 8, 18)
        let stats = DashboardStats.compute(records: [rec(now, words: 400, seconds: 240)], now: now, calendar: cal)
        XCTAssertEqual(stats.timeSavedSeconds, 360, accuracy: 0.01)
    }

    func testStreakCountsConsecutiveDaysEndingTodayOrYesterday() {
        let now = date(2026, 8, 18, 20)
        let three = [rec(date(2026, 8, 18), words: 5, seconds: 5), rec(date(2026, 8, 17), words: 5, seconds: 5), rec(date(2026, 8, 16), words: 5, seconds: 5)]
        XCTAssertEqual(DashboardStats.compute(records: three, now: now, calendar: cal).streakDays, 3)
        // Gap breaks it.
        let gap = [rec(date(2026, 8, 18), words: 5, seconds: 5), rec(date(2026, 8, 16), words: 5, seconds: 5)]
        XCTAssertEqual(DashboardStats.compute(records: gap, now: now, calendar: cal).streakDays, 1)
        // Nothing yet today but yesterday counts — the streak is alive.
        let yesterday = [rec(date(2026, 8, 17), words: 5, seconds: 5), rec(date(2026, 8, 16), words: 5, seconds: 5)]
        XCTAssertEqual(DashboardStats.compute(records: yesterday, now: now, calendar: cal).streakDays, 2)
        XCTAssertEqual(DashboardStats.compute(records: [], now: now, calendar: cal).streakDays, 0)
    }

    func testHourlyHistogramAndPeakHour() {
        let now = date(2026, 8, 18, 20)
        let records = [rec(date(2026, 8, 18, 9), words: 10, seconds: 5), rec(date(2026, 8, 17, 9), words: 30, seconds: 5), rec(date(2026, 8, 18, 14), words: 20, seconds: 5)]
        let stats = DashboardStats.compute(records: records, now: now, calendar: cal)
        XCTAssertEqual(stats.wordsByHour.count, 24)
        XCTAssertEqual(stats.wordsByHour[9], 40)
        XCTAssertEqual(stats.wordsByHour[14], 20)
        XCTAssertEqual(stats.peakHour, 9)
    }

    func testDailyWordsSeriesCoversLast14Days() {
        let now = date(2026, 8, 18, 20)
        let stats = DashboardStats.compute(records: [rec(date(2026, 8, 18), words: 7, seconds: 5), rec(date(2026, 8, 1), words: 999, seconds: 5)], now: now, calendar: cal)
        XCTAssertEqual(stats.dailyWords.count, 14)
        XCTAssertEqual(stats.dailyWords.last?.words, 7)
        XCTAssertEqual(stats.dailyWords.map(\.words).reduce(0, +), 7) // Aug 1 is outside the window
    }

    func testUntimedImportsDoNotDistortSpeedOrTimeSaved() {
        // Records imported from the old Markdown history have no timing. They
        // must count toward word totals but not toward pace or time saved —
        // otherwise 2 000 imported words over 10 measured seconds = 12 000 wpm.
        let now = date(2026, 8, 18, 15)
        let imported = rec(date(2026, 8, 17), words: 2000, seconds: 0, latency: 0)
        let timed = rec(date(2026, 8, 18), words: 100, seconds: 60)
        let stats = DashboardStats.compute(records: [imported, timed], now: now, calendar: cal)
        XCTAssertEqual(stats.totalWords, 2100)
        XCTAssertEqual(stats.averageWPM, 100, accuracy: 0.01)
        XCTAssertEqual(stats.timeSavedSeconds, 100.0 / 40 * 60 - 60, accuracy: 0.01)
    }

    func testEmptyIsSafe() {
        let stats = DashboardStats.compute(records: [], now: Date(), calendar: cal)
        XCTAssertEqual(stats.averageWPM, 0)
        XCTAssertNil(stats.peakHour)
        XCTAssertEqual(stats.timeSavedSeconds, 0)
    }
}
