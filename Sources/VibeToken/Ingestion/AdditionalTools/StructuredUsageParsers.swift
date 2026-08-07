import CryptoKit
import Foundation

extension FileUsageParser {
    static func kimiEvents(
        fileURL: URL,
        roots: [URL],
        configuration: AppConfiguration,
        homeDirectory _: URL
    ) throws -> [LocalUsageEvent] {
        if fileURL.pathComponents.contains("agents") {
            return try currentKimiEvents(
                fileURL: fileURL,
                roots: roots,
                configuration: configuration
            )
        }
        return try legacyKimiEvents(
            fileURL: fileURL,
            roots: roots,
            configuration: configuration
        )
    }

    static func ampEvents(fileURL: URL) throws -> [LocalUsageEvent] {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let object = try? JSONSerialization.jsonObject(with: data),
              let thread = LocalUsageValue.dictionary(object) else {
            return []
        }
        let sessionIdentifier = LocalUsageValue.string(thread["id"])
            ?? StableHash.string(fileURL.standardizedFileURL.path)
        let messages = thread["messages"] as? [Any] ?? []
        let ledger = LocalUsageValue.dictionary(thread["usageLedger"])
        let ledgerEvents = ledger?["events"] as? [Any] ?? []
        var events: [LocalUsageEvent] = []

        if !ledgerEvents.isEmpty {
            for (index, rawEvent) in ledgerEvents.enumerated() {
                guard let event = LocalUsageValue.dictionary(rawEvent),
                      let tokens = LocalUsageValue.dictionary(event["tokens"]),
                      let occurredAt = LocalUsageValue.date(event["timestamp"]) else {
                    continue
                }
                let messageIndex = Int(LocalUsageValue.count(event["toMessageId"]))
                let message = messages[safe: messageIndex].flatMap(LocalUsageValue.dictionary)
                let usage = LocalUsageValue.dictionary(message?["usage"])
                let counters = LocalUsageValue.counters(
                    input: LocalUsageValue.count(tokens["input"]),
                    cachedInput: LocalUsageValue.count(usage?["cacheReadInputTokens"]),
                    cacheWrite: LocalUsageValue.count(usage?["cacheCreationInputTokens"]),
                    output: LocalUsageValue.count(tokens["output"]),
                    reasoning: LocalUsageValue.count(tokens["reasoning"])
                )
                guard counters.totalTokens > 0 else { continue }
                let identity = LocalUsageValue.string(event["id"]) ?? String(index)
                events.append(LocalUsageEvent(
                    idempotencyKey: "amp:\(sessionIdentifier):ledger:\(identity)",
                    sessionIdentifier: sessionIdentifier,
                    model: LocalUsageValue.string(event["model"]),
                    projectLabel: projectName(LocalUsageValue.string(thread["cwd"])),
                    occurredAt: occurredAt,
                    counters: counters,
                    rawSchemaVersion: "amp-usage-ledger-v1"
                ))
            }
            return events
        }

        for (index, rawMessage) in messages.enumerated() {
            guard let message = LocalUsageValue.dictionary(rawMessage),
                  let usage = LocalUsageValue.dictionary(message["usage"]),
                  let occurredAt = LocalUsageValue.date(message["timestamp"])
                    ?? LocalUsageValue.date(thread["created"]) else {
                continue
            }
            let counters = LocalUsageValue.counters(
                input: LocalUsageValue.count(usage["inputTokens"]),
                cachedInput: LocalUsageValue.count(usage["cacheReadInputTokens"]),
                cacheWrite: LocalUsageValue.count(usage["cacheCreationInputTokens"]),
                output: LocalUsageValue.count(usage["outputTokens"]),
                reasoning: LocalUsageValue.count(usage["reasoningTokens"])
            )
            guard counters.totalTokens > 0 else { continue }
            events.append(LocalUsageEvent(
                idempotencyKey: "amp:\(sessionIdentifier):message:\(index)",
                sessionIdentifier: sessionIdentifier,
                model: LocalUsageValue.string(usage["model"]),
                projectLabel: projectName(LocalUsageValue.string(thread["cwd"])),
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "amp-message-usage-v1"
            ))
        }
        return events
    }

