import CryptoKit
import CoreFoundation
import Foundation

enum StableHash {
    static func string(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum LocalUsageValue {
    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func count(_ value: Any?) -> Int64 {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return 0
        }
        let decimal = number.decimalValue
        guard decimal.isFinite, decimal > 0 else { return 0 }
        let rounded = NSDecimalNumber(decimal: decimal).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
        return rounded.compare(NSDecimalNumber(value: Int64.max)) == .orderedDescending
            ? Int64.max
            : max(0, rounded.int64Value)
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func date(_ value: Any?) -> Date? {
        if let text = string(value) {
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }

    static func counters(
        input: Int64,
        cachedInput: Int64,
        cacheWrite: Int64,
        output: Int64,
        reasoning: Int64
    ) -> TokenUsageCounters {
        let normalizedInput = max(0, input)
        let normalizedCached = max(0, cachedInput)
        let normalizedCacheWrite = max(0, cacheWrite)
        let normalizedOutput = max(0, output)
        let normalizedReasoning = max(0, reasoning)
        let total = [
            normalizedInput,
            normalizedCached,
            normalizedCacheWrite,
            normalizedOutput,
            normalizedReasoning
        ].reduce(Int64(0), saturatingAdd)
        return TokenUsageCounters(
            inputTokens: normalizedInput,
            cachedInputTokens: normalizedCached,
            cacheWriteTokens: normalizedCacheWrite,
            outputTokens: normalizedOutput,
            reasoningTokens: normalizedReasoning,
            totalTokens: total
        )
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

enum JSONLStreamReader {
    static func readCompleteLines(
        at url: URL,
        from startOffset: UInt64,
        through endOffset: UInt64,
        chunkBytes: Int,
        maximumLineBytes: Int,
        onLine: (Data, UInt64) throws -> Void
    ) throws -> UInt64 {
        guard startOffset < endOffset else { return startOffset }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)

        var buffer = Data()
        var bufferStartOffset = startOffset
        var readOffset = startOffset
        let newline = Data([0x0A])

        while readOffset < endOffset {
            try Task.checkCancellation()
            let remaining = endOffset - readOffset
            let readCount = min(max(1, chunkBytes), Int(clamping: remaining))
            guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else { break }
            buffer.append(chunk)
            readOffset += UInt64(chunk.count)

            while let range = buffer.range(of: newline) {
                var line = Data(buffer[..<range.lowerBound])
                let consumed = buffer.distance(from: buffer.startIndex, to: range.upperBound)
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty, line.count <= maximumLineBytes {
                    try onLine(line, bufferStartOffset)
                }
                buffer.removeSubrange(..<range.upperBound)
                bufferStartOffset += UInt64(consumed)
            }

            if buffer.count > maximumLineBytes {
                // Keep memory bounded until the oversized record's newline arrives.
                buffer.removeAll(keepingCapacity: true)
                bufferStartOffset = readOffset
            }
        }
        return bufferStartOffset
    }
}

enum LocalUsageFileDiscovery {
    static func files(
        under roots: [URL],
        extensions: Set<String>,
        modifiedSince: Date,
        maximumFiles: Int
    ) -> [URL] {
        var candidates: [(url: URL, modifiedAt: Date)] = []
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey
        ]

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard extensions.contains(fileURL.pathExtension.lowercased()),
                      let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                let modifiedAt = values.contentModificationDate ?? .distantPast
                guard modifiedAt >= modifiedSince else { continue }
                candidates.append((fileURL, modifiedAt))
            }
        }

        return candidates
            .sorted { left, right in
                if left.modifiedAt == right.modifiedAt { return left.url.path < right.url.path }
                return left.modifiedAt > right.modifiedAt
            }
            .prefix(max(1, maximumFiles))
            .map(\.url)
    }
}
