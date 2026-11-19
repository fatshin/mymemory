import XCTest

/// 書き出しは利用者が外へ持ち出す唯一の形。時刻順・欠落なし・環境に依存しない表記を固定する。
final class ExportFormatterTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Tokyo")!
    private let ja = Locale(identifier: "ja_JP")

    private func date(_ h: Int, _ m: Int) -> Date {
        var c = DateComponents(year: 2026, month: 11, day: 20, hour: h, minute: m)
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testDayIsChronologicalAndKeepsAllText() {
        let later = ExportEntry(startedAt: date(14, 0), duration: 600, summary: "午後の要約", transcript: "午後の会話")
        let earlier = ExportEntry(startedAt: date(9, 5), duration: 599, summary: nil, transcript: "朝の会話")
        let md = ExportFormatter.day(date(0, 0), entries: [later, earlier], reflection: "1日の流れ",
                                     locale: ja, timeZone: tz)
        for s in ["振り返り", "1日の流れ", "午後の要約", "午後の会話", "朝の会話", "9:05", "14:00", "(10分)"] {
            XCTAssertTrue(md.contains(s), "missing \(s)")
        }
        let morning = md.range(of: "朝の会話")!.lowerBound
        let afternoon = md.range(of: "午後の会話")!.lowerBound
        XCTAssertLessThan(morning, afternoon)
    }

    func testEmptyRecordingIsMarkedNotDropped() {
        let e = ExportEntry(startedAt: date(10, 0), duration: 60, summary: nil, transcript: nil)
        XCTAssertTrue(ExportFormatter.recording(e, locale: ja, timeZone: tz).contains("(文字起こしなし)"))
    }

    func testNoReflectionSectionWhenAbsent() {
        let md = ExportFormatter.day(date(0, 0), entries: [], reflection: nil, locale: ja, timeZone: tz)
        XCTAssertFalse(md.contains("振り返り"))
    }

    func testFileNameUsesLocalDay() {
        XCTAssertEqual(ExportFormatter.fileName(for: date(23, 30), timeZone: tz), "MyMemory-2026-11-20.md")
    }
}
