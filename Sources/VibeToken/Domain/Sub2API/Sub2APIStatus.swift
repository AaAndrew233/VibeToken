enum Sub2APIStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case requiresTwoFactor(maskedEmail: String)
    case syncing
    case connected
    case failed(Sub2APIError)

    var isBusy: Bool {
        switch self {
        case .connecting, .syncing: true
        default: false
        }
    }
}
