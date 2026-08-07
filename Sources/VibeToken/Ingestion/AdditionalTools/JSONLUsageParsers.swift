import Foundation

extension FileUsageParser {
    static func grokEvents(
        fileURL: URL,
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        let sessionDirectory = fileURL.deletingLastPathComponent()
        let summary = boundedDictionary(
            at: sessionDirectory.appendingPathComponent("summary.json"),
            maximumBytes: configuration.maximumStructuredUsageFileBytes
        ) ?? [:]
        let info = LocalUsageValue.dictionary(summary["info"])
        let project = projectName(
            LocalUsageValue.string(info?["cwd"])
                ?? LocalUsageValue.string(summary["git_root_dir"])
        ) ?? grokProjectFallback(
            sessionDirectory: sessionDirectory,
            maximumBytes: configuration.maximumStructuredUsageFileBytes
        )
        let fallbackModel = LocalUsageValue.string(summary["current_model_id"]) ?? "unknown"
        let sessionIdentifier = sessionDirectory.lastPathComponent
        var events: [LocalUsageEvent] = []

        for (record, offset) in try records(at: fileURL, configuration: configuration) {
            guard let update = LocalUsageValue.dictionary(
                LocalUsageValue.dictionary(record["params"])?["update"]
            ),
            LocalUsageValue.string(update["sessionUpdate"]) == "turn_completed",
            let occurredAt = LocalUsageValue.date(record["timestamp"]),
            let usage = LocalUsageValue.dictionary(update["usage"]) else {
                continue
            }
            if let modelUsage = LocalUsageValue.dictionary(usage["modelUsage"]), !modelUsage.isEmpty {
                for model in modelUsage.keys.sorted() {
                    let counters = grokCounters(
                        LocalUsageValue.dictionary(modelUsage[model]) ?? usage
                    )
                    guard counters.totalTokens > 0 else { continue }
                    events.append(LocalUsageEvent(
                        idempotencyKey: "grok:\(sessionIdentifier):\(offset):\(model)",
                        sessionIdentifier: sessionIdentifier,
                        model: model,
                        projectLabel: project,
                        occurredAt: occurredAt,
                        counters: counters,
                        rawSchemaVersion: "grok-turn-completed-v1"
                    ))
                }
            } else {
                let counters = grokCounters(usage)
                guard counters.totalTokens > 0 else { continue }
                events.append(LocalUsageEvent(
                    idempotencyKey: "grok:\(sessionIdentifier):\(offset):\(fallbackModel)",
                    sessionIdentifier: sessionIdentifier,
                    model: fallbackModel,
                    projectLabel: project,
                    occurredAt: occurredAt,
                    counters: counters,
                    rawSchemaVersion: "grok-turn-completed-v1"
                ))
            }
        }
        return events
    }

    static func openClawEvents(
        fileURL: URL,
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        let sessionIdentifier = StableHash.string(fileURL.standardizedFileURL.path)
        let project = component(after: "agents", in: fileURL) ?? "unknown"
        return try records(at: fileURL, configuration: configuration).compactMap { record, offset in
            guard LocalUsageValue.string(record["type"]) == "message",
                  let message = LocalUsageValue.dictionary(record["message"]),
                  LocalUsageValue.string(message["role"]) == "assistant",
                  let usage = LocalUsageValue.dictionary(message["usage"]),
                  let occurredAt = LocalUsageValue.date(record["timestamp"])
                    ?? LocalUsageValue.date(message["timestamp"]) else {
                return nil
            }
            let counters = LocalUsageValue.counters(
                input: firstCount(
                    usage,
                    keys: ["input", "inputTokens", "input_tokens", "promptTokens", "prompt_tokens"]
                ),
                cachedInput: firstCount(
                    usage,
                    keys: ["cacheRead", "cache_read", "cache_read_input_tokens"]
                ),
                cacheWrite: firstCount(
                    usage,
                    keys: ["cacheWrite", "cache_write", "cache_creation_input_tokens"]
                ),
                output: firstCount(
                    usage,
                    keys: ["output", "outputTokens", "output_tokens", "completionTokens", "completion_tokens"]
                ),
                reasoning: firstCount(
                    usage,
                    keys: ["reasoning", "reasoningTokens", "reasoning_tokens"]
                )
            )
            guard counters.totalTokens > 0 else { return nil }
            let identity = LocalUsageValue.string(record["id"])
                ?? LocalUsageValue.string(message["id"])
                ?? String(offset)
            return LocalUsageEvent(
                idempotencyKey: "openclaw:\(sessionIdentifier):\(identity)",
                sessionIdentifier: sessionIdentifier,
                model: LocalUsageValue.string(message["model"])
                    ?? LocalUsageValue.string(record["model"]),
                projectLabel: project,
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "openclaw-message-usage-v1"
            )
        }
    }

