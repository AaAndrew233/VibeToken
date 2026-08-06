import Foundation
import GRDB

final class VibeTokenDatabase: @unchecked Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try DatabaseMigratorFactory.make().migrate(writer)
    }

    static func openDefault(
        supportDirectory: URL = AppConfiguration.defaultApplicationSupportDirectory
    ) throws -> VibeTokenDatabase {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let databasePath = supportDirectory
            .appendingPathComponent("vibetoken.sqlite", isDirectory: false)
            .path
        let pool = try DatabasePool(path: databasePath, configuration: configuration)
        try pool.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
        }
        return try VibeTokenDatabase(writer: pool)
    }

    static func inMemory() throws -> VibeTokenDatabase {
        try VibeTokenDatabase(writer: DatabaseQueue())
    }
}
