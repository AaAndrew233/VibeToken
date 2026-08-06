import Foundation
import XCTest
@testable import VibeToken

final class CodexFileChangeObserverTests: XCTestCase {
    func testNotifiesShortlyAfterSessionFileIsAppended() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let changeReceived = DispatchSemaphore(value: 0)
        let observer = CodexFileChangeObserver(debounceMilliseconds: 100)
        observer.watch(fileURL: fileURL) {
            changeReceived.signal()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("{}\n".utf8))
            } catch {
                return
            }
        }

        XCTAssertEqual(changeReceived.wait(timeout: .now() + 1), .success)
        observer.stop()
    }
}
