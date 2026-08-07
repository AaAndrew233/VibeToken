import Foundation

struct Sub2APIConnection: Codable, Equatable, Sendable {
    let baseURL: URL
    let email: String
}

struct Sub2APISession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

enum Sub2APILoginResult: Equatable, Sendable {
    case authenticated(Sub2APISession)
    case requiresTwoFactor(tempToken: String, maskedEmail: String)
}

struct Sub2APILoginPayload: Decodable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let user: Sub2APIUserPayload?
    let requiresTwoFactor: Bool?
    let tempToken: String?
    let maskedEmail: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
        case requiresTwoFactor = "requires_2fa"
        case tempToken = "temp_token"
        case maskedEmail = "user_email_masked"
    }
}

struct Sub2APIUserPayload: Decodable, Sendable {
    let role: String
}

struct Sub2APIRefreshPayload: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct Sub2APIEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let code: Int
    let message: String
    let data: Payload?
}

struct Sub2APIPaginatedAccounts: Decodable, Sendable {
    let items: [Sub2APIAccountPayload]
    let total: Int
    let page: Int
    let pageSize: Int
    let pages: Int

    enum CodingKeys: String, CodingKey {
        case items, total, page, pages
        case pageSize = "page_size"
    }
}

struct Sub2APIAccountPayload: Decodable, Sendable {
    let id: Int64
    let name: String?
    let status: String
    let schedulable: Bool
    let parentAccountID: Int64?
    let credentials: Credentials?
    let extra: Extra?
    let rateLimitResetAt: String?
    let overloadUntil: String?
    let tempUnschedulableUntil: String?

