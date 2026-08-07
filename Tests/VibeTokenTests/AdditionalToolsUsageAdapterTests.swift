import Foundation
import GRDB
import XCTest
@testable import VibeToken

final class AdditionalToolsUsageAdapterTests: XCTestCase {
    func testAllFileToolsParseExactUsageAndRemainIdempotent() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let microseconds = Int64(Date().timeIntervalSince1970 * 1_000_000)

        try write(
            #"{"info":{"cwd":"/Users/test/GrokProject"},"current_model_id":"grok-model"}"#,
            to: home.appendingPathComponent(".grok/sessions/project/session/summary.json")
        )
        try write(
            """
            {"timestamp":"\(timestamp)","params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100,"cachedReadTokens":20,"outputTokens":40,"reasoningTokens":10}}}}
            """,
            to: home.appendingPathComponent(".grok/sessions/project/session/updates.jsonl")
        )
        try write(
            """
            {"id":"open-1","type":"message","timestamp":"\(timestamp)","message":{"role":"assistant","model":"open-model","usage":{"input":10,"output":5,"cacheRead":2}}}
            """,
            to: home.appendingPathComponent(".openclaw/agents/default/sessions/open.jsonl")
        )
        try write(
            """
            {"type":"session","id":"pi-session","cwd":"/Users/test/PiProject"}
            {"id":"pi-1","type":"message","timestamp":"\(timestamp)","message":{"role":"assistant","model":"pi-model","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":3}}}
            """,
            to: home.appendingPathComponent(".pi/agent/sessions/project/pi.jsonl")
        )
        try write(
            """
            {"uuid":"qwen-1","type":"assistant","timestamp":"\(timestamp)","cwd":"/Users/test/QwenProject","model":"qwen-model","usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":20,"candidatesTokenCount":50,"thoughtsTokenCount":10}}
            """,
            to: home.appendingPathComponent(".qwen/tmp/project/chats/qwen.jsonl")
        )
        try write(
            """
            {"type":"usage.record","model":"kimi-model","time":\(Int64(Date().timeIntervalSince1970 * 1_000)),"usage":{"inputOther":10,"inputCacheCreation":3,"inputCacheRead":2,"output":5}}
            """,
            to: home.appendingPathComponent(
                ".kimi-code/sessions/wd_KimiProject_abcd/session_1/agents/main/wire.jsonl"
            )
        )
        try write(
            """
            {"id":"amp-session","created":"\(timestamp)","messages":[{"role":"user"},{"role":"assistant","usage":{"cacheReadInputTokens":2}}],"usageLedger":{"events":[{"id":"amp-1","timestamp":"\(timestamp)","model":"amp-model","toMessageId":1,"tokens":{"input":10,"output":5}}]}}
            """,
            to: home.appendingPathComponent(".local/share/amp/threads/T-amp.json")
        )
        try write(
            """
            {"type":"message","timestamp":"\(timestamp)","message":{"role":"user"}}
            """,
            to: home.appendingPathComponent(".factory/sessions/work-DroidProject/droid.jsonl")
        )
        try write(
            #"{"model":"droid-model","tokenUsage":{"inputTokens":100,"cacheReadTokens":20,"outputTokens":40,"thinkingTokens":10}}"#,
            to: home.appendingPathComponent(".factory/sessions/work-DroidProject/droid.settings.json")
        )
        try write(
            #"{"metadata":{"cwd":"/Users/test/TraeProject","model_name":"trae-model"}}"#,
            to: home.appendingPathComponent("Library/Caches/trae-cli/sessions/trae/session.json")
        )
        try write(
            """
            {"traceID":"trace-1","startTime":\(microseconds),"tags":[{"key":"model.name","value":"trae-model"},{"key":"usage.input_tokens","value":10},{"key":"usage.output_tokens","value":5},{"key":"usage.cache_read_tokens","value":2},{"key":"usage.reasoning_tokens","value":1}]}
            """,
            to: home.appendingPathComponent("Library/Caches/trae-cli/sessions/trae/traces.jsonl")
        )