    static func droidEvents(
        settingsURL: URL,
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        guard let settings = boundedDictionary(
            at: settingsURL,
            maximumBytes: configuration.maximumStructuredUsageFileBytes
        ),
        let tokenUsage = LocalUsageValue.dictionary(settings["tokenUsage"]) else {
            return []
        }
        let settingsName = settingsURL.lastPathComponent
        let sessionIdentifier = String(settingsName.dropLast(".settings.json".count))
        let occurredAt = try settingsURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        guard let occurredAt else { return [] }

        let cached = LocalUsageValue.count(tokenUsage["cacheReadTokens"])
        let reasoning = LocalUsageValue.count(tokenUsage["thinkingTokens"])
        let counters = LocalUsageValue.counters(
            input: max(0, LocalUsageValue.count(tokenUsage["inputTokens"]) - cached),
            cachedInput: cached,
            cacheWrite: LocalUsageValue.count(tokenUsage["cacheWriteTokens"]),
            output: max(0, LocalUsageValue.count(tokenUsage["outputTokens"]) - reasoning),
            reasoning: reasoning
        )
        guard counters.totalTokens > 0 else { return [] }
        let slug = settingsURL.deletingLastPathComponent().lastPathComponent
        return [LocalUsageEvent(
            idempotencyKey: "droid:\(sessionIdentifier):cumulative",
            sessionIdentifier: sessionIdentifier,
            model: LocalUsageValue.string(settings["model"]),
            projectLabel: slug.split(separator: "-").last.map(String.init),
            occurredAt: occurredAt,
            counters: counters,
            rawSchemaVersion: "droid-session-cumulative-snapshot-v2"
        )]
    }

    static func traeEvents(
        fileURL: URL,
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        struct TraceUsage {
            var model: String?
            var input: Int64 = 0
            var output: Int64 = 0
            var cached: Int64 = 0
            var reasoning: Int64 = 0
            var startTime: Decimal?
        }

        let sessionDirectory = fileURL.deletingLastPathComponent()
        let sessionIdentifier = sessionDirectory.lastPathComponent
        let session = boundedDictionary(
            at: sessionDirectory.appendingPathComponent("session.json"),
            maximumBytes: configuration.maximumStructuredUsageFileBytes
        ) ?? [:]
        let metadata = LocalUsageValue.dictionary(session["metadata"])
        let project = projectName(LocalUsageValue.string(metadata?["cwd"]))
        let fallbackModel = LocalUsageValue.string(metadata?["model_name"])
        var traces: [String: TraceUsage] = [:]

        for (record, _) in try records(at: fileURL, configuration: configuration) {
            guard let traceIdentifier = LocalUsageValue.string(record["traceID"]),
                  let tags = record["tags"] as? [Any] else {
                continue
            }
            var tagMap: [String: Any] = [:]
            for rawTag in tags {
                guard let tag = LocalUsageValue.dictionary(rawTag),
                      let key = LocalUsageValue.string(tag["key"]) else {
                    continue
                }
                tagMap[key] = tag["value"]
            }
            let input = LocalUsageValue.count(tagMap["usage.input_tokens"])
            let output = LocalUsageValue.count(tagMap["usage.output_tokens"])
            let cached = LocalUsageValue.count(tagMap["usage.cache_read_tokens"])
            let reasoning = LocalUsageValue.count(tagMap["usage.reasoning_tokens"])
            guard input > 0 || output > 0 || cached > 0 || reasoning > 0 else { continue }

            var trace = traces[traceIdentifier] ?? TraceUsage()
            trace.model = LocalUsageValue.string(tagMap["model.name"])
                ?? LocalUsageValue.string(tagMap["semantic.name"])
                ?? trace.model
            trace.input = max(trace.input, input)
            trace.output = max(trace.output, output)
            trace.cached = max(trace.cached, cached)
            trace.reasoning = max(trace.reasoning, reasoning)
            if let start = decimal(record["startTime"]), start > 0 {
                trace.startTime = trace.startTime.map { min($0, start) } ?? start
            }
            traces[traceIdentifier] = trace
        }

        return traces.compactMap { traceIdentifier, trace in
            guard let startTime = trace.startTime else { return nil }
            let seconds = NSDecimalNumber(decimal: startTime / 1_000_000).doubleValue
            guard seconds.isFinite, seconds > 0 else { return nil }
            let counters = LocalUsageValue.counters(
                input: trace.input,
                cachedInput: trace.cached,
                cacheWrite: 0,
                output: trace.output,
                reasoning: trace.reasoning
            )
            return LocalUsageEvent(
                idempotencyKey: "trae-cli:\(sessionIdentifier):\(traceIdentifier)",
                sessionIdentifier: sessionIdentifier,
                model: trace.model ?? fallbackModel,
                projectLabel: project,
                occurredAt: Date(timeIntervalSince1970: seconds),
                counters: counters,
                rawSchemaVersion: "trae-cli-trace-v1"
            )
        }
    }

