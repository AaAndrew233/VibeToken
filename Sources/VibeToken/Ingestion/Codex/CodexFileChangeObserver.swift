import Darwin
import Foundation

final class CodexFileChangeObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.vibetoken.codex-file-events", qos: .utility)
    private let debounceMilliseconds: Int
    private var fileSources: [URL: any DispatchSourceFileSystemObject] = [:]
    private var directorySources: [URL: any DispatchSourceFileSystemObject] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private var watchedFileURLs: Set<URL> = []
    private var watchedDirectoryURLs: Set<URL> = []
    private var onChange: (@Sendable () -> Void)?

    init(debounceMilliseconds: Int) {
        self.debounceMilliseconds = max(20, debounceMilliseconds)
    }

    func watch(fileURL: URL?, onChange: @escaping @Sendable () -> Void) {
        watch(
            fileURLs: fileURL.map { [$0] } ?? [],
            directoryURLs: fileURL.map { [$0.deletingLastPathComponent()] } ?? [],
            onChange: onChange
        )
    }

    func watch(
        fileURLs: [URL],
        directoryURLs: [URL],
        onChange: @escaping @Sendable () -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onChange = onChange
            let newFiles = Set(fileURLs)
            let newDirectories = Set(directoryURLs)
            guard newFiles != self.watchedFileURLs
                    || newDirectories != self.watchedDirectoryURLs else {
                return
            }

            self.cancelSources()
            self.watchedFileURLs = newFiles
            self.watchedDirectoryURLs = newDirectories
            for url in newFiles {
                self.fileSources[url] = self.makeSource(
                    url: url,
                    eventMask: [.write, .extend, .attrib, .rename, .delete]
                )
            }
            for url in newDirectories {
                self.directorySources[url] = self.makeSource(
                    url: url,
                    eventMask: [.write, .rename, .delete]
                )
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.cancelSources()
            self?.watchedFileURLs = []
            self?.watchedDirectoryURLs = []
            self?.onChange = nil
        }
    }

    private func makeSource(
        url: URL,
        eventMask: DispatchSource.FileSystemEvent
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: eventMask,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    private func scheduleChange() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + .milliseconds(debounceMilliseconds),
            execute: workItem
        )
    }

    private func cancelSources() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        fileSources.values.forEach { $0.cancel() }
        directorySources.values.forEach { $0.cancel() }
        fileSources.removeAll()
        directorySources.removeAll()
    }
}
