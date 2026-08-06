import AppKit

@MainActor
final class OutsideClickMonitor {
    typealias Handler = @MainActor @Sendable () -> Void
    typealias StartMonitoring = (@escaping Handler) -> Any?
    typealias StopMonitoring = (Any) -> Void

    private let startMonitoring: StartMonitoring
    private let stopMonitoring: StopMonitoring
    private var monitor: Any?

    init() {
        startMonitoring = { handler in
            NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { _ in
                Task { @MainActor in
                    handler()
                }
            }
        }
        stopMonitoring = { monitor in
            NSEvent.removeMonitor(monitor)
        }
    }

    init(
        startMonitoring: @escaping StartMonitoring,
        stopMonitoring: @escaping StopMonitoring
    ) {
        self.startMonitoring = startMonitoring
        self.stopMonitoring = stopMonitoring
    }

    var isMonitoring: Bool {
        monitor != nil
    }

    func start(onOutsideClick: @escaping Handler) {
        guard monitor == nil else { return }
        monitor = startMonitoring(onOutsideClick)
    }

    func stop() {
        guard let monitor else { return }
        self.monitor = nil
        stopMonitoring(monitor)
    }
}
