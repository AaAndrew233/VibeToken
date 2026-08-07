import Foundation

actor GitHubCopilotCLIUsageAdapter: UsageSourceAdapter {
    private struct FileSignature: Equatable, Sendable {
        let size: UInt64
        let modificationDate: Date?
    }

    nonisolated let sourceIdentifier = "copilot-cli"
    nonisolated let displayName = "GitHub Copilot CLI"
    nonisolated let accuracy = UsageAccuracy.exact

    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let sessionStateRoot: URL
    private var knownSignatures: [URL: FileSignature] = [:]

    init(
        configuration: AppConfiguration,
        repository: UsageRepository,
        sessionStateRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.configuration = configuration
        self.repository = repository
        self.sessionStateRoot = sessionStateRoot ?? homeDirectory
            .appendingPathComponent(".copilot/session-state", isDirectory: true)
    }

    func discover() async -> Bool {
        Self.isDirectory(sessionStateRoot)
    }

    func ingestRecentSessions(now: Date) async throws {
        guard await discover() else { return }
        for fileURL in eventFiles(now: now) {
            try Task.checkCancellation()
            guard let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ]) else {
                continue
            }
            let signature = FileSignature(
                size: UInt64(max(0, values.fileSize ?? 0)),
                modificationDate: values.contentModificationDate
            )
            guard signature.size <= UInt64(configuration.maximumStructuredUsageFileBytes),
                  knownSignatures[fileURL] != signature else {
                continue
            }

            let sessionIdentifier = fileURL.deletingLastPathComponent().lastPathComponent
            let events = try parse(
                fileURL,
                fileSize: signature.size,
                sessionIdentifier: sessionIdentifier
            )
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_jsonl",
                accuracy: accuracy
            )
            knownSignatures[fileURL] = signature
            await Task.yield()
        }
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets {
        UsageWatchTargets(
            fileURLs: Array(eventFiles(now: now).prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: Self.isDirectory(sessionStateRoot) ? [sessionStateRoot] : []
        )
    }

    private func parse(
        _ fileURL: URL,
        fileSize: UInt64,
        sessionIdentifier: String
    ) throws -> [LocalUsageEvent] {
        var project: String?
        var events: [LocalUsageEvent] = []
        _ = try JSONLStreamReader.readCompleteLines(
            at: fileURL,
            from: 0,
            through: fileSize,
            chunkBytes: configuration.ingestionChunkBytes,
            maximumLineBytes: configuration.maximumJSONLineBytes
        ) { data, offset in
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let record = LocalUsageValue.dictionary(object),
                  let type = LocalUsageValue.string(record["type"]) else {
                return
            }

            if type == "session.start" || type == "session.resume" {
                let context = LocalUsageValue.dictionary(
                    LocalUsageValue.dictionary(record["data"])?["context"]
                )
                project = Self.projectLabel(
                    LocalUsageValue.string(context?["gitRoot"])
                        ?? LocalUsageValue.string(context?["cwd"])
                ) ?? project
                return
            }

            guard type == "session.shutdown",
                  let occurredAt = LocalUsageValue.date(record["timestamp"]),
                  let metrics = LocalUsageValue.dictionary(
                    LocalUsageValue.dictionary(record["data"])?["modelMetrics"]
                  ) else {
                return
            }

            for (model, rawMetrics) in metrics {
                guard let usage = LocalUsageValue.dictionary(
                    LocalUsageValue.dictionary(rawMetrics)?["usage"]
                ) else {
                    continue
                }
                let totalInput = LocalUsageValue.count(usage["inputTokens"])
                let cacheRead = LocalUsageValue.count(usage["cacheReadTokens"])
                let cacheWrite = LocalUsageValue.count(usage["cacheWriteTokens"])
                let output = LocalUsageValue.count(usage["outputTokens"])
                let reasoning = LocalUsageValue.count(usage["reasoningTokens"])
                let input = max(0, totalInput - cacheRead - cacheWrite)
                let counters = LocalUsageValue.counters(
                    input: input,
                    cachedInput: cacheRead,
                    cacheWrite: cacheWrite,
                    output: output,
                    reasoning: reasoning
                )
                guard counters.totalTokens > 0 else { continue }
                events.append(LocalUsageEvent(
                    idempotencyKey: "copilot-cli:\(sessionIdentifier):\(offset):\(model)",
                    sessionIdentifier: sessionIdentifier,
                    model: model,
                    projectLabel: project,
                    occurredAt: occurredAt,
                    counters: counters,
                    rawSchemaVersion: "copilot-cli-session-shutdown-v1"
                ))
            }
        }
        return events
    }

    private func eventFiles(now: Date) -> [URL] {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        return LocalUsageFileDiscovery.files(
            under: [sessionStateRoot],
            extensions: ["jsonl"],
            modifiedSince: modifiedSince,
            maximumFiles: configuration.maximumUsageSourceFiles
        ).filter { $0.lastPathComponent == "events.jsonl" }
    }

    private static func projectLabel(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.split(separator: "/").last.map(String.init)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
