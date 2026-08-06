import OSLog

enum PrivacyLog {
    static let ingestion = Logger(subsystem: "app.vibetoken.mac", category: "ingestion")
    static let database = Logger(subsystem: "app.vibetoken.mac", category: "database")
    static let lifecycle = Logger(subsystem: "app.vibetoken.mac", category: "lifecycle")
    static let relay = Logger(subsystem: "app.vibetoken.mac", category: "relay")
}
