import Foundation

actor ClaudeCodeUsageAdapter: UsageSourceAdapter {
    private struct FileSignature: Equatable, Sendable {
        let path: String
        let size: UInt64
        let modificationDate: Date?
    }

    private struct Candidate: Sendable {
        let url: URL
        let sessionIdentifier: String
        let fallbackProject: String?
        let size: UInt64
        let modificationDate: Date?
    }

    private struct ParsedEntry {
        let uuid: String?
        let lineOffset: UInt64
        let model: String
        let occurredAt: Date
        let inputTokens: Int64
        let cachedInputTokens: Int64
        let cacheWriteTokens: Int64
        let outputTokens: Int64
    }

    nonisolated let sourceIdentifier = "claude-code"
    nonisolated let displayName = "Claude Code"
    nonisolated let accuracy = UsageAccuracy.exact

    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let homeDirectory: URL
    private let environment: [String: String]
    private let rootsOverride: [URL]?
    private var knownSignatures: [String: FileSignature] = [:]
    private var cachedRoots: [URL]?
    private var rootsDiscoveredAt = Date.distantPast

    init(
        configuration: AppConfiguration,
        repository: UsageRepository,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rootsOverride: [URL]? = nil
    ) {
        self.configuration = configuration
        self.repository = repository
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.rootsOverride = rootsOverride
    }

    func discover() async -> Bool {
        dataDirectories().isEmpty == false
    }

    func ingestRecentSessions(now: Date) async throws {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast

        for candidate in bestProjectCandidates(modifiedSince: modifiedSince) {
            try Task.checkCancellation()
            guard candidate.size <= UInt64(configuration.maximumStructuredUsageFileBytes) else {
                continue
            }
            let signature = FileSignature(
                path: candidate.url.standardizedFileURL.path,
                size: candidate.size,
                modificationDate: candidate.modificationDate
            )
            guard knownSignatures[candidate.sessionIdentifier] != signature else { continue }
            let events = try parse(candidate)
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_jsonl",
                accuracy: accuracy
            )
            knownSignatures[candidate.sessionIdentifier] = signature
            await Task.yield()
        }
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        let files = bestProjectCandidates(modifiedSince: modifiedSince).map(\.url)
        let directories = dataDirectories().filter { $0.lastPathComponent == "projects" }
        return UsageWatchTargets(
            fileURLs: Array(files.prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: directories
        )
    }

    private func parse(_ candidate: Candidate) throws -> [LocalUsageEvent] {
        var entries: [ParsedEntry] = []
        var project = candidate.fallbackProject
        var foundSessionCwd = false
        var lastModel: String?

        _ = try JSONLStreamReader.readCompleteLines(
            at: candidate.url,
            from: 0,
            through: candidate.size,
            chunkBytes: configuration.ingestionChunkBytes,
            maximumLineBytes: configuration.maximumJSONLineBytes
        ) { data, lineOffset in
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let record = LocalUsageValue.dictionary(object) else {
                return
            }
            if !foundSessionCwd,
               let cwd = LocalUsageValue.string(record["cwd"]) {
                project = Self.lastPathComponent(cwd)
                foundSessionCwd = true
            }
            guard LocalUsageValue.string(record["type"]) == "assistant",
                  let message = LocalUsageValue.dictionary(record["message"]),
                  let usage = LocalUsageValue.dictionary(message["usage"]),
                  let occurredAt = LocalUsageValue.date(record["timestamp"]) else {
                return
            }

            let rawModel = LocalUsageValue.string(message["model"])
            if let rawModel, rawModel != "<synthetic>" {
                lastModel = rawModel
            }
            guard let model = rawModel == "<synthetic>" ? lastModel : (rawModel ?? lastModel) else {
                return
            }

            let input = LocalUsageValue.count(usage["input_tokens"])
            let cached = LocalUsageValue.count(usage["cache_read_input_tokens"])
            let cacheWrite = Self.cacheCreationTokens(usage)
            let output = LocalUsageValue.count(usage["output_tokens"])
            guard input > 0 || cached > 0 || cacheWrite > 0 || output > 0 else { return }

            entries.append(ParsedEntry(
                uuid: LocalUsageValue.string(record["uuid"]),
                lineOffset: lineOffset,
                model: model,
                occurredAt: occurredAt,
                inputTokens: input,
                cachedInputTokens: cached,
                cacheWriteTokens: cacheWrite,
                outputTokens: output
            ))
        }

        return entries.map { entry in
            let stableEventIdentity = entry.uuid
                ?? StableHash.string("\(candidate.sessionIdentifier):\(entry.lineOffset)")
            return LocalUsageEvent(
                idempotencyKey: "\(sourceIdentifier):\(stableEventIdentity)",
                sessionIdentifier: candidate.sessionIdentifier,
                model: entry.model,
                projectLabel: project,
                occurredAt: entry.occurredAt,
                counters: LocalUsageValue.counters(
                    input: entry.inputTokens,
                    cachedInput: entry.cachedInputTokens,
                    cacheWrite: entry.cacheWriteTokens,
                    output: entry.outputTokens,
                    reasoning: 0
                ),
                rawSchemaVersion: "claude-code-assistant-usage-v1"
            )
        }
    }

    private func bestProjectCandidates(modifiedSince: Date) -> [Candidate] {
        let projectDirectories = dataDirectories().filter { $0.lastPathComponent == "projects" }
        let files = LocalUsageFileDiscovery.files(
            under: projectDirectories,
            extensions: ["jsonl"],
            modifiedSince: modifiedSince,
            maximumFiles: configuration.maximumUsageSourceFiles
        )
        var groups: [String: [Candidate]] = [:]
        for fileURL in files {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ]) else {
                continue
            }
            let sessionIdentifier = fileURL.deletingPathExtension().lastPathComponent
            let candidate = Candidate(
                url: fileURL,
                sessionIdentifier: sessionIdentifier,
                fallbackProject: fallbackProject(for: fileURL, projectDirectories: projectDirectories),
                size: UInt64(max(0, values.fileSize ?? 0)),
                modificationDate: values.contentModificationDate
            )
            groups[sessionIdentifier, default: []].append(candidate)
        }

        return groups.values.compactMap { candidates in
            candidates.max { left, right in
                if left.size != right.size { return left.size < right.size }
                if left.modificationDate != right.modificationDate {
                    return (left.modificationDate ?? .distantPast) < (right.modificationDate ?? .distantPast)
                }
                return left.url.path > right.url.path
            }
        }.sorted { left, right in
            (left.modificationDate ?? .distantPast) < (right.modificationDate ?? .distantPast)
        }
    }

    private func dataDirectories() -> [URL] {
        claudeRoots().flatMap { root in
            ["projects", "transcripts"].compactMap { name in
                let directory = root.appendingPathComponent(name, isDirectory: true)
                return Self.isDirectory(directory) ? directory : nil
            }
        }
    }

    private func claudeRoots() -> [URL] {
        if let rootsOverride {
            return Self.uniqueCanonicalURLs(rootsOverride)
        }
        let now = Date()
        if let cachedRoots, now.timeIntervalSince(rootsDiscoveredAt) < 30 {
            return cachedRoots
        }

        var roots = [homeDirectory.appendingPathComponent(".claude", isDirectory: true)]
        if let configuredPath = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !configuredPath.isEmpty {
            roots.append(Self.expandedURL(configuredPath, homeDirectory: homeDirectory))
        }
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            roots.append(contentsOf: entries.filter { url in
                url.lastPathComponent.hasPrefix(".claude-")
                    && Self.containsClaudeData(url)
            })
        }

        let desktopDataDirectory = homeDirectory
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        let coworkDirectory = desktopDataDirectory
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        var inspectedEntries = 0
        roots.append(contentsOf: Self.discoverCoworkRoots(
            under: coworkDirectory,
            depth: 0,
            inspectedEntries: &inspectedEntries
        ))
        let resolvedRoots = Self.uniqueCanonicalURLs(roots)
        cachedRoots = resolvedRoots
        rootsDiscoveredAt = now
        return resolvedRoots
    }

    private func fallbackProject(for fileURL: URL, projectDirectories: [URL]) -> String? {
        for projectsDirectory in projectDirectories {
            let prefix = projectsDirectory.standardizedFileURL.path + "/"
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard let firstSegment = relative.split(separator: "/").first else { return nil }
            return firstSegment.split(separator: "-").last.map(String.init)
        }
        return nil
    }

    private static func cacheCreationTokens(_ usage: [String: Any]) -> Int64 {
        let direct = LocalUsageValue.count(usage["cache_creation_input_tokens"])
        guard let breakdown = LocalUsageValue.dictionary(usage["cache_creation"]) else {
            return direct
        }
        let split = saturatingAdd(
            LocalUsageValue.count(breakdown["ephemeral_5m_input_tokens"]),
            LocalUsageValue.count(breakdown["ephemeral_1h_input_tokens"])
        )
        return max(direct, split)
    }

    private static func discoverCoworkRoots(
        under directory: URL,
        depth: Int,
        inspectedEntries: inout Int
    ) -> [URL] {
        guard depth <= 8,
              inspectedEntries < 10_000,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
              ) else {
            return []
        }
        inspectedEntries += entries.count
        if let claudeRoot = entries.first(where: {
            $0.lastPathComponent == ".claude" && isDirectory($0)
        }) {
            return [claudeRoot]
        }
        guard depth < 8 else { return [] }
        return entries.flatMap { entry -> [URL] in
            guard isDirectory(entry), !["rpm", "skills"].contains(entry.lastPathComponent) else {
                return []
            }
            return discoverCoworkRoots(
                under: entry,
                depth: depth + 1,
                inspectedEntries: &inspectedEntries
            )
        }
    }

    private static func expandedURL(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func containsClaudeData(_ root: URL) -> Bool {
        isDirectory(root.appendingPathComponent("projects", isDirectory: true))
            || isDirectory(root.appendingPathComponent("transcripts", isDirectory: true))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func uniqueCanonicalURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
    }

    private static func lastPathComponent(_ rawPath: String) -> String? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.split(separator: "/").last.map(String.init)
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}