    static func piEvents(
        fileURL: URL,
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        var sessionIdentifier = fileURL.deletingPathExtension().lastPathComponent
        var project = piProjectFallback(fileURL)
        var events: [LocalUsageEvent] = []

        for (record, offset) in try records(at: fileURL, configuration: configuration) {
            if LocalUsageValue.string(record["type"]) == "session" {
                sessionIdentifier = LocalUsageValue.string(record["id"]) ?? sessionIdentifier
                project = projectName(LocalUsageValue.string(record["cwd"])) ?? project
                continue
            }
            guard LocalUsageValue.string(record["type"]) == "message",
                  let message = LocalUsageValue.dictionary(record["message"]),
                  LocalUsageValue.string(message["role"]) == "assistant",
                  let usage = LocalUsageValue.dictionary(message["usage"]),
                  let occurredAt = LocalUsageValue.date(record["timestamp"])
                    ?? LocalUsageValue.date(message["timestamp"]) else {
                continue
            }
            let counters = LocalUsageValue.counters(
                input: LocalUsageValue.count(usage["input"]),
                cachedInput: LocalUsageValue.count(usage["cacheRead"]),
                cacheWrite: LocalUsageValue.count(usage["cacheWrite"]),
                output: LocalUsageValue.count(usage["output"]),
                reasoning: LocalUsageValue.count(usage["reasoning"])
            )
            guard counters.totalTokens > 0 else { continue }
            let recordIdentity = LocalUsageValue.string(record["id"])
            let identity = recordIdentity ?? "\(sessionIdentifier):\(offset)"
            events.append(LocalUsageEvent(
                idempotencyKey: "pi-coding-agent:\(identity)",
                sessionIdentifier: sessionIdentifier,
                model: LocalUsageValue.string(message["model"]),
                projectLabel: project,
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "pi-message-usage-v1"
            ))
        }
        return events
    }

    static func qwenEvents(
        fileURL: URL,
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        let sessionIdentifier = StableHash.string(fileURL.standardizedFileURL.path)
        return try records(at: fileURL, configuration: configuration).compactMap { record, offset in
            guard LocalUsageValue.string(record["type"]) == "assistant",
                  let usage = LocalUsageValue.dictionary(record["usageMetadata"]),
                  let occurredAt = LocalUsageValue.date(record["timestamp"]) else {
                return nil
            }
            let cached = LocalUsageValue.count(usage["cachedContentTokenCount"])
            let reasoning = LocalUsageValue.count(usage["thoughtsTokenCount"])
            let counters = LocalUsageValue.counters(
                input: max(0, LocalUsageValue.count(usage["promptTokenCount"]) - cached),
                cachedInput: cached,
                cacheWrite: 0,
                output: max(0, LocalUsageValue.count(usage["candidatesTokenCount"]) - reasoning),
                reasoning: reasoning
            )
            guard counters.totalTokens > 0 else { return nil }
            let identity = LocalUsageValue.string(record["uuid"])
                ?? LocalUsageValue.string(record["id"])
                ?? String(offset)
            return LocalUsageEvent(
                idempotencyKey: "qwen-code:\(identity)",
                sessionIdentifier: sessionIdentifier,
                model: LocalUsageValue.string(record["model"]),
                projectLabel: projectName(LocalUsageValue.string(record["cwd"]))
                    ?? qwenProjectFallback(fileURL),
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "qwen-code-usage-metadata-v1"
            )
        }
    }

    private static func grokCounters(_ usage: [String: Any]) -> TokenUsageCounters {
        let cached = LocalUsageValue.count(usage["cachedReadTokens"])
        let reasoning = LocalUsageValue.count(usage["reasoningTokens"])
        return LocalUsageValue.counters(
            input: max(0, LocalUsageValue.count(usage["inputTokens"]) - cached),
            cachedInput: cached,
            cacheWrite: LocalUsageValue.count(usage["cacheWriteTokens"]),
            output: max(0, LocalUsageValue.count(usage["outputTokens"]) - reasoning),
            reasoning: reasoning
        )
    }

    private static func firstCount(_ dictionary: [String: Any], keys: [String]) -> Int64 {
        for key in keys {
            let count = LocalUsageValue.count(dictionary[key])
            if count > 0 { return count }
        }
        return 0
    }

    private static func component(after name: String, in fileURL: URL) -> String? {
        let components = fileURL.pathComponents
        guard let index = components.lastIndex(of: name), index + 1 < components.count else {
            return nil
        }
        return components[index + 1]
    }

    private static func grokProjectFallback(
        sessionDirectory: URL,
        maximumBytes: Int
    ) -> String {
        let groupDirectory = sessionDirectory.deletingLastPathComponent()
        let cwdFile = groupDirectory.appendingPathComponent(".cwd")
        if let size = try? cwdFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size >= 0,
           size <= maximumBytes,
           let cwd = try? String(contentsOf: cwdFile, encoding: .utf8),
           let project = projectName(cwd.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return project
        }
        return projectName(groupDirectory.lastPathComponent.removingPercentEncoding) ?? "unknown"
    }

    private static func piProjectFallback(_ fileURL: URL) -> String? {
        let encoded = fileURL.deletingLastPathComponent().lastPathComponent
        return encoded.split(separator: "-").last.map(String.init)
    }

    private static func qwenProjectFallback(_ fileURL: URL) -> String? {
        let components = fileURL.pathComponents
        guard let tmpIndex = components.lastIndex(of: "tmp"), tmpIndex + 1 < components.count else {
            return nil
        }
        return components[tmpIndex + 1]
    }
}