    struct Credentials: Decodable, Sendable {
        let planType: String?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            planType = container.flexibleString(forKey: .planType)
            name = container.flexibleString(forKey: .name)
        }
    }

    struct Extra: Decodable, Sendable {
        let fiveHourUsedPercent: Double?
        let fiveHourResetAt: String?
        let fiveHourResetAfterSeconds: Double?
        let sevenDayUsedPercent: Double?
        let sevenDayResetAt: String?
        let sevenDayResetAfterSeconds: Double?
        let usageUpdatedAt: String?
        let primaryUsedPercent: Double?
        let primaryResetAfterSeconds: Double?
        let primaryWindowMinutes: Double?
        let secondaryUsedPercent: Double?
        let secondaryResetAfterSeconds: Double?
        let secondaryWindowMinutes: Double?

        enum CodingKeys: String, CodingKey {
            case fiveHourUsedPercent = "codex_5h_used_percent"
            case fiveHourResetAt = "codex_5h_reset_at"
            case fiveHourResetAfterSeconds = "codex_5h_reset_after_seconds"
            case sevenDayUsedPercent = "codex_7d_used_percent"
            case sevenDayResetAt = "codex_7d_reset_at"
            case sevenDayResetAfterSeconds = "codex_7d_reset_after_seconds"
            case usageUpdatedAt = "codex_usage_updated_at"
            case primaryUsedPercent = "codex_primary_used_percent"
            case primaryResetAfterSeconds = "codex_primary_reset_after_seconds"
            case primaryWindowMinutes = "codex_primary_window_minutes"
            case secondaryUsedPercent = "codex_secondary_used_percent"
            case secondaryResetAfterSeconds = "codex_secondary_reset_after_seconds"
            case secondaryWindowMinutes = "codex_secondary_window_minutes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHourUsedPercent = container.flexibleDouble(forKey: .fiveHourUsedPercent)
            fiveHourResetAt = container.flexibleString(forKey: .fiveHourResetAt)
            fiveHourResetAfterSeconds = container.flexibleDouble(forKey: .fiveHourResetAfterSeconds)
            sevenDayUsedPercent = container.flexibleDouble(forKey: .sevenDayUsedPercent)
            sevenDayResetAt = container.flexibleString(forKey: .sevenDayResetAt)
            sevenDayResetAfterSeconds = container.flexibleDouble(forKey: .sevenDayResetAfterSeconds)
            usageUpdatedAt = container.flexibleString(forKey: .usageUpdatedAt)
            primaryUsedPercent = container.flexibleDouble(forKey: .primaryUsedPercent)
            primaryResetAfterSeconds = container.flexibleDouble(forKey: .primaryResetAfterSeconds)
            primaryWindowMinutes = container.flexibleDouble(forKey: .primaryWindowMinutes)
            secondaryUsedPercent = container.flexibleDouble(forKey: .secondaryUsedPercent)
            secondaryResetAfterSeconds = container.flexibleDouble(forKey: .secondaryResetAfterSeconds)
            secondaryWindowMinutes = container.flexibleDouble(forKey: .secondaryWindowMinutes)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, schedulable, credentials, extra
        case rateLimitResetAt = "rate_limit_reset_at"
        case overloadUntil = "overload_until"
        case tempUnschedulableUntil = "temp_unschedulable_until"
        case parentAccountID = "parent_account_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = container.flexibleString(forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        schedulable = try container.decode(Bool.self, forKey: .schedulable)
        parentAccountID = container.flexibleInt64(forKey: .parentAccountID)
        credentials = try? container.decodeIfPresent(Credentials.self, forKey: .credentials)
        extra = try? container.decodeIfPresent(Extra.self, forKey: .extra)
        rateLimitResetAt = container.flexibleString(forKey: .rateLimitResetAt)
        overloadUntil = container.flexibleString(forKey: .overloadUntil)
        tempUnschedulableUntil = container.flexibleString(forKey: .tempUnschedulableUntil)
    }

    func snapshot(
        now: Date,
        capacityTier: Sub2APICapacityTier? = nil
    ) -> Sub2APIAccountSnapshot {
        let fiveHourFallback = extra?.legacyWindow(minutes: 300)
        let sevenDayFallback = extra?.legacyWindow(minutes: 10_080)
        return Sub2APIAccountSnapshot(
            id: id,
            status: status,
            schedulable: schedulable,
            parentAccountID: parentAccountID,
            plan: Self.normalizedPlan(credentials?.planType),
            capacityTier: resolvedCapacityTier(configuredTier: capacityTier),
            fiveHourUsedPercent: extra?.fiveHourUsedPercent ?? fiveHourFallback?.usedPercent,
            fiveHourResetAt: Self.resolveResetAt(
                absolute: extra?.fiveHourResetAt,
                afterSeconds: extra?.fiveHourResetAfterSeconds ?? fiveHourFallback?.resetAfterSeconds,
                now: now
            ),
            sevenDayUsedPercent: extra?.sevenDayUsedPercent ?? sevenDayFallback?.usedPercent,
            sevenDayResetAt: Self.resolveResetAt(
                absolute: extra?.sevenDayResetAt,
                afterSeconds: extra?.sevenDayResetAfterSeconds ?? sevenDayFallback?.resetAfterSeconds,
                now: now
            ),
            usageUpdatedAt: extra?.usageUpdatedAt.flatMap(Self.parseDate),
            rateLimitResetAt: rateLimitResetAt.flatMap(Self.parseDate),
            overloadUntil: overloadUntil.flatMap(Self.parseDate),
            tempUnschedulableUntil: tempUnschedulableUntil.flatMap(Self.parseDate)
        )
    }

    var capacityDisplayName: String? {
        let value = name ?? credentials?.name
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    var detectedPlan: String {
        Self.normalizedPlan(credentials?.planType)
    }

    var requiresManualCapacityTier: Bool {
        detectedPlan.caseInsensitiveCompare("Pro") == .orderedSame
    }

    func resolvedCapacityTier(
        configuredTier: Sub2APICapacityTier?
    ) -> Sub2APICapacityTier? {
        if requiresManualCapacityTier {
            guard configuredTier?.isProCapacity == true else { return nil }
            return configuredTier
        }
        return .plus
    }

    private static func normalizedPlan(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed!.capitalized : "Unknown"
    }

    private static func resolveResetAt(
        absolute: String?,
        afterSeconds: Double?,
        now: Date
    ) -> Date? {
        if let absolute, let parsed = parseDate(absolute) { return parsed }
        guard let afterSeconds, afterSeconds >= 0 else { return nil }
        return now.addingTimeInterval(afterSeconds)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }
        guard let timestamp = Double(value), timestamp.isFinite else { return nil }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }
}

private extension KeyedDecodingContainer {
    func flexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = try? decode(String.self, forKey: key),
           let parsed = Double(value),
           parsed.isFinite {
            return parsed
        }
        return nil
    }

    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key), value.isFinite {
            return String(value)
        }
        return nil
    }

    func flexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int64(value) }
        return nil
    }
}

private extension Sub2APIAccountPayload.Extra {
    func legacyWindow(minutes targetMinutes: Double) -> (usedPercent: Double, resetAfterSeconds: Double?)? {
        let tolerance = 1.0
        if let primaryWindowMinutes,
           abs(primaryWindowMinutes - targetMinutes) <= tolerance,
           let primaryUsedPercent {
            return (primaryUsedPercent, primaryResetAfterSeconds)
        }
        if let secondaryWindowMinutes,
           abs(secondaryWindowMinutes - targetMinutes) <= tolerance,
           let secondaryUsedPercent {
            return (secondaryUsedPercent, secondaryResetAfterSeconds)
        }
        return nil
    }
}
