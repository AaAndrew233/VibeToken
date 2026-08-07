import Foundation

actor KiroUsageAdapter: UsageSourceAdapter {
    private struct FileSignature: Equatable, Sendable {
        let size: UInt64
        let modificationDate: Date?
    }

    private struct SessionMetadata: Sendable {
        let projectLabel: String?
        let model: String?
    }

    nonisolated let sourceIdentifier = "kiro"
    nonisolated let displayName = "Kiro"
    nonisolated let accuracy = UsageAccuracy.estimated

    private static let charactersPerToken = 4
    private static let defaultImageTokens: Int64 = 1_600
    private static let excludedTextKeys: Set<String> = [
        "signature",
        "redactedContent",
        "toolUseId",
        "modelId",
        "message_id",
        "format",
        "id"
    ]

    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let sessionsRoot: URL
    private var knownSignatures: [URL: FileSignature] = [:]

    init(
        configuration: AppConfiguration,
        repository: UsageRepository,
        sessionsRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.configuration = configuration
        self.repository = repository
        self.sessionsRoot = sessionsRoot ?? homeDirectory
            .appendingPathComponent(".kiro/sessions/cli", isDirectory: true)
    }

    func discover() async -> Bool {
        Self.isDirectory(sessionsRoot)
    }

    func ingestRecentSessions(now: Date) async throws {
        guard await discover() else { return }
        for fileURL in sessionFiles(now: now) {
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
            let events = try parse(fileURL, signature: signature)
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_jsonl_estimate",
                accuracy: accuracy
            )
            knownSignatures[fileURL] = signature
            await Task.yield()
        }
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets {
        UsageWatchTargets(
            fileURLs: Array(sessionFiles(now: now).prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: Self.isDirectory(sessionsRoot) ? [sessionsRoot] : []
        )
    }

    private func parse(_ fileURL: URL, signature: FileSignature) throws -> [LocalUsageEvent] {
        let sessionIdentifier = fileURL.deletingPathExtension().lastPathComponent
        let metadata = sessionMetadata(sessionIdentifier: sessionIdentifier)
        let fallbackTimestamp = signature.modificationDate ?? Date()
        var currentTimestamp: Date?
        var currentModel = metadata.model
        var pendingInput: Int64 = 0
        var cumulativeContext: Int64 = 0
        var assistantIndex = 0
        var events: [LocalUsageEvent] = []

        _ = try JSONLStreamReader.readCompleteLines(
            at: fileURL,
            from: 0,
            through: signature.size,
            chunkBytes: configuration.ingestionChunkBytes,
            maximumLineBytes: configuration.maximumJSONLineBytes
        ) { data, _ in
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let event = LocalUsageValue.dictionary(object),
                  let kind = LocalUsageValue.string(event["kind"]),
                  let eventData = LocalUsageValue.dictionary(event["data"]) else {
                return
            }
            let content = eventData["content"] as? [Any] ?? []

            switch kind {
            case "Prompt":
                if let timestamp = LocalUsageValue.date(
                    LocalUsageValue.dictionary(eventData["meta"])?["timestamp"]
                ) {
                    currentTimestamp = timestamp
                }
                for rawItem in content {
                    guard let item = LocalUsageValue.dictionary(rawItem) else { continue }
                    let tokens = LocalUsageValue.string(item["kind"]) == "image"
                        ? Self.defaultImageTokens
                        : Self.estimatedTokens(item["data"])
                    pendingInput = Self.saturatingAdd(pendingInput, tokens)
                }

            case "ToolResults":
                for rawItem in content {
                    let value = LocalUsageValue.dictionary(rawItem)?["data"]
                    pendingInput = Self.saturatingAdd(
                        pendingInput,
                        Self.estimatedTokens(value)
                    )
                }

            case "AssistantMessage":
                var output: Int64 = 0
                var reasoning: Int64 = 0
                for rawItem in content {
                    guard let item = LocalUsageValue.dictionary(rawItem) else { continue }
                    let itemData = item["data"]
                    if let dictionary = LocalUsageValue.dictionary(itemData),
                       let model = LocalUsageValue.string(dictionary["modelId"]) {
                        currentModel = Self.normalizedModel(model)
                    }
                    if LocalUsageValue.string(item["kind"]) == "thinking",
                       let dictionary = LocalUsageValue.dictionary(itemData) {
                        reasoning = Self.saturatingAdd(
                            reasoning,
                            Self.tokenCount(forCharacterCount: LocalUsageValue.string(
                                dictionary["text"]
                            )?.count ?? 0)
                        )
                    } else {
                        output = Self.saturatingAdd(output, Self.estimatedTokens(itemData))
                    }
                }

                let counters = LocalUsageValue.counters(
                    input: pendingInput,
                    cachedInput: cumulativeContext,
                    cacheWrite: 0,
                    output: output,
                    reasoning: reasoning
                )
                if counters.inputTokens > 0
                    || counters.outputTokens > 0
                    || counters.reasoningTokens > 0 {
                    events.append(LocalUsageEvent(
                        idempotencyKey: "kiro:\(sessionIdentifier):\(assistantIndex)",
                        sessionIdentifier: sessionIdentifier,
                        model: Self.normalizedModel(currentModel),
                        projectLabel: metadata.projectLabel,
                        occurredAt: currentTimestamp ?? fallbackTimestamp,
                        counters: counters,
                        rawSchemaVersion: "kiro-cli-text-estimate-v1"
                    ))
                    assistantIndex += 1
                }
                cumulativeContext = [
                    cumulativeContext,
                    pendingInput,
                    output,
                    reasoning
                ].reduce(0, Self.saturatingAdd)
                pendingInput = 0

            case "Compaction":
                cumulativeContext = Self.estimatedTokens(eventData["summary"])
                pendingInput = 0

            default:
                break
            }
        }
        return events
    }

    private func sessionMetadata(sessionIdentifier: String) -> SessionMetadata {
        let metadataURL = sessionsRoot.appendingPathComponent(
            "\(sessionIdentifier).json",
            isDirectory: false
        )
        guard let size = try? metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0,
              size <= configuration.maximumStructuredUsageFileBytes,
              let data = try? Data(contentsOf: metadataURL, options: [.mappedIfSafe]),
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = LocalUsageValue.dictionary(object) else {
            return SessionMetadata(projectLabel: nil, model: nil)
        }
        let sessionState = LocalUsageValue.dictionary(record["session_state"])
        let modelState = LocalUsageValue.dictionary(sessionState?["rts_model_state"])
        let modelInfo = LocalUsageValue.dictionary(modelState?["model_info"])
        return SessionMetadata(
            projectLabel: Self.projectLabel(LocalUsageValue.string(record["cwd"])),
            model: Self.normalizedModel(LocalUsageValue.string(modelInfo?["model_id"]))
        )
    }

    private func sessionFiles(now: Date) -> [URL] {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        return LocalUsageFileDiscovery.files(
            under: [sessionsRoot],
            extensions: ["jsonl"],
            modifiedSince: modifiedSince,
            maximumFiles: configuration.maximumUsageSourceFiles
        )
    }

    private static func estimatedTokens(_ value: Any?) -> Int64 {
        tokenCount(forCharacterCount: textCharacterCount(value))
    }

    private static func textCharacterCount(_ value: Any?) -> Int {
        if let text = value as? String { return text.count }
        if let values = value as? [Any] {
            return values.reduce(0) { partial, value in
                let (result, overflow) = partial.addingReportingOverflow(textCharacterCount(value))
                return overflow ? Int.max : result
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(0) { partial, element in
                guard !excludedTextKeys.contains(element.key) else { return partial }
                let (result, overflow) = partial.addingReportingOverflow(
                    textCharacterCount(element.value)
                )
                return overflow ? Int.max : result
            }
        }
        return 0
    }

    private static func tokenCount(forCharacterCount count: Int) -> Int64 {
        guard count > 0 else { return 0 }
        return Int64(clamping: count / charactersPerToken)
    }

    private static func normalizedModel(_ rawModel: String?) -> String {
        guard var model = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            return "kiro-token-estimate"
        }
        model = model.replacingOccurrences(
            of: "_[0-9]{8}_V[0-9]+_[0-9]+$",
            with: "",
            options: .regularExpression
        )
        model = model.replacingOccurrences(
            of: "_V[0-9]+$",
            with: "",
            options: .regularExpression
        )
        return model.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func projectLabel(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.split(separator: "/").last.map(String.init)
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
