import Darwin
import Foundation

struct AntigravityLegacyClient: Sendable {
    func events(
        cascadeIdentifiers: [String],
        historyStart: Date
    ) async -> [LocalUsageEvent] {
        guard let server = findLanguageServer(),
              let baseURL = await findLanguageServerURL(server: server) else {
            return []
        }
        var events: [LocalUsageEvent] = []
        for cascadeIdentifier in cascadeIdentifiers {
            guard !Task.isCancelled,
                  let response = await request(
                    baseURL: baseURL,
                    method: "GetCascadeTrajectory",
                    body: ["cascadeId": cascadeIdentifier],
                    csrfToken: server.csrfToken
                  ),
                  let trajectory = LocalUsageValue.dictionary(response["trajectory"]) else {
                continue
            }
            let project = projectLabel(trajectory) ?? "unknown"
            let metadata = trajectory["generatorMetadata"] as? [Any] ?? []
            for (metadataIndex, rawMetadata) in metadata.enumerated() {
                guard let metadataRecord = LocalUsageValue.dictionary(rawMetadata),
                      let chatModel = LocalUsageValue.dictionary(metadataRecord["chatModel"]),
                      let startMetadata = LocalUsageValue.dictionary(chatModel["chatStartMetadata"]),
                      let occurredAt = LocalUsageValue.date(startMetadata["createdAt"]),
                      occurredAt >= historyStart else {
                    continue
                }
                let model = resolvedModel(chatModel)
                let retries = chatModel["retryInfos"] as? [Any] ?? []
                for (retryIndex, rawRetry) in retries.enumerated() {
                    guard let retry = LocalUsageValue.dictionary(rawRetry),
                          let usage = LocalUsageValue.dictionary(retry["usage"]) else {
                        continue
                    }
                    let counters = LocalUsageValue.counters(
                        input: LocalUsageValue.count(usage["inputTokens"]),
                        cachedInput: LocalUsageValue.count(usage["cacheReadTokens"]),
                        cacheWrite: LocalUsageValue.count(usage["cacheWriteTokens"]),
                        output: LocalUsageValue.count(usage["outputTokens"]),
                        reasoning: LocalUsageValue.count(usage["thinkingOutputTokens"])
                    )
                    guard counters.totalTokens > 0 else { continue }
                    let responseIdentifier = LocalUsageValue.string(usage["responseId"])
                    events.append(LocalUsageEvent(
                        idempotencyKey: responseIdentifier.map { "antigravity:\($0)" }
                            ?? "antigravity:\(cascadeIdentifier):legacy:\(metadataIndex):\(retryIndex)",
                        sessionIdentifier: cascadeIdentifier,
                        model: model,
                        projectLabel: project,
                        occurredAt: occurredAt,
                        counters: counters,
                        rawSchemaVersion: "antigravity-language-server-v1"
                    ))
                }
            }
        }
        return events
    }

