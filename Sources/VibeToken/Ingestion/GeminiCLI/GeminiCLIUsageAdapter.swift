import Foundation

actor GeminiCLIUsageAdapter: UsageSourceAdapter {
    private struct FileSignature: Equatable, Sendable {
        let size: UInt64
        let modificationDate: Date?
    }

    nonisolated let sourceIdentifier = "gemini-cli"
    nonisolated let displayName = "Gemini CLI"
    nonisolated let accuracy = UsageAccuracy.exact

    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let dataRoot: URL
    private var knownSignatures: [URL: FileSignature] = [:]

    init(
        configuration: AppConfiguration,
        repository: UsageRepository,
        dataRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.configuration = configuration
        self.repository = repository
        self.dataRoot = dataRoot ?? homeDirectory
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
    }

    func discover() async -> Bool {
        Self.isDirectory(dataRoot)
    }

    func ingestRecentSessions(now: Date) async throws {
        guard await discover() else { return }
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast

        for fileURL in sessionFiles(modifiedSince: modifiedSince) {
            try Task.checkCancellation()
            guard let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ]) else {
                continue
            }
            let fileSize = UInt64(max(0, values.fileSize ?? 0))
            guard fileSize <= UInt64(configuration.maximumStructuredUsageFileBytes) else { continue }
            let signature = FileSignature(size: fileSize, modificationDate: values.contentModificationDate)
            guard knownSignatures[fileURL] != signature else { continue }
            let events = fileURL.pathExtension.lowercased() == "jsonl"
                ? try parseJSONL(fileURL, fileSize: fileSize)
                : try parseLegacyJSON(fileURL)
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: fileURL.pathExtension.lowercased() == "jsonl"
                    ? "local_jsonl"
                    : "local_json",
                accuracy: accuracy
            )
            knownSignatures[fileURL] = signature
            await Task.yield()
        }
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        let files = sessionFiles(modifiedSince: modifiedSince)
        let directories = projectDirectories().map {
            $0.appendingPathComponent("chats", isDirectory: true)
        }.filter(Self.isDirectory)
        return UsageWatchTargets(
            fileURLs: Array(files.prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: directories
        )
    }

    private func parseJSONL(_ fileURL: URL, fileSize: UInt64) throws -> [LocalUsageEvent] {
        var project: String?
        var messages: [(record: [String: Any], offset: UInt64)] = []
        _ = try JSONLStreamReader.readCompleteLines(
            at: fileURL,
            from: 0,
            through: fileSize,
            chunkBytes: configuration.ingestionChunkBytes,
            maximumLineBytes: configuration.maximumJSONLineBytes
        ) { data, offset in
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let record = LocalUsageValue.dictionary(object) else {
                return
            }
            if project == nil, let directories = record["directories"] as? [Any] {
                project = Self.projectName(from: directories)
            }
            if LocalUsageValue.string(record["type"]) != nil
                || LocalUsageValue.string(record["role"]) != nil {
                messages.append((record, offset))
            }
        }
        return makeEvents(
            messages: messages,
            project: project,
            sessionIdentifier: sessionIdentifier(for: fileURL)
        )
    }

    private func parseLegacyJSON(_ fileURL: URL) throws -> [LocalUsageEvent] {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = LocalUsageValue.dictionary(object) else {
            return []
        }
        let rawMessages = (record["messages"] as? [Any]) ?? (record["history"] as? [Any]) ?? []
        let messages = rawMessages.enumerated().compactMap { index, value in
            LocalUsageValue.dictionary(value).map { ($0, UInt64(index)) }
        }
        return makeEvents(
            messages: messages,
            project: Self.projectName(from: record["directories"] as? [Any]),
            sessionIdentifier: sessionIdentifier(for: fileURL)
        )
    }

    private func makeEvents(
        messages: [(record: [String: Any], offset: UInt64)],
        project: String?,
        sessionIdentifier: String
    ) -> [LocalUsageEvent] {
        messages.compactMap { message, offset in
            guard Self.role(of: message) == "assistant",
                  let occurredAt = LocalUsageValue.date(message["timestamp"])
                    ?? LocalUsageValue.date(message["createTime"]),
                  let counters = Self.counters(from: message) else {
                return nil
            }
            let messageIdentity = LocalUsageValue.string(message["id"])
                ?? LocalUsageValue.string(message["uuid"])
                ?? String(offset)
            return LocalUsageEvent(
                idempotencyKey: "\(sourceIdentifier):\(sessionIdentifier):\(messageIdentity)",
                sessionIdentifier: sessionIdentifier,
                model: LocalUsageValue.string(message["model"]),
                projectLabel: project,
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "gemini-cli-message-usage-v1"
            )
        }
    }

    private func sessionFiles(modifiedSince: Date) -> [URL] {
        var files: [URL] = []
        for projectDirectory in projectDirectories() {
            collectChatFiles(
                under: projectDirectory.appendingPathComponent("chats", isDirectory: true),
                depth: 0,
                modifiedSince: modifiedSince,
                output: &files
            )
            if files.count >= configuration.maximumUsageSourceFiles { break }
        }
        return files.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if leftDate == rightDate { return left.path < right.path }
            return leftDate > rightDate
        }.prefix(configuration.maximumUsageSourceFiles).map { $0 }
    }

    private func collectChatFiles(
        under directory: URL,
        depth: Int,
        modifiedSince: Date,
        output: inout [URL]
    ) {
        guard depth <= 2,
              output.count < configuration.maximumUsageSourceFiles,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .contentModificationDateKey,
                    .isSymbolicLinkKey
                ],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }
        for entry in entries {
            guard output.count < configuration.maximumUsageSourceFiles,
                  let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .contentModificationDateKey,
                    .isSymbolicLinkKey
                  ]),
                  values.isSymbolicLink != true else {
                continue
            }
            if values.isDirectory == true {
                collectChatFiles(
                    under: entry,
                    depth: depth + 1,
                    modifiedSince: modifiedSince,
                    output: &output
                )
            } else if values.isRegularFile == true,
                      ["json", "jsonl"].contains(entry.pathExtension.lowercased()),
                      (values.contentModificationDate ?? .distantPast) >= modifiedSince {
                output.append(entry)
            }
        }
    }

    private func projectDirectories() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dataRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { entry in
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private func sessionIdentifier(for fileURL: URL) -> String {
        StableHash.string(fileURL.standardizedFileURL.path)
    }

    private static func role(of message: [String: Any]) -> String? {
        switch LocalUsageValue.string(message["type"])
            ?? LocalUsageValue.string(message["role"]) {
        case "user": "user"
        case "gemini", "model", "assistant": "assistant"
        default: nil
        }
    }

    private static func counters(from message: [String: Any]) -> TokenUsageCounters? {
        if let tokens = LocalUsageValue.dictionary(message["tokens"]) {
            let cached = LocalUsageValue.count(tokens["cached"])
            let reasoning = LocalUsageValue.count(tokens["thoughts"])
            return LocalUsageValue.counters(
                input: max(0, LocalUsageValue.count(tokens["input"]) - cached),
                cachedInput: cached,
                cacheWrite: 0,
                output: max(0, LocalUsageValue.count(tokens["output"]) - reasoning),
                reasoning: reasoning
            )
        }
        guard let usage = LocalUsageValue.dictionary(message["usageMetadata"])
                ?? LocalUsageValue.dictionary(message["usage"]) else {
            return nil
        }
        let cached = LocalUsageValue.count(usage["cachedContentTokenCount"])
        let reasoning = LocalUsageValue.count(usage["thoughtsTokenCount"])
        let rawInput = LocalUsageValue.count(usage["promptTokenCount"])
        let rawOutput = LocalUsageValue.count(usage["candidatesTokenCount"])
        return LocalUsageValue.counters(
            input: max(
                0,
                (rawInput > 0 ? rawInput : LocalUsageValue.count(usage["input_tokens"])) - cached
            ),
            cachedInput: cached,
            cacheWrite: 0,
            output: max(
                0,
                (rawOutput > 0 ? rawOutput : LocalUsageValue.count(usage["output_tokens"])) - reasoning
            ),
            reasoning: reasoning
        )
    }

    private static func projectName(from directories: [Any]?) -> String? {
        guard let raw = directories?.first else { return nil }
        let value = String(describing: raw)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.split(separator: "/").last.map(String.init)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
