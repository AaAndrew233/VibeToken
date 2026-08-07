import Foundation

enum FileUsageTool: CaseIterable, Hashable, Sendable {
    case grok
    case openClaw
    case pi
    case qwenCode
    case kimiCode
    case amp
    case droid
    case traeCLI

    var sourceIdentifier: String {
        switch self {
        case .grok: "grok"
        case .openClaw: "openclaw"
        case .pi: "pi-coding-agent"
        case .qwenCode: "qwen-code"
        case .kimiCode: "kimi-code"
        case .amp: "amp"
        case .droid: "droid"
        case .traeCLI: "trae-cli"
        }
    }

    var displayName: String {
        switch self {
        case .grok: "Grok"
        case .openClaw: "OpenClaw"
        case .pi: "pi"
        case .qwenCode: "Qwen Code"
        case .kimiCode: "Kimi Code"
        case .amp: "Amp"
        case .droid: "Droid"
        case .traeCLI: "Trae CLI"
        }
    }
}

actor FileUsageAdapter: UsageSourceAdapter {
    nonisolated let sourceIdentifier: String
    nonisolated let displayName: String
    nonisolated let accuracy: UsageAccuracy

    private let tool: FileUsageTool
    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let homeDirectory: URL
    private let environment: [String: String]
    private var knownSignatures: [URL: FileUsageSignature] = [:]

    init(
        tool: FileUsageTool,
        configuration: AppConfiguration,
        repository: UsageRepository,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.tool = tool
        sourceIdentifier = tool.sourceIdentifier
        displayName = tool.displayName
        accuracy = tool == .droid ? .derived : .exact
        self.configuration = configuration
        self.repository = repository
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func discover() async -> Bool {
        !FileUsageParser.roots(
            for: tool,
            homeDirectory: homeDirectory,
            environment: environment
        ).isEmpty
    }

    func ingestRecentSessions(now: Date) async throws {
        let roots = FileUsageParser.roots(
            for: tool,
            homeDirectory: homeDirectory,
            environment: environment
        )
        guard !roots.isEmpty else { return }

        let files = FileUsageParser.primaryFiles(
            for: tool,
            roots: roots,
            configuration: configuration,
            now: now
        )
        for fileURL in files {
            try Task.checkCancellation()
            guard let signature = FileUsageSignature(fileURL: fileURL),
                  signature.totalSize <= UInt64(configuration.maximumStructuredUsageFileBytes),
                  knownSignatures[fileURL] != signature else {
                continue
            }
            let parsedEvents = try FileUsageParser.events(
                for: tool,
                fileURL: fileURL,
                roots: roots,
                configuration: configuration,
                homeDirectory: homeDirectory
            )
            let events = tool == .droid
                ? try incrementalDroidEvents(from: parsedEvents)
                : parsedEvents
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: fileURL.pathExtension.lowercased() == "jsonl"
                    ? "local_jsonl"
                    : "local_json",
                accuracy: accuracy,
                allowDecreasingTotals: true
            )
            knownSignatures[fileURL] = signature
            await Task.yield()
        }

        if files.isEmpty {
            try repository.persistLocalEvents(
                [],
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_structured",
                accuracy: accuracy
            )
        }
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets {
        let roots = FileUsageParser.roots(
            for: tool,
            homeDirectory: homeDirectory,
            environment: environment
        )
        let files = FileUsageParser.primaryFiles(
            for: tool,
            roots: roots,
            configuration: configuration,
            now: now
        )
        return UsageWatchTargets(
            fileURLs: Array(files.prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: roots
        )
    }

    private func incrementalDroidEvents(
        from cumulativeEvents: [LocalUsageEvent]
    ) throws -> [LocalUsageEvent] {
        try cumulativeEvents.compactMap { event in
            let previous = try repository.persistedCounters(
                sourceIdentifier: sourceIdentifier,
                sessionIdentifier: event.sessionIdentifier
            )
            guard event.counters.inputTokens >= previous.inputTokens,
                  event.counters.cachedInputTokens >= previous.cachedInputTokens,
                  event.counters.cacheWriteTokens >= previous.cacheWriteTokens,
                  event.counters.outputTokens >= previous.outputTokens,
                  event.counters.reasoningTokens >= previous.reasoningTokens else {
                return nil
            }
            let delta = LocalUsageValue.counters(
                input: event.counters.inputTokens - previous.inputTokens,
                cachedInput: event.counters.cachedInputTokens - previous.cachedInputTokens,
                cacheWrite: event.counters.cacheWriteTokens - previous.cacheWriteTokens,
                output: event.counters.outputTokens - previous.outputTokens,
                reasoning: event.counters.reasoningTokens - previous.reasoningTokens
            )
            guard delta.totalTokens > 0 else { return nil }
            let snapshotIdentity = StableHash.string(
                [
                    event.counters.inputTokens,
                    event.counters.cachedInputTokens,
                    event.counters.cacheWriteTokens,
                    event.counters.outputTokens,
                    event.counters.reasoningTokens
                ].map(String.init).joined(separator: ":")
            )
            return LocalUsageEvent(
                idempotencyKey: "droid:\(event.sessionIdentifier):snapshot:\(snapshotIdentity)",
                sessionIdentifier: event.sessionIdentifier,
                model: event.model,
                projectLabel: event.projectLabel,
                occurredAt: event.occurredAt,
                counters: delta,
                rawSchemaVersion: "droid-session-observed-delta-v2"
            )
        }
    }
}

struct FileUsageSignature: Equatable, Sendable {
    let totalSize: UInt64
    let modificationDate: Date?

    init?(fileURL: URL) {
        guard let values = try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true else {
            return nil
        }
        totalSize = UInt64(max(0, values.fileSize ?? 0))
        modificationDate = values.contentModificationDate
    }
}

enum FileUsageParser {
    static func roots(
        for tool: FileUsageTool,
        homeDirectory: URL,
        environment: [String: String]
    ) -> [URL] {
        let candidates: [URL]
        switch tool {
        case .grok:
            let home = absoluteDirectory(
                environment["GROK_HOME"],
                relativeTo: homeDirectory
            ) ?? homeDirectory.appendingPathComponent(".grok", isDirectory: true)
            candidates = [home.appendingPathComponent("sessions", isDirectory: true)]
        case .openClaw:
            candidates = openClawRoots(homeDirectory: homeDirectory).map {
                $0.appendingPathComponent("agents", isDirectory: true)
            }
        case .pi:
            let base = absoluteDirectory(
                environment["PI_CODING_AGENT_DIR"],
                relativeTo: homeDirectory
            ) ?? homeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
            candidates = [base.appendingPathComponent("sessions", isDirectory: true)]
        case .qwenCode:
            candidates = [homeDirectory.appendingPathComponent(".qwen/tmp", isDirectory: true)]
        case .kimiCode:
            let current = absoluteDirectory(
                environment["KIMI_CODE_HOME"],
                relativeTo: homeDirectory
            ) ?? homeDirectory.appendingPathComponent(".kimi-code", isDirectory: true)
            candidates = [
                current.appendingPathComponent("sessions", isDirectory: true),
                homeDirectory.appendingPathComponent(".kimi/sessions", isDirectory: true)
            ]
        case .amp:
            if let override = absoluteDirectory(environment["AMP_DATA_DIR"], relativeTo: homeDirectory) {
                candidates = [override]
            } else {
                let dataHome = absoluteDirectory(environment["XDG_DATA_HOME"], relativeTo: homeDirectory)
                    ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
                candidates = [dataHome.appendingPathComponent("amp/threads", isDirectory: true)]
            }
        case .droid:
            candidates = [homeDirectory.appendingPathComponent(".factory/sessions", isDirectory: true)]
        case .traeCLI:
            candidates = [homeDirectory.appendingPathComponent(
                "Library/Caches/trae-cli/sessions",
                isDirectory: true
            )]
        }
        return candidates.filter(isDirectory)
    }

    static func primaryFiles(
        for tool: FileUsageTool,
        roots: [URL],
        configuration: AppConfiguration,
        now: Date
    ) -> [URL] {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        let extensions: Set<String> = tool == .amp || tool == .droid ? ["json"] : ["jsonl"]
        return LocalUsageFileDiscovery.files(
            under: roots,
            extensions: extensions,
            modifiedSince: modifiedSince,
            maximumFiles: configuration.maximumUsageSourceFiles
        ).filter { fileURL in
            switch tool {
            case .grok: fileURL.lastPathComponent == "updates.jsonl"
            case .openClaw: fileURL.pathComponents.contains("sessions")
            case .pi: true
            case .qwenCode: fileURL.pathComponents.contains("chats")
            case .kimiCode: fileURL.lastPathComponent == "wire.jsonl"
            case .amp:
                fileURL.lastPathComponent.hasPrefix("T-")
                    && fileURL.pathExtension.lowercased() == "json"
            case .droid: fileURL.lastPathComponent.hasSuffix(".settings.json")
            case .traeCLI: fileURL.lastPathComponent == "traces.jsonl"
        }
    }

}

    static func events(
        for tool: FileUsageTool,
        fileURL: URL,
        roots: [URL],
        configuration: AppConfiguration,
        homeDirectory: URL
    ) throws -> [LocalUsageEvent] {
        switch tool {
        case .grok:
            try grokEvents(fileURL: fileURL, configuration: configuration)
        case .openClaw:
            try openClawEvents(fileURL: fileURL, configuration: configuration)
        case .pi:
            try piEvents(fileURL: fileURL, configuration: configuration)
        case .qwenCode:
            try qwenEvents(fileURL: fileURL, configuration: configuration)
        case .kimiCode:
            try kimiEvents(
                fileURL: fileURL,
                roots: roots,
                configuration: configuration,
                homeDirectory: homeDirectory
            )
        case .amp:
            try ampEvents(fileURL: fileURL)
        case .droid:
            try droidEvents(settingsURL: fileURL, configuration: configuration)
        case .traeCLI:
            try traeEvents(fileURL: fileURL, configuration: configuration)
        }
    }

    static func records(
        at fileURL: URL,
        configuration: AppConfiguration
    ) throws -> [(record: [String: Any], offset: UInt64)] {
        guard let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize >= 0,
              fileSize <= configuration.maximumStructuredUsageFileBytes else {
            return []
        }
        var result: [(record: [String: Any], offset: UInt64)] = []
        _ = try JSONLStreamReader.readCompleteLines(
            at: fileURL,
            from: 0,
            through: UInt64(fileSize),
            chunkBytes: configuration.ingestionChunkBytes,
            maximumLineBytes: configuration.maximumJSONLineBytes
        ) { data, offset in
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let record = LocalUsageValue.dictionary(object) else {
                return
            }
            result.append((record, offset))
        }
        return result
    }

    static func boundedDictionary(at fileURL: URL, maximumBytes: Int) -> [String: Any]? {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0,
              size <= maximumBytes,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return LocalUsageValue.dictionary(object)
    }

    static func projectName(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.split(separator: "/").last.map(String.init)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func openClawRoots(homeDirectory: URL) -> [URL] {
        var roots = [
            homeDirectory.appendingPathComponent(".clawdbot", isDirectory: true),
            homeDirectory.appendingPathComponent(".moltbot", isDirectory: true),
            homeDirectory.appendingPathComponent(".moldbot", isDirectory: true)
        ]
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            roots.append(contentsOf: entries.filter { entry in
                let name = entry.lastPathComponent
                guard name == ".openclaw" || name.hasPrefix(".openclaw-") else { return false }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            })
        }
        return roots
    }

    private static func absoluteDirectory(_ rawValue: String?, relativeTo home: URL) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        if rawValue == "~" { return home }
        if rawValue.hasPrefix("~/") {
            return home.appendingPathComponent(String(rawValue.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: rawValue, isDirectory: true)
    }
}