    private func findLanguageServer() -> LanguageServer? {
        guard let output = ProcessOutput.run(
            executable: "/bin/ps",
            arguments: ["-ww", "-axo", "pid=,command="],
            timeout: 3
        ) else {
            return nil
        }
        let expression = try? NSRegularExpression(
            pattern: #"--csrf_token\s+([0-9a-f-]+)"#,
            options: [.caseInsensitive]
        )
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            let lowercase = text.lowercased()
            guard lowercase.contains("antigravity"), lowercase.contains("language_server") else {
                continue
            }
            let parts = text.split(whereSeparator: \Character.isWhitespace)
            guard let processIdentifier = parts.first.map(String.init),
                  Int(processIdentifier) != nil,
                  let expression,
                  let match = expression.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                  ),
                  let tokenRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            return LanguageServer(
                processIdentifier: processIdentifier,
                csrfToken: String(text[tokenRange])
            )
        }
        return nil
    }

    private func findLanguageServerURL(server: LanguageServer) async -> URL? {
        let lsofPath = ["/usr/sbin/lsof", "/usr/bin/lsof"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let lsofPath,
              let output = ProcessOutput.run(
                executable: lsofPath,
                arguments: [
                    "-a", "-p", server.processIdentifier,
                    "-iTCP", "-sTCP:LISTEN", "-nP"
                ],
                timeout: 3
              ) else {
            return nil
        }
        let expression = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#)
        var ports = Set<Int>()
        if let expression {
            let range = NSRange(output.startIndex..., in: output)
            for match in expression.matches(in: output, range: range) {
                guard let portRange = Range(match.range(at: 1), in: output),
                      let port = Int(output[portRange]),
                      (1...65_535).contains(port) else {
                    continue
                }
                ports.insert(port)
            }
        }
        for port in ports.sorted() {
            guard let baseURL = URL(string: "http://127.0.0.1:\(port)"),
                  await request(
                    baseURL: baseURL,
                    method: "GetWorkspaceInfos",
                    body: [:],
                    csrfToken: server.csrfToken
                  ) != nil else {
                continue
            }
            return baseURL
        }
        return nil
    }

    private func request(
        baseURL: URL,
        method: String,
        body: [String: Any],
        csrfToken: String
    ) async -> [String: Any]? {
        let endpoint = baseURL.appendingPathComponent(
            "exa.language_server_pb.LanguageServerService/\(method)"
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }
            return LocalUsageValue.dictionary(object)
        } catch {
            return nil
        }
    }

    private func projectLabel(_ trajectory: [String: Any]) -> String? {
        guard let metadata = LocalUsageValue.dictionary(trajectory["metadata"]),
              let workspaces = metadata["workspaces"] as? [Any],
              let first = workspaces.first.flatMap(LocalUsageValue.dictionary) else {
            return nil
        }
        let repository = LocalUsageValue.dictionary(first["repository"])
        return LocalUsageValue.string(repository?["computedName"])
            ?? FileUsageParser.projectName(
                LocalUsageValue.string(first["workspaceFolderAbsoluteUri"])
            )
    }

    private func resolvedModel(_ chatModel: [String: Any]) -> String {
        if let displayName = LocalUsageValue.string(chatModel["modelDisplayName"]) {
            return displayName
        }
        if let responseModel = LocalUsageValue.string(chatModel["responseModel"]) {
            switch responseModel {
            case "claude-opus-4-6-thinking": return "claude-opus-4-6"
            case "claude-sonnet-4-6-thinking": return "claude-sonnet-4-6"
            case "gemini-3.1-pro-high", "gemini-3.1-pro-low": return "gemini-3.1-pro"
            case "gemini-3-pro-high", "gemini-3-pro-low": return "gemini-3-pro"
            default: return responseModel
            }
        }
        let placeholders = [
            "MODEL_PLACEHOLDER_M37": "gemini-3.1-pro",
            "MODEL_PLACEHOLDER_M36": "gemini-3.1-pro",
            "MODEL_PLACEHOLDER_M47": "gemini-3-flash",
            "MODEL_PLACEHOLDER_M35": "claude-sonnet-4-6",
            "MODEL_PLACEHOLDER_M26": "claude-opus-4-6",
            "MODEL_OPENAI_GPT_OSS_120B_MEDIUM": "gpt-oss-120b"
        ]
        return LocalUsageValue.string(chatModel["model"]).flatMap { placeholders[$0] }
            ?? "unknown"
    }
}

private struct LanguageServer: Sendable {
    let processIdentifier: String
    let csrfToken: String
}

private enum ProcessOutput {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        let pipe = Pipe()
        let box = LockedProcessData()
        let readFinished = DispatchSemaphore(value: 0)
        let processFinished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in processFinished.signal() }
        DispatchQueue.global(qos: .utility).async {
            box.set(pipe.fileHandleForReading.readDataToEndOfFile())
            readFinished.signal()
        }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForReading.close()
            return nil
        }
        if processFinished.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            process.terminate()
            if processFinished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + 1)
            }
        }
        try? pipe.fileHandleForWriting.close()
        _ = readFinished.wait(timeout: .now() + 1)
        guard !process.isRunning,
              process.terminationStatus == 0,
              let data = box.value() else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private final class LockedProcessData: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func value() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
