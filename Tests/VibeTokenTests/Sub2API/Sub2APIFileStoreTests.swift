import Foundation
import XCTest
@testable import VibeToken

final class Sub2APIFileStoreTests: XCTestCase {
    func testSessionAndConnectionPersistAcrossStoreInstances() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = Sub2APISession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let connection = Sub2APIConnection(
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/api/v1")),
            email: "admin@example.com"
        )

        try FileSub2APISessionStore(supportDirectory: directory).save(session)
        try FileSub2APIConnectionStore(supportDirectory: directory).save(connection)

        XCTAssertEqual(
            try FileSub2APISessionStore(supportDirectory: directory).load(),
            session
        )
        XCTAssertEqual(
            try FileSub2APIConnectionStore(supportDirectory: directory).load(),
            connection
        )

        let sessionData = try Data(
            contentsOf: directory.appendingPathComponent("sub2api-session.json")
        )
        XCTAssertFalse(String(decoding: sessionData, as: UTF8.self).contains("password"))
    }

    func testFilesUseOwnerOnlyPermissionsAndDeleteCleanly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSub2APISessionStore(supportDirectory: directory)
        try store.save(Sub2APISession(accessToken: "access", refreshToken: nil, expiresAt: nil))

        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(
            try permissions(at: directory.appendingPathComponent("sub2api-session.json")),
            0o600
        )

        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testCapacityConfigurationPersistsAcrossStoreInstances() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = Sub2APIAccountCapacityConfiguration(
            selectionsByServer: [
                "https://relay.example.com/api/v1": [
                    Sub2APIAccountCapacitySelection(accountID: 7, tier: .pro20),
                    Sub2APIAccountCapacitySelection(accountID: 8, tier: .pro5),
                    Sub2APIAccountCapacitySelection(accountID: 9, tier: .pro10)
                ]
            ]
        )

        try FileSub2APICapacityConfigurationStore(supportDirectory: directory)
            .save(configuration)

        XCTAssertEqual(
            try FileSub2APICapacityConfigurationStore(supportDirectory: directory).load(),
            configuration
        )
        XCTAssertEqual(
            try permissions(at: directory.appendingPathComponent("sub2api-capacity-config.json")),
            0o600
        )
    }

    func testRejectsSymbolicLinkOversizedAndCorruptedFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sub2api-session.json")
        let targetURL = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: targetURL)

        let store = FileSub2APISessionStore(supportDirectory: directory, maximumFileSize: 64)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? Sub2APIError, .secureStorageFailed)
        }

        try FileManager.default.removeItem(at: fileURL)
        try Data(repeating: 0x41, count: 65).write(to: fileURL)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? Sub2APIError, .secureStorageFailed)
        }

        try Data("not-json".utf8).write(to: fileURL)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? Sub2APIError, .secureStorageFailed)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeTokenTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
