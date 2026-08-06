import AppKit
import XCTest
@testable import VibeToken

@MainActor
final class OutsideClickMonitorTests: XCTestCase {
    private final class CallbackRecorder: @unchecked Sendable {
        var callCount = 0
    }

    func testRegistersOnceForwardsOutsideClickAndStopsOnce() {
        let token = NSObject()
        var startCount = 0
        var stopCount = 0
        var capturedHandler: OutsideClickMonitor.Handler?
        var stoppedToken: Any?
        let callbackRecorder = CallbackRecorder()

        let monitor = OutsideClickMonitor(
            startMonitoring: { handler in
                startCount += 1
                capturedHandler = handler
                return token
            },
            stopMonitoring: { receivedToken in
                stopCount += 1
                stoppedToken = receivedToken
            }
        )

        monitor.start {
            callbackRecorder.callCount += 1
        }
        monitor.start {
            callbackRecorder.callCount += 1
        }

        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertEqual(startCount, 1)

        capturedHandler?()
        XCTAssertEqual(callbackRecorder.callCount, 1)

        monitor.stop()
        monitor.stop()

        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue((stoppedToken as AnyObject) === token)
    }
}