        let expectedTotals: [FileUsageTool: Int64] = [
            .grok: 140,
            .openClaw: 17,
            .pi: 20,
            .qwenCode: 150,
            .kimiCode: 20,
            .amp: 17,
            .droid: 140,
            .traeCLI: 18
        ]
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let configuration = makeTestConfiguration(dataRoot: home)

        for tool in FileUsageTool.allCases {
            for _ in 0..<2 {
                let adapter = FileUsageAdapter(
                    tool: tool,
                    configuration: configuration,
                    repository: repository,
                    homeDirectory: home,
                    environment: [:]
                )
                let isDiscovered = await adapter.discover()
                XCTAssertTrue(isDiscovered, "\(tool) should be discovered")
                try await adapter.ingestRecentSessions(now: Date())
            }
            let aggregate = try aggregate(repository, source: tool.sourceIdentifier)
            XCTAssertEqual(aggregate.snapshot?.totalTokens, expectedTotals[tool], "\(tool)")
            XCTAssertEqual(
                aggregate.snapshot?.accuracy,
                tool == .droid ? .derived : .exact,
                "\(tool)"
            )
        }
    }

    func testDroidAttributesOnlyObservedGrowthToTheLaterRefresh() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionDirectory = home.appendingPathComponent(
            ".factory/sessions/work-DroidProject",
            isDirectory: true
        )
        let settingsURL = sessionDirectory.appendingPathComponent("droid.settings.json")
        let firstObservedAt = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let secondObservedAt = Date()
        try write(
            #"{"model":"droid-model","tokenUsage":{"inputTokens":100,"outputTokens":40}}"#,
            to: settingsURL
        )
        try FileManager.default.setAttributes(
            [.modificationDate: firstObservedAt],
            ofItemAtPath: settingsURL.path
        )

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = FileUsageAdapter(
            tool: .droid,
            configuration: makeTestConfiguration(dataRoot: home),
            repository: repository,
            homeDirectory: home,
            environment: [:]
        )
        try await adapter.ingestRecentSessions(now: firstObservedAt)

        try write(
            #"{"model":"droid-model","tokenUsage":{"inputTokens":130,"outputTokens":50}}"#,
            to: settingsURL
        )
        try FileManager.default.setAttributes(
            [.modificationDate: secondObservedAt],
            ofItemAtPath: settingsURL.path
        )
        try await adapter.ingestRecentSessions(now: secondObservedAt)

        let allUsage = try repository.aggregate(
            source: FileUsageTool.droid.sourceIdentifier,
            from: firstObservedAt.addingTimeInterval(-60),
            through: secondObservedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(allUsage.snapshot?.totalTokens, 180)
        XCTAssertEqual(allUsage.snapshot?.accuracy, .derived)

        let recentUsage = try repository.aggregate(
            source: FileUsageTool.droid.sourceIdentifier,
            from: secondObservedAt.addingTimeInterval(-60),
            through: secondObservedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(recentUsage.snapshot?.totalTokens, 40)

        try await adapter.ingestRecentSessions(now: secondObservedAt)
        let idempotentUsage = try repository.aggregate(
            source: FileUsageTool.droid.sourceIdentifier,
            from: firstObservedAt.addingTimeInterval(-60),
            through: secondObservedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(idempotentUsage.snapshot?.totalTokens, 180)

        let rollbackObservedAt = secondObservedAt.addingTimeInterval(30)
        try write(
            #"{"model":"droid-model","tokenUsage":{"inputTokens":10,"outputTokens":5}}"#,
            to: settingsURL
        )
        try FileManager.default.setAttributes(
            [.modificationDate: rollbackObservedAt],
            ofItemAtPath: settingsURL.path
        )
        try await adapter.ingestRecentSessions(now: rollbackObservedAt)
        let rollbackIgnoredUsage = try repository.aggregate(
            source: FileUsageTool.droid.sourceIdentifier,
            from: firstObservedAt.addingTimeInterval(-60),
            through: rollbackObservedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(rollbackIgnoredUsage.snapshot?.totalTokens, 180)
    }

    func testAllSQLiteToolsParseExactUsageAndDimAgentDropsForkReplay() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let seconds = Date().timeIntervalSince1970

        let dimURL = home.appendingPathComponent(".dimcode/v2/dimcode.sqlite")
        try FileManager.default.createDirectory(
            at: dimURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dimQueue = try DatabaseQueue(path: dimURL.path)
        try await dimQueue.write { database in
            try database.execute(sql: "CREATE TABLE sessions (sessionId TEXT, cwd TEXT)")
            try database.execute(sql: """
                CREATE TABLE usage_ledger (
                    ledgerId TEXT, runId TEXT, providerId TEXT, modelId TEXT,
                    sessionId TEXT, usage TEXT, cost REAL, createdAt TEXT
                )
                """)
            try database.execute(
                sql: "INSERT INTO sessions VALUES (?, ?)",
                arguments: ["dim-session", "/Users/test/DimProject"]
            )
            let usage = #"{"promptTokens":100,"cacheReadTokens":20,"completionTokens":40}"#
            for ledgerID in ["original-entry", "ledger_12345678-1234-1234-1234-123456789abc"] {
                try database.execute(
                    sql: "INSERT INTO usage_ledger VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    arguments: [
                        ledgerID, "run-1", "provider", "dim-model",
                        "dim-session", usage, 0, timestamp
                    ]
                )
            }
        }

        let mimoURL = home.appendingPathComponent(".local/share/mimocode/mimocode.db")
        try FileManager.default.createDirectory(
            at: mimoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let mimoQueue = try DatabaseQueue(path: mimoURL.path)
        try await mimoQueue.write { database in
            try database.execute(sql: "CREATE TABLE session (id TEXT, directory TEXT)")
            try database.execute(sql: "CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
            try database.execute(sql: "INSERT INTO session VALUES ('mimo-session', '/Users/test/MiMoProject')")
            try database.execute(
                sql: "INSERT INTO message VALUES (?, ?, ?, ?)",
                arguments: [
                    "mimo-message", "mimo-session", milliseconds,
                    """
                    {"role":"assistant","modelID":"mimo-model","time":{"created":\(milliseconds)},"tokens":{"input":10,"output":5,"reasoning":1,"cache":{"read":2,"write":3}}}
                    """
                ]
            )
        }

        let hermesURL = home.appendingPathComponent(".hermes/state.db")
        try FileManager.default.createDirectory(
            at: hermesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let hermesQueue = try DatabaseQueue(path: hermesURL.path)
        try await hermesQueue.write { database in
            try database.execute(sql: """
                CREATE TABLE sessions (
                    id TEXT, model TEXT, started_at REAL, input_tokens INTEGER,
                    output_tokens INTEGER, cache_read_tokens INTEGER, reasoning_tokens INTEGER
                )
                """)
            try database.execute(
                sql: "INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: ["hermes-session", "hermes-model", seconds, 10, 5, 2, 1]
            )
        }

        let zCodeURL = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        try FileManager.default.createDirectory(
            at: zCodeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let zCodeQueue = try DatabaseQueue(path: zCodeURL.path)
        try await zCodeQueue.write { database in
            try database.execute(sql: "CREATE TABLE session (id TEXT, directory TEXT)")
            try database.execute(sql: "CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
            try database.execute(sql: "INSERT INTO session VALUES ('z-session', '/Users/test/ZProject')")
            try database.execute(
                sql: "INSERT INTO message VALUES (?, ?, ?, ?)",
                arguments: [
                    "z-message", "z-session", milliseconds,
                    #"{"role":"assistant","modelID":"z-model","tokens":{"input":100,"output":40,"reasoning":10,"cache":{"read":20}},"path":{"root":"/Users/test/ZProject"}}"#
                ]
            )
        }

        let expectedTotals: [SQLiteUsageTool: Int64] = [
            .dimAgent: 140,
            .mimoCode: 21,
            .hermes: 18,
            .zCode: 140
        ]
        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let configuration = makeTestConfiguration(dataRoot: home)
        for tool in SQLiteUsageTool.allCases {
            let adapter = SQLiteUsageAdapter(
                tool: tool,
                configuration: configuration,
                repository: repository,
                homeDirectory: home,
                environment: [:]
            )
            let isDiscovered = await adapter.discover()
            XCTAssertTrue(isDiscovered, "\(tool) should be discovered")
            try await adapter.ingestRecentSessions(now: Date())
            let aggregate = try aggregate(repository, source: tool.sourceIdentifier)
            XCTAssertEqual(aggregate.snapshot?.totalTokens, expectedTotals[tool], "\(tool)")
            XCTAssertEqual(aggregate.snapshot?.accuracy, .exact, "\(tool)")
        }
    }

    func testAntigravityParsesOfflineProtobufDatabase() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let databaseURL = home.appendingPathComponent(
            ".gemini/antigravity/conversations/cascade.db"
        )
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourceQueue = try DatabaseQueue(path: databaseURL.path)
        let now = Date()
        try await sourceQueue.write { database in
            try database.execute(sql: "CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            try database.execute(sql: "CREATE TABLE trajectory_metadata_blob (data BLOB)")
            try database.execute(
                sql: "INSERT INTO gen_metadata VALUES (?, ?)",
                arguments: [0, Self.antigravityGeneratorMetadata(now: now)]
            )
            try database.execute(
                sql: "INSERT INTO trajectory_metadata_blob VALUES (?)",
                arguments: [Self.protobufBytes(field: 1, value: Self.protobufString(
                    field: 1,
                    value: "file:///Users/test/GravityProject"
                ))]
            )
        }

        let database = try VibeTokenDatabase.inMemory()
        let repository = UsageRepository(database: database)
        let adapter = AntigravityUsageAdapter(
            configuration: makeTestConfiguration(dataRoot: home),
            repository: repository,
            homeDirectory: home
        )
        let isDiscovered = await adapter.discover()
        XCTAssertTrue(isDiscovered)
        try await adapter.ingestRecentSessions(now: now)

        let aggregate = try aggregate(repository, source: "antigravity")
        XCTAssertEqual(aggregate.snapshot?.totalTokens, 18)
        XCTAssertEqual(aggregate.snapshot?.model, "gravity-model")
        XCTAssertEqual(aggregate.snapshot?.accuracy, .exact)
    }

    private func aggregate(
        _ repository: UsageRepository,
        source: String
    ) throws -> UsageAggregation {
        try repository.aggregate(
            source: source,
            from: Date().addingTimeInterval(-60),
            through: Date().addingTimeInterval(60)
        )
    }

    private func makeTemporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (text + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func antigravityGeneratorMetadata(now: Date) -> Data {
        let usage = protobufVarint(field: 2, value: 10)
            + protobufVarint(field: 3, value: 5)
            + protobufVarint(field: 5, value: 2)
            + protobufVarint(field: 9, value: 1)
            + protobufString(field: 11, value: "gravity-response")
        let timestamp = protobufVarint(field: 1, value: UInt64(now.timeIntervalSince1970))
        let startMetadata = protobufBytes(field: 4, value: timestamp)
        let chatModel = protobufBytes(field: 4, value: usage)
            + protobufBytes(field: 9, value: startMetadata)
            + protobufString(field: 21, value: "gravity-model")
        return protobufBytes(field: 1, value: chatModel)
    }

    private static func protobufString(field: Int, value: String) -> Data {
        protobufBytes(field: field, value: Data(value.utf8))
    }

    private static func protobufBytes(field: Int, value: Data) -> Data {
        protobufVarintValue(UInt64(field << 3 | 2))
            + protobufVarintValue(UInt64(value.count))
            + value
    }

    private static func protobufVarint(field: Int, value: UInt64) -> Data {
        protobufVarintValue(UInt64(field << 3)) + protobufVarintValue(value)
    }

    private static func protobufVarintValue(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }
}
