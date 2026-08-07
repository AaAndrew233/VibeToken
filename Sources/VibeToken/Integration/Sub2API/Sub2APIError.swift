import Foundation

enum Sub2APIError: LocalizedError, Equatable, Sendable {
    case invalidServerURL
    case insecureServerURL
    case invalidCredentials
    case administratorRequired
    case captchaRequired
    case twoFactorExpired
    case unauthorized
    case incompatibleServer
    case requestTimedOut
    case serverUnavailable
    case tooManyAccounts
    case secureStorageFailed
    case capacityConfigurationIncomplete
    case unexpectedResponse

    var errorDescription: String? {
        message(language: .simplifiedChinese)
    }

    func message(language: AppLanguage) -> String {
        if language == .english {
            return switch self {
            case .invalidServerURL: "Invalid server address"
            case .insecureServerURL: "Remote servers must use HTTPS"
            case .invalidCredentials: "Incorrect admin email or password"
            case .administratorRequired: "Administrator permission is required"
            case .captchaRequired: "Complete the CAPTCHA login in your browser first"
            case .twoFactorExpired: "The verification session expired; sign in again"
            case .unauthorized: "Admin login expired; reconnect to continue"
            case .incompatibleServer: "This Sub2API version does not expose usage windows"
            case .requestTimedOut: "The relay server timed out"
            case .serverUnavailable: "The relay server is unavailable"
            case .tooManyAccounts: "The account pool exceeds the safe read limit"
            case .secureStorageFailed: "Login state could not be saved locally"
            case .capacityConfigurationIncomplete: "Choose a capacity type for every Pro account"
            case .unexpectedResponse: "The relay server returned unrecognized data"
            }
        }
        return switch self {
        case .invalidServerURL: "中转服务地址无效"
        case .insecureServerURL: "远程中转服务必须使用 HTTPS"
        case .invalidCredentials: "管理员账号或密码不正确"
        case .administratorRequired: "该账号没有管理员权限"
        case .captchaRequired: "后台已启用登录验证码，请先在浏览器完成登录"
        case .twoFactorExpired: "两步验证码会话已过期，请重新登录"
        case .unauthorized: "管理员登录已失效，请重新连接"
        case .incompatibleServer: "当前 Sub2API 版本不支持所需的用量窗口"
        case .requestTimedOut: "中转服务响应超时"
        case .serverUnavailable: "暂时无法连接中转服务"
        case .tooManyAccounts: "账号数量超过安全读取上限"
        case .secureStorageFailed: "无法保存本地登录状态"
        case .capacityConfigurationIncomplete: "请为每个 Pro 账号选择额度类型"
        case .unexpectedResponse: "中转服务返回了无法识别的数据"
        }
    }
}

enum Sub2APIURLBuilder {
    static func normalize(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              scheme == "https" || scheme == "http"
        else {
            throw Sub2APIError.invalidServerURL
        }

        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || isLocal else { throw Sub2APIError.insecureServerURL }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/api/v1"
        } else if path == "api/v1" {
            components.path = "/api/v1"
        } else {
            throw Sub2APIError.invalidServerURL
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw Sub2APIError.invalidServerURL }
        return url
    }
}
