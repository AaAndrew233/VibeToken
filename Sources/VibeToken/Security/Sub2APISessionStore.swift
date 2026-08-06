import Darwin
import Foundation

protocol Sub2APISessionStoring: Sendable {
    func load() throws -> Sub2APISession?
    func save(_ session: Sub2APISession) throws
    func delete() throws
}

protocol Sub2APIConnectionStoring: Sendable {
    func load() throws -> Sub2APIConnection?
    func save(_ connection: Sub2APIConnection) throws
    func delete() throws
}

struct FileSub2APISessionStore: Sub2APISessionStoring {
    private let store: LocalCodableFileStore<Sub2APISession>

    init(supportDirectory: URL, maximumFileSize: Int = 64 * 1_024) {
        store = LocalCodableFileStore(
            fileURL: supportDirectory.appendingPathComponent(
                "sub2api-session.json",
                isDirectory: false
            ),
            maximumFileSize: maximumFileSize
        )
    }

    func load() throws -> Sub2APISession? {
        try store.load()
    }

    func save(_ session: Sub2APISession) throws {
        try store.save(session)
    }

    func delete() throws {
        try store.delete()
    }
}

struct FileSub2APIConnectionStore: Sub2APIConnectionStoring {
    private let store: LocalCodableFileStore<Sub2APIConnection>

    init(supportDirectory: URL, maximumFileSize: Int = 64 * 1_024) {
        store = LocalCodableFileStore(
            fileURL: supportDirectory.appendingPathComponent(
                "sub2api-connection.json",
                isDirectory: false
            ),
            maximumFileSize: maximumFileSize
        )
    }

    func load() throws -> Sub2APIConnection? {
        try store.load()
    }

    func save(_ connection: Sub2APIConnection) throws {
        try store.save(connection)
    }

    func delete() throws {
        try store.delete()
    }
}

private struct LocalCodableFileStore<Value: Codable & Sendable>: Sendable {
    let fileURL: URL
    let maximumFileSize: Int

    func load() throws -> Value? {
        try ensureSecureDirectory()
        guard let metadata = try metadataIfPresent(at: fileURL) else { return nil }
        guard metadata.isRegularFile,
              metadata.ownerID == geteuid(),
              metadata.size >= 0,
              metadata.size <= maximumFileSize
        else {
            throw Sub2APIError.secureStorageFailed
        }
        guard chmod(fileURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw Sub2APIError.secureStorageFailed
        }

        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Sub2APIError.secureStorageFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
            try handle.close()
            guard data.count <= maximumFileSize else {
                throw Sub2APIError.secureStorageFailed
            }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            try? handle.close()
            throw Sub2APIError.secureStorageFailed
        }
    }

    func save(_ value: Value) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw Sub2APIError.secureStorageFailed
        }
        guard data.count <= maximumFileSize else {
            throw Sub2APIError.secureStorageFailed
        }

        try ensureSecureDirectory()
        if let metadata = try metadataIfPresent(at: fileURL) {
            guard metadata.isRegularFile, metadata.ownerID == geteuid() else {
                throw Sub2APIError.secureStorageFailed
            }
        }

        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw Sub2APIError.secureStorageFailed }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporaryURL.path, fileURL.path) == 0,
                  chmod(fileURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0
            else {
                throw Sub2APIError.secureStorageFailed
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw Sub2APIError.secureStorageFailed
        }
    }

    func delete() throws {
        try ensureSecureDirectory()
        guard let metadata = try metadataIfPresent(at: fileURL) else { return }
        guard metadata.isRegularFile, metadata.ownerID == geteuid() else {
            throw Sub2APIError.secureStorageFailed
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw Sub2APIError.secureStorageFailed
        }
    }

    private func ensureSecureDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            if let metadata = try metadataIfPresent(at: directoryURL) {
                guard metadata.isDirectory, metadata.ownerID == geteuid() else {
                    throw Sub2APIError.secureStorageFailed
                }
            } else {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard chmod(directoryURL.path, mode_t(S_IRWXU)) == 0 else {
                throw Sub2APIError.secureStorageFailed
            }
        } catch let error as Sub2APIError {
            throw error
        } catch {
            throw Sub2APIError.secureStorageFailed
        }
    }

    private func metadataIfPresent(at url: URL) throws -> FileMetadata? {
        var status = stat()
        let result = lstat(url.path, &status)
        if result == 0 {
            let type = status.st_mode & S_IFMT
            return FileMetadata(
                isRegularFile: type == S_IFREG,
                isDirectory: type == S_IFDIR,
                size: Int(status.st_size),
                ownerID: status.st_uid
            )
        }
        if errno == ENOENT { return nil }
        throw Sub2APIError.secureStorageFailed
    }
}

private struct FileMetadata: Sendable {
    let isRegularFile: Bool
    let isDirectory: Bool
    let size: Int
    let ownerID: uid_t
}
