import GRDB
import XCTest
@testable import VibeToken

final class DatabaseMigrationTests: XCTestCase {
    func testInitialMigrationCreatesRequiredTables() throws {
        let database = try VibeTokenDatabase.inMemory()
        let tables = try database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }

        XCTAssertTrue(tables.contains("usage_sources"))
        XCTAssertTrue(tables.contains("conversations"))
        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("ingest_checkpoints"))
        XCTAssertTrue(tables.contains("price_rules"))
        XCTAssertTrue(tables.contains("codex_raw_token_records"))

        let conversationColumns = try database.writer.read { db in
            try db.columns(in: "conversations").map(\.name)
        }
        let eventColumns = try database.writer.read { db in
            try db.columns(in: "usage_events").map(\.name)
        }
        let checkpointColumns = try database.writer.read { db in
            try db.columns(in: "ingest_checkpoints").map(\.name)
        }
        XCTAssertTrue(conversationColumns.contains("parent_session_hash"))
        XCTAssertTrue(conversationColumns.contains("forked_from_session_hash"))
        XCTAssertTrue(conversationColumns.contains("replay_token_count"))
        XCTAssertTrue(eventColumns.contains("model_id"))
        XCTAssertTrue(eventColumns.contains("raw_token_ordinal"))
        XCTAssertTrue(eventColumns.contains("replay_fingerprint"))
        XCTAssertTrue(checkpointColumns.contains("current_model"))
        XCTAssertTrue(checkpointColumns.contains("last_total_tokens"))
        XCTAssertTrue(checkpointColumns.contains("raw_token_count"))
        XCTAssertTrue(checkpointColumns.contains("last_raw_cumulative_total"))
    }
}
