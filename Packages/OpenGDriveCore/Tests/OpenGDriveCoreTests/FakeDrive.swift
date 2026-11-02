import Foundation
@testable import OpenGDriveCore

/// In-memory Google Drive with a changes feed, enough to drive `SyncEngine` in tests.
final class FakeDrive: DriveAPI, @unchecked Sendable {
    let rootID = "root-id"
    private let lock = NSLock()
    private(set) var files: [String: DriveFile] = [:]
    private(set) var contents: [String: Data] = [:]
    private var log: [DriveChange] = []
    private var nextID = 1

    // MARK: Test helpers

    @discardableResult
    func add(_ name: String, in parent: String? = nil, folder: Bool = false, data: Data = Data("x".utf8),
             mimeType: String? = nil) -> String {
        lock.withLock {
            let id = "f\(nextID)"
            nextID += 1
            var file = DriveFile(
                id: id, name: name, mimeType: mimeType ?? (folder ? GoogleMime.folder : "text/plain"),
                parents: [parent ?? rootID], modifiedTime: Date(timeIntervalSince1970: 1000), version: "1",
                capabilities: .init()
            )
            if !folder, mimeType == nil {
                file.size = String(data.count)
                file.md5Checksum = String(data.hashValue)
                contents[id] = data
            }
            put(file)
            return id
        }
    }

    /// Simulates an edit made on another device.
    func editRemotely(_ id: String, data: Data) {
        lock.withLock {
            var file = files[id]!
            file.md5Checksum = String(data.hashValue)
            file.size = String(data.count)
            file.version = String((Int(file.version ?? "0") ?? 0) + 1)
            contents[id] = data
            put(file)
        }
    }

    func trashRemotely(_ id: String) {
        lock.withLock {
            files[id]?.trashed = true
            log.append(DriveChange(fileId: id, file: files[id]))
        }
    }

    func moveRemotely(_ id: String, to parent: String) {
        lock.withLock {
            var file = files[id]!
            file.parents = [parent]
            put(file)
        }
    }

    private func put(_ file: DriveFile) {
        files[file.id] = file
        log.append(DriveChange(fileId: file.id, file: file))
    }

    // MARK: DriveAPI

    func about() async throws -> DriveAbout { DriveAbout() }
    func rootFolderID() async throws -> String { rootID }
    func startPageToken() async throws -> String { lock.withLock { String(log.count) } }

    func listAll() async throws -> [DriveFile] {
        lock.withLock { files.values.filter { $0.trashed != true } }
    }

    func listChildren(of folderID: String) async throws -> [DriveFile] {
        lock.withLock { files.values.filter { $0.trashed != true && $0.parents?.first == folderID } }
    }

    /// Two changes per page, to exercise paging.
    func changes(pageToken: String) async throws -> DriveChangeList {
        lock.withLock {
            let start = Int(pageToken)!
            let end = min(start + 2, log.count)
            let page = Array(log[start..<end])
            return end < log.count
                ? DriveChangeList(changes: page, nextPageToken: String(end))
                : DriveChangeList(changes: page, newStartPageToken: String(end))
        }
    }

    func file(id: String) async throws -> DriveFile {
        guard let file = lock.withLock({ files[id] }) else { throw DriveAPIError(.notFound, "missing") }
        return file
    }

    func download(id: String, range: ClosedRange<Int64>?, to url: URL) async throws {
        guard let data = lock.withLock({ contents[id] }) else { throw DriveAPIError(.notFound, "missing") }
        try data.write(to: url)
    }

    func export(id: String, mimeType: String, to url: URL) async throws {
        try Data("exported \(mimeType)".utf8).write(to: url)
    }

    func createFolder(name: String, parentID: String) async throws -> DriveFile {
        let id = add(name, in: parentID, folder: true)
        return try await file(id: id)
    }

    func upload(name: String, parentID: String, contents url: URL, modified: Date?) async throws -> DriveFile {
        let id = add(name, in: parentID, data: try Data(contentsOf: url))
        return try await file(id: id)
    }

    func update(id: String, contents url: URL?, name: String?, newParent: String?, oldParent: String?, modified: Date?) async throws -> DriveFile {
        let data = try url.map { try Data(contentsOf: $0) }
        return lock.withLock {
            var file = files[id]!
            if let name { file.name = name }
            if let newParent { file.parents = [newParent] }
            if let data {
                file.md5Checksum = String(data.hashValue)
                file.size = String(data.count)
                contents[id] = data
            }
            file.version = String((Int(file.version ?? "0") ?? 0) + 1)
            put(file)
            return file
        }
    }

    func trash(id: String) async throws { trashRemotely(id) }
    func thumbnail(id: String) async throws -> Data? { nil }
}