    private static func currentKimiEvents(
        fileURL: URL,
        roots: [URL],
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        let sessionDirectory = fileURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessionsRoot = roots.first { fileURL.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path) }
        let currentRoot = sessionsRoot?.deletingLastPathComponent()
        let project = currentRoot.flatMap {
            kimiSessionIndex(
                at: $0.appendingPathComponent("session_index.jsonl"),
                configuration: configuration
            )[sessionDirectory.standardizedFileURL.path]
        } ?? kimiBucketProject(sessionDirectory.deletingLastPathComponent().lastPathComponent)
        let sessionIdentifier = StableHash.string(sessionDirectory.standardizedFileURL.path)
        let fileIdentity = StableHash.string(fileURL.standardizedFileURL.path)

        return try records(at: fileURL, configuration: configuration).compactMap { record, offset in
            guard LocalUsageValue.string(record["type"]) == "usage.record",
                  let usage = LocalUsageValue.dictionary(record["usage"]),
                  let occurredAt = LocalUsageValue.date(record["time"]) else {
                return nil
            }
            let counters = LocalUsageValue.counters(
                input: saturatingAdd(
                    LocalUsageValue.count(usage["inputOther"]),
                    LocalUsageValue.count(usage["inputCacheCreation"])
                ),
                cachedInput: LocalUsageValue.count(usage["inputCacheRead"]),
                cacheWrite: 0,
                output: LocalUsageValue.count(usage["output"]),
                reasoning: LocalUsageValue.count(usage["reasoning"])
            )
            guard counters.totalTokens > 0 else { return nil }
            return LocalUsageEvent(
                idempotencyKey: "kimi-code:\(fileIdentity):\(offset)",
                sessionIdentifier: sessionIdentifier,
                model: LocalUsageValue.string(record["model"]),
                projectLabel: project,
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "kimi-code-usage-record-v1"
            )
        }
    }

    private static func legacyKimiEvents(
        fileURL: URL,
        roots: [URL],
        configuration: AppConfiguration
    ) throws -> [LocalUsageEvent] {
        let sessionIdentifier = StableHash.string(fileURL.deletingLastPathComponent().standardizedFileURL.path)
        let workDirectoryHash = fileURL.deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        let legacyRoot = roots.first { $0.lastPathComponent == "sessions" && $0.path.contains("/.kimi/") }
        let project = legacyRoot.flatMap {
            legacyKimiProjectMap(
                at: $0.deletingLastPathComponent().appendingPathComponent("kimi.json"),
                maximumBytes: configuration.maximumStructuredUsageFileBytes
            )[workDirectoryHash]
        } ?? workDirectoryHash
        let defaultModel = legacyRoot.flatMap {
            legacyKimiModel(
                at: $0.deletingLastPathComponent().appendingPathComponent("config.toml"),
                maximumBytes: configuration.maximumStructuredUsageFileBytes
            )
        }
        var currentModel = defaultModel
        var lastTimestamp: Date?
        var events: [LocalUsageEvent] = []

        for (record, offset) in try records(at: fileURL, configuration: configuration) {
            let envelope = LocalUsageValue.dictionary(record["message"]) ?? record
            let type = LocalUsageValue.string(envelope["type"])
                ?? LocalUsageValue.string(record["type"])
            guard let payload = LocalUsageValue.dictionary(envelope["payload"])
                ?? LocalUsageValue.dictionary(record["payload"]) else {
                continue
            }
            lastTimestamp = LocalUsageValue.date(record["timestamp"])
                ?? LocalUsageValue.date(payload["timestamp"])
                ?? lastTimestamp
            currentModel = LocalUsageValue.string(payload["model"]) ?? currentModel
            guard type == "StatusUpdate",
                  let usage = LocalUsageValue.dictionary(payload["token_usage"]),
                  let occurredAt = lastTimestamp else {
                continue
            }
            let counters = LocalUsageValue.counters(
                input: saturatingAdd(
                    LocalUsageValue.count(usage["input_other"]),
                    LocalUsageValue.count(usage["input_cache_creation"])
                ),
                cachedInput: LocalUsageValue.count(usage["input_cache_read"]),
                cacheWrite: 0,
                output: LocalUsageValue.count(usage["output"]),
                reasoning: LocalUsageValue.count(usage["reasoning"])
            )
            guard counters.totalTokens > 0 else { continue }
            let messageIdentity = LocalUsageValue.string(payload["message_id"])
            let identity = messageIdentity ?? "\(sessionIdentifier):\(offset)"
            events.append(LocalUsageEvent(
                idempotencyKey: "kimi-code:legacy:\(identity)",
                sessionIdentifier: sessionIdentifier,
                model: currentModel,
                projectLabel: project,
                occurredAt: occurredAt,
                counters: counters,
                rawSchemaVersion: "kimi-code-legacy-status-v1"
            ))
        }
        return events
    }

    private static func kimiSessionIndex(
        at fileURL: URL,
        configuration: AppConfiguration
    ) -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let records = try? records(at: fileURL, configuration: configuration) else {
            return [:]
        }
        var result: [String: String] = [:]
        for (record, _) in records {
            guard let rawDirectory = LocalUsageValue.string(record["sessionDir"]),
                  let project = projectName(LocalUsageValue.string(record["workDir"])) else {
                continue
            }
            result[URL(fileURLWithPath: rawDirectory).standardizedFileURL.path] = project
        }
        return result
    }

    private static func kimiBucketProject(_ name: String) -> String {
        guard name.hasPrefix("wd_"),
              let separator = name.lastIndex(of: "_") else {
            return name
        }
        return String(name[name.index(name.startIndex, offsetBy: 3)..<separator])
    }

    private static func legacyKimiProjectMap(
        at fileURL: URL,
        maximumBytes: Int
    ) -> [String: String] {
        guard let record = boundedDictionary(at: fileURL, maximumBytes: maximumBytes) else {
            return [:]
        }
        var result: [String: String] = [:]
        if let workDirectories = record["work_dirs"] as? [Any] {
            for rawItem in workDirectories {
                guard let item = LocalUsageValue.dictionary(rawItem),
                      let path = LocalUsageValue.string(item["path"]),
                      let project = projectName(path) else {
                    continue
                }
                let hash = Insecure.MD5.hash(data: Data(path.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                result[hash] = project
            }
        }
        for key in ["workspaces", "projects"] {
            guard let values = LocalUsageValue.dictionary(record[key]) else { continue }
            for (hash, rawValue) in values {
                let path = LocalUsageValue.string(rawValue)
                    ?? LocalUsageValue.string(LocalUsageValue.dictionary(rawValue)?["path"])
                    ?? LocalUsageValue.string(LocalUsageValue.dictionary(rawValue)?["dir"])
                if let project = projectName(path) { result[hash] = project }
            }
        }
        return result
    }

    private static func legacyKimiModel(at fileURL: URL, maximumBytes: Int) -> String? {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0,
              size <= maximumBytes,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let patterns = [
            #"(?m)^\s*default_model\s*=\s*[\"']([^\"']+)[\"']"#,
            #"(?m)^\s*\[models\.(?:\"([^\"]+)\"|([A-Za-z0-9_-]+))\]"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                  ) else {
                continue
            }
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: text) {
                    return String(text[range])
                }
            }
        }
        return nil
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber,
              !(value is Bool),
              number.decimalValue.isFinite else {
            return nil
        }
        return number.decimalValue
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
