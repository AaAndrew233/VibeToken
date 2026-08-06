import Foundation

enum AppError: LocalizedError, Equatable, Sendable {
    case sourceNotFound
    case permissionDenied
    case unreadableFile
    case malformedUsage
    case database(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            "未找到数据源"
        case .permissionDenied:
            "没有读取数据源的权限"
        case .unreadableFile:
            "无法读取用量文件"
        case .malformedUsage:
            "用量文件格式暂不兼容"
        case .database:
            "本地数据库暂时不可用"
        case .unexpected:
            "发生未知错误"
        }
    }
}
