import Foundation
import GRDB
import XCTest
@testable import VibeToken

final class UsageTrendTests: XCTestCase {
    func testSelectsHourlyForShortRangesAndDailyForLongRanges() {
        XCTAssertEqual(UsageTrendGranularity.forRange(.today), .hourly)
        XCTAssertEqual(UsageTrendGranularity.forRange(.hours24), .hourly)
        XCTAssertEqual(UsageTrendGranularity.forRange(.days7), .daily)
        XCTAssertEqual(UsageTrendGranularity.forRange(.days30), .daily)
    }

    func testCalendarIntervalsPreservePartialRangeEdges() throws {
        let calendar = calendar()
        let start = try date(2026, 8, 5, 11, 30, calendar: calendar)
        let end = try date(2026, 8, 6, 11, 30, calendar: calendar)

        let hourly = UsageTrendGranularity.hourly.intervals(
            from: start,
            through: end,
            calendar: calendar
        )

        XCTAssertEqual(hourly.count, 25)
        XCTAssertEqual(hourly.first?.rangeStart, start)
        XCTAssertEqual(hourly.last?.rangeEnd, end)
        XCTAssertEqual(hourly.reduce(0) { $0 + $1.rangeEnd.timeIntervalSince($1.rangeStart) }, 86_400)

        let sevenDayStart = try date(2026, 7, 30, 11, 30, calendar: calendar)
        let daily = UsageTrendGranularity.daily.intervals(
            from: sevenDayStart,
            through: end,
            calendar: calendar
        )
        XCTAssertEqual(daily.count, 8)
        XCTAssertEqual(daily.first?.rangeStart, sevenDayStart)
        XCTAssertEqual(daily.last?.rangeEnd, end)
    }

    func testRepositoryFillsEmptyBucketsAndTrendCostUsesModelPricing() throws {
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let calendar = calendar()
        let start = try date(2026, 8, 6, 8, 30, calendar: calendar)
        let end = try date(2026, 8, 6, 10, 15, calendar: calendar)
        let intervals = UsageTrendGranularity.hourly.intervals(
            from: start,
            through: end,
            calendar: calendar
        )

        try database.writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO usage_sources (id, kind, display_name, status, accuracy)
                    VALUES ('codex', 'local_jsonl', 'Codex', 'online', 'exact')
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO conversations (
                        id, source_id, external_session_hash, model_id, started_at, last_event_at
                    ) VALUES ('codex:test', 'codex', 'test', 'gpt-5.6-sol', ?, ?)
                    """,
                arguments: [start, end]
            )
            try database.execute(
                sql: """
                    INSERT INTO usage_events (
                        idempotency_key, conversation_id, occurred_at, model_id,
                        input_tokens, cached_input_tokens, cache_write_tokens,
                        output_tokens, reasoning_tokens, total_tokens, accuracy
                    ) VALUES
                        ('first-sol', 'codex:test', ?, 'gpt-5.6-sol', 1000000, 0, 0, 0, 0, 1000000, 'exact'),
                        ('first-terra', 'codex:test', ?, 'gpt-5.6-terra', 1000000, 0, 0, 0, 0, 1000000, 'exact'),
                        ('last-sol', 'codex:test', ?, 'gpt-5.6-sol', 500000, 0, 0, 0, 0, 500000, 'exact')
                    """,
                arguments: [
                    start.addingTimeInterval(60),
                    start.addingTimeInterval(120),
                    end
                ]
            )
        }

        let series = try repository.trend(
            source: "codex",
            intervals: intervals,
            granularity: .hourly
        )
        let points = UsageTrendBuilder.points(
            from: series,
            costEstimator: CostEstimator(catalog: .vibeCafeCompatibleCodex)
        )

        XCTAssertEqual(series.buckets.count, 3)
        XCTAssertEqual(series.buckets.map(\.modelSnapshots.count), [2, 0, 1])
        XCTAssertEqual(points.map(\.totalTokens), [2_000_000, 0, 500_000])
        XCTAssertEqual(points.map { $0.estimatedCost?.micros }, [7_000_000, nil, 2_500_000])
        XCTAssertTrue(points.allSatisfy(\.isCostComplete))
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
