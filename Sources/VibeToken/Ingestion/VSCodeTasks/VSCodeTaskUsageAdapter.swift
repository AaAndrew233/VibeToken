import Foundation

actor VSCodeTaskUsageAdapter: UsageSourceAdapter {
    enum Tool: Sendable {
        case cline
        case rooCode

        var sourceIdentifier: String {
            switch self {
            case .cline: "cline"
            case .rooCode: "roo-code"
            }
        }

        var displayName: String {
            switch self {
            case .cline: "Cline"
            case .rooCode: "Roo Code"
            }
        }

        var extensionIdentifier: String {
            switch self {
            case .cline: "saoudrizwan.claude-dev"
            case .rooCode: "rooveterinaryinc.roo-cline"
            }
        }
    }

    private struct FileSignature: Equatable, Sendable {
        let size: UInt64
        let modificationDate: Date?
    }

    private struct TaskCandidate: Sendable {
        let taskIdentifier: String
        let deduplicationIdentifier: String
        let messagesURL: URL
        let fallbackModel: String
        let projectLabel: String?
        let signature: FileSignature
    }

    nonisolated let sourceIdentifier: String
    nonisolated let displayName: String
    nonisolated let accuracy = UsageAccuracy.exact

    private let tool: Tool
    private let configuration: AppConfiguration
    private let repository: UsageRepository
    private let rootsOverride: [URL]?
    private let homeDirectory: URL
    private var knownSignatures: [URL: FileSignature] = [:]

    init(
        tool: Tool,
        configuration: AppConfiguration,
        repository: UsageRepository,
        rootsOverride: [URL]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.tool = tool
        sourceIdentifier = tool.sourceIdentifier
        displayName = tool.displayName
        self.configuration = configuration
        self.repository = repository
        self.rootsOverride = rootsOverride
        self.homeDirectory = homeDirectory
    }

    func discover() async -> Bool {
        !dataRoots().isEmpty
    }

    func ingestRecentSessions(now: Date) async throws {
        guard await discover() else { return }
        for candidate in taskCandidates(now: now) {
            try Task.checkCancellation()
            guard candidate.signature.size <= UInt64(configuration.maximumStructuredUsageFileBytes),
                  knownSignatures[candidate.messagesURL] != candidate.signature else {
                continue
            }
            let events = try parse(candidate)
            try repository.persistLocalEvents(
                events,
                sourceIdentifier: sourceIdentifier,
                sourceDisplayName: displayName,
                sourceKind: "local_json",
                accuracy: accuracy
            )
            knownSignatures[candidate.messagesURL] = candidate.signature
            await Task.yield()
        }
    }

    func watchTargets(now: Date) async throws -> UsageWatchTargets {
        let candidates = taskCandidates(now: now)
        return UsageWatchTargets(
            fileURLs: Array(candidates.map(\.messagesURL).prefix(configuration.maximumWatchedSessionFiles)),
            directoryURLs: dataRoots()
        )
    }

    private func parse(_ candidate: TaskCandidate) throws -> [LocalUsageEvent] {
        let data = try Data(contentsOf: candidate.messagesURL, options: [.mappedIfSafe])
        guard let rawMessages = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }

        return rawMessages.enumerated().compactMap { index, rawMessage in
            guard let message = LocalUsageValue.dictionary(rawMessage),
                  LocalUsageValue.string(message["type"]) == "say",
                  LocalUsageValue.string(message["say"]) == "api_req_started",
                  let occurredAt = LocalUsageValue.date(message["ts"]),
                  let info = Self.requestInfo(from: message["text"]) else {
                return nil
            }
            let input = LocalUsageValue.count(info["tokensIn"])
            let output = LocalUsageValue.count(info["tokensOut"])
            let cacheWrite = LocalUsageValue.count(info["cacheWrites"])
            let cacheRead = LocalUsageValue.count(info["cacheReads"])
            let reasoning = LocalUsageValue.count(info["reasoningTokens"])
            let counters = LocalUsageValue.counters(
                input: input,
                cachedInput: cacheRead,
                cacheWrite: cacheWrite,
                output: output,
                reasoning: reasoning
            )
            guard counters.totalTokens > 0 else { return nil }
            return LocalUsageEvent(
                idempotencyKey: "\(sourceIdentifier):\(candidate.deduplicationIdentifier):\(index)",
                sessionIdentifier: candidate.taskIdentifier,
                model: LocalUsageValue.string(info["model"]) ?? candidate.fallbackModel,
                projectLabel: candidate.projectLabel,
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "vscode-task-api-request-v1"
            )
        }
    }

    private func taskCandidates(now: Date) -> [TaskCandidate] {
        let modifiedSince = Calendar.current.date(
            byAdding: .day,
            value: -configuration.historyLookbackDays,
            to: now
        ) ?? .distantPast
        var candidates: [TaskCandidate] = []
        for root in dataRoots() {
            switch tool {
            case .cline:
                candidates.append(contentsOf: clineCandidates(root: root, modifiedSince: modifiedSince))
            case .rooCode:
                candidates.append(contentsOf: rooCandidates(root: root, modifiedSince: modifiedSince))
            }
        }

        let selected = Dictionary(grouping: candidates, by: \.deduplicationIdentifier)
            .compactMap { _, copies in
                copies.max { left, right in
                    if left.signature.size == right.signature.size {
                        return (left.signature.modificationDate ?? .distantPast)
                            < (right.signature.modificationDate ?? .distantPast)
                    }
                    return left.signature.size < right.signature.size
                }
            }
        return selected.sorted {
            ($0.signature.modificationDate ?? .distantPast)
                > ($1.signature.modificationDate ?? .distantPast)
        }.prefix(configuration.maximumUsageSourceFiles).map { $0 }
    }

    private func clineCandidates(root: URL, modifiedSince: Date) -> [TaskCandidate] {
        guard let history = Self.jsonArray(
            at: root.appendingPathComponent("state/taskHistory.json", isDirectory: false),
            maximumBytes: configuration.maximumStructuredUsageFileBytes
        ) else {
            return []
        }
        return history.compactMap { rawItem in
            guard let item = LocalUsageValue.dictionary(rawItem),
                  let taskIdentifier = LocalUsageValue.string(item["id"]) else {
                return nil
            }
            let messagesURL = root.appendingPathComponent(
                "tasks/\(taskIdentifier)/ui_messages.json",
                isDirectory: false
            )
            guard let signature = fileSignature(messagesURL),
                  (signature.modificationDate ?? .distantPast) >= modifiedSince else {
                return nil
            }
            let projectPath = LocalUsageValue.string(item["cwdOnTaskInitialization"])
                ?? LocalUsageValue.string(item["shadowGitConfigWorkTree"])
                ?? LocalUsageValue.string(item["cwd"])
            return TaskCandidate(
                taskIdentifier: taskIdentifier,
                deduplicationIdentifier: LocalUsageValue.string(item["ulid"]) ?? taskIdentifier,
                messagesURL: messagesURL,
                fallbackModel: LocalUsageValue.string(item["modelId"]) ?? "cline-unknown",
                projectLabel: Self.projectLabel(projectPath),
                signature: signature
            )
        }
    }

    private func rooCandidates(root: URL, modifiedSince: Date) -> [TaskCandidate] {
        let tasksRoot = root.appendingPathComponent("tasks", isDirectory: true)
        let indexURL = tasksRoot.appendingPathComponent("_index.json", isDirectory: false)
        let indexedItems = Self.jsonDictionary(
            at: indexURL,
            maximumBytes: configuration.maximumStructuredUsageFileBytes
        )?["entries"] as? [Any]
        let items: [Any]
        if let indexedItems {
            items = indexedItems
        } else {
            items = (try? FileManager.default.contentsOfDirectory(
                at: tasksRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ))?.compactMap { taskDirectory -> Any? in
                guard let values = try? taskDirectory.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]),
                values.isDirectory == true,
                values.isSymbolicLink != true,
                !taskDirectory.lastPathComponent.hasPrefix("_") else {
                    return nil
                }
                return Self.jsonDictionary(
                    at: taskDirectory.appendingPathComponent("history_item.json", isDirectory: false),
                    maximumBytes: configuration.maximumStructuredUsageFileBytes
                )
            } ?? []
        }

        return items.compactMap { rawItem in
            guard let item = LocalUsageValue.dictionary(rawItem),
                  let taskIdentifier = LocalUsageValue.string(item["id"]) else {
                return nil
            }
            let messagesURL = tasksRoot.appendingPathComponent(
                "\(taskIdentifier)/ui_messages.json",
                isDirectory: false
            )
            guard let signature = fileSignature(messagesURL),
                  (signature.modificationDate ?? .distantPast) >= modifiedSince else {
                return nil
            }
            return TaskCandidate(
                taskIdentifier: taskIdentifier,
                deduplicationIdentifier: taskIdentifier,
                messagesURL: messagesURL,
                fallbackModel: LocalUsageValue.string(item["apiConfigName"]) ?? "roo-unknown",
                projectLabel: Self.projectLabel(LocalUsageValue.string(item["workspace"])),
                signature: signature
            )
        }
    }

    private func dataRoots() -> [URL] {
        if let rootsOverride {
            return rootsOverride.filter(Self.isDirectory)
        }
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let hosts = ["Code", "Cursor", "Windsurf", "VSCodium", "Code - Insiders", "Trae", "Trae CN"]
        var candidates = hosts.map {
            applicationSupport.appendingPathComponent(
                "\($0)/User/globalStorage/\(tool.extensionIdentifier)",
                isDirectory: true
            )
        }
        if tool == .cline {
            candidates.insert(
                homeDirectory.appendingPathComponent(".cline", isDirectory: true),
                at: 0
            )
        }
        return candidates.filter(Self.isDirectory)
    }

    private func fileSignature(_ url: URL) -> FileSignature? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true else {
            return nil
        }
        return FileSignature(
            size: UInt64(max(0, values.fileSize ?? 0)),
            modificationDate: values.contentModificationDate
        )
    }

    private static func requestInfo(from rawValue: Any?) -> [String: Any]? {
        if let dictionary = LocalUsageValue.dictionary(rawValue) { return dictionary }
        guard let text = LocalUsageValue.string(rawValue),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return LocalUsageValue.dictionary(object)
    }

    private static func jsonArray(at url: URL, maximumBytes: Int) -> [Any]? {
        guard let data = boundedData(at: url, maximumBytes: maximumBytes),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [Any]
    }

    private static func jsonDictionary(at url: URL, maximumBytes: Int) -> [String: Any]? {
        guard let data = boundedData(at: url, maximumBytes: maximumBytes),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return LocalUsageValue.dictionary(object)
    }

    private static func boundedData(at url: URL, maximumBytes: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0,
              size <= maximumBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
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
