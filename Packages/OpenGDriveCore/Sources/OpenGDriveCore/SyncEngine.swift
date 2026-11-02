import Foundation
import os

/// Keeps `ItemStore` in step with Google Drive and carries Finder's edits back to it.
///
/// Pulling uses the Drive changes feed: one full listing the first time, then only what changed since
/// the saved page token. Drive file IDs are stable, so renames and moves need no bookkeeping.
public actor SyncEngine {
    public nonisolated let store: ItemStore
    private let api: DriveAPI
    private let log = Logger(subsystem: "OpenGDrive", category: "sync")
    private var running: Task<Void, Error>?
    private var conflicts: Set<String> = []
    private var listedFolders: Set<String> = []

    static let pageTokenKey = "pageToken"
    static let rootFolderKey = "rootFolderID"

    public init(api: DriveAPI, store: ItemStore) {
        self.api = api
        self.store = store
    }

    // MARK: Pull

    /// Brings the index up to date. Calls made while a sync runs wait for that one instead of starting another.
    public func sync() async throws {
        if let running { return try await running.value }
        let task = Task { try await self.pull() }
        running = task
        defer { running = nil }
        try await task.value
    }

    /// Before the first full sync finishes, fetches just this folder's children so Finder can show it now.
    /// Listing a large drive takes minutes, so the full sync carries on in the background.
    public func prepare(folder parentID: String) async throws {
        guard try store.meta(Self.pageTokenKey) == nil else { return }
        if running == nil { Task { try? await self.sync() } }
        guard !listedFolders.contains(parentID) else { return }
        let rootID = try await rootFolderID()
        let children = try await api.listChildren(of: driveParent(parentID))
        try store.write { w in
            for file in children where GoogleMime.isSupported(file.mimeType) && file.trashed != true {
                try w.upsert(record(file, rootID: rootID))
            }
        }
        listedFolders.insert(parentID)
    }

    private func pull() async throws {
        if let token = try store.meta(Self.pageTokenKey) {
            try await applyChanges(from: token)
        } else {
            try await fullSync()
        }
    }

    /// Lists the whole drive and makes the index match it.
    func fullSync() async throws {
        // Taken first, so anything that changes during the listing shows up in the next round.
        let token = try await api.startPageToken()
        let rootID = try await api.rootFolderID()
        let files = try await api.listAll()
        let byParent = Dictionary(grouping: files.filter { $0.parents?.first != nil }) { $0.parents![0] }

        // Only what hangs under My Drive. Files shared with you but not added to My Drive are left out.
        var keep: [ItemRecord] = []
        var queue = [rootID]
        while let folder = queue.popLast() {
            // Oldest first, so the original keeps its name when Drive holds duplicates.
            let children = (byParent[folder] ?? []).sorted {
                ($0.createdTime ?? .distantPast, $0.id) < ($1.createdTime ?? .distantPast, $1.id)
            }
            for file in children where GoogleMime.isSupported(file.mimeType) && file.trashed != true {
                keep.append(record(file, rootID: rootID))
                if file.isFolder { queue.append(file.id) }
            }
        }
        try store.write { w in
            let gone = try w.allIDs().subtracting(keep.map(\.id))
            for id in gone { try w.delete(id: id) }
            // Parents before children, so uniquing sees the final siblings.
            for item in keep { try w.upsert(item) }
            try w.setMeta(Self.rootFolderKey, rootID)
            try w.setMeta(Self.pageTokenKey, token)
        }
        log.info("Full sync: \(keep.count) items")
    }

    private func applyChanges(from start: String) async throws {
        let rootID = try await rootFolderID()
        var token = start
        while true {
            let page = try await api.changes(pageToken: token)
            var newFolders: [String] = []
            try store.write { w in
                for change in page.changes where change.changeType != "drive" {
                    guard let id = change.fileId ?? change.file?.id else { continue }
                    guard change.removed != true, let file = change.file, file.trashed != true,
                          GoogleMime.isSupported(file.mimeType),
                          let parent = file.parents?.first,
                          try parent == rootID || w.item(id: parent) != nil
                    else {
                        // Deleted, trashed, unsupported, or moved somewhere outside My Drive.
                        try w.delete(id: id)
                        continue
                    }
                    let isNew = try w.item(id: id) == nil
                    try w.upsert(record(file, rootID: rootID))
                    if isNew, file.isFolder { newFolders.append(file.id) }
                }
                if let next = page.newStartPageToken { try w.setMeta(Self.pageTokenKey, next) }
            }
            // A folder restored or moved in from elsewhere arrives without its contents.
            for folder in newFolders { try await fillFolder(folder, rootID: rootID) }
            if let next = page.nextPageToken {
                token = next
            } else {
                break
            }
        }
    }

    private func fillFolder(_ folderID: String, rootID: String) async throws {
        let children = try await api.listChildren(of: folderID).filter { GoogleMime.isSupported($0.mimeType) }
        var subfolders: [String] = []
        try store.write { w in
            for file in children where try w.item(id: file.id) == nil {
                try w.upsert(record(file, rootID: rootID))
                if file.isFolder { subfolders.append(file.id) }
            }
        }
        for sub in subfolders { try await fillFolder(sub, rootID: rootID) }
    }

    private func rootFolderID() async throws -> String {
        if let saved = try store.meta(Self.rootFolderKey) { return saved }
        let id = try await api.rootFolderID()
        try store.write { try $0.setMeta(Self.rootFolderKey, id) }
        return id
    }

    /// Drive's parent ID for an index parent ID.
    private func driveParent(_ parentID: String) async throws -> String {
        parentID == ItemStore.rootID ? try await rootFolderID() : parentID
    }

    nonisolated func record(_ file: DriveFile, rootID: String) -> ItemRecord {
        let parent = file.parents?.first
        let now = Date()
        return ItemRecord(
            id: file.id,
            parentID: parent == rootID || parent == nil ? ItemStore.rootID : parent!,
            name: file.name,
            isDirectory: file.isFolder,
            mimeType: file.mimeType,
            size: Int64(file.size ?? "") ?? 0,
            modified: file.modifiedTime ?? now,
            created: file.createdTime ?? file.modifiedTime ?? now,
            md5: file.md5Checksum,
            driveVersion: file.version ?? "0",
            canEdit: file.capabilities?.canEdit ?? true
        )
    }

    private func save(_ file: DriveFile) async throws -> ItemRecord {
        let rootID = try await rootFolderID()
        return try store.write { try $0.upsert(record(file, rootID: rootID)) }
    }

    // MARK: Contents

    /// Downloads the file, or exports a Google document, into a new temporary file.
    public func download(id: String, range: ClosedRange<Int64>? = nil) async throws -> (URL, ItemRecord) {
        guard let item = try store.item(id: id) else { throw DriveError.noSuchItem }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            if let export = item.export {
                try await api.export(id: id, mimeType: export.mimeType, to: url)
            } else if item.size == 0 {
                try Data().write(to: url)
            } else {
                try await api.download(id: id, range: range, to: url)
            }
        } catch let e as DriveAPIError where e.kind == .notFound {
            try store.write { try $0.delete(id: id) }
            throw DriveError.noSuchItem
        }
        return (url, item)
    }

    public func thumbnail(id: String) async -> Data? {
        try? await api.thumbnail(id: id)
    }

    // MARK: Push

    public func createFolder(parentID: String, name: String) async throws -> ItemRecord {
        let file = try await api.createFolder(name: name, parentID: driveParent(parentID))
        return try await save(file)
    }

    /// The Drive item a create from Finder refers to, if Drive already has it.
    ///
    /// The system re-sends items it already had as creates, for instance after losing its own database.
    /// Uploading those again would duplicate them, so a folder, or a file of the same size, with the
    /// same name is taken to be the same item. `askDrive` also checks Drive when the index lacks it.
    public func existing(named name: String, in parentID: String, isFolder: Bool, size: Int64?, askDrive: Bool) async throws -> ItemRecord? {
        func matches(_ item: ItemRecord, _ itemName: String) -> Bool {
            itemName == name && item.isDirectory == isFolder && (isFolder || size == nil || item.size == size)
        }
        if let found = try store.children(of: parentID).first(where: { matches($0, $0.filename) }) { return found }
        guard askDrive else { return nil }
        let rootID = try await rootFolderID()
        let children = try await api.listChildren(of: driveParent(parentID))
        guard let file = children.first(where: {
            GoogleMime.isSupported($0.mimeType) && $0.trashed != true && GoogleMime.exports[$0.mimeType] == nil
                && matches(record($0, rootID: rootID), $0.name)
        }) else { return nil }
        return try store.write { try $0.upsert(record(file, rootID: rootID)) }
    }

    public func createFile(parentID: String, name: String, contents: URL, modified: Date?) async throws -> ItemRecord {
        let file = try await api.upload(name: name, parentID: driveParent(parentID), contents: contents, modified: modified)
        return try await save(file)
    }

    /// Applies a rename, move and/or new contents from Finder.
    ///
    /// If the file changed in Drive since this Mac last saw it, Drive's version is kept and the local
    /// edit is uploaded next to it as a conflict copy. `takeConflict` then tells the caller to refetch.
    public func modify(id: String, newName: String?, newParentID: String?, contents: URL?, modified: Date?) async throws -> ItemRecord {
        guard let item = try store.item(id: id) else { throw DriveError.noSuchItem }
        if contents != nil, item.export != nil { throw DriveError.readOnly(item.filename) }

        var name = newName
        if let given = newName, let export = item.export, given.hasSuffix("." + export.fileExtension) {
            name = String(given.dropLast(export.fileExtension.count + 1))
        }
        if name == item.name || newName == item.filename { name = nil }
        var parent: String?
        if let newParentID, newParentID != item.parentID { parent = try await driveParent(newParentID) }
        let oldParent = try await driveParent(item.parentID)

        if let contents {
            let remote = try await api.file(id: id)
            if let known = item.md5, let current = remote.md5Checksum, known != current {
                let copy = Self.conflictName(newName ?? item.filename)
                let target = try await driveParent(newParentID ?? item.parentID)
                _ = try await save(api.upload(name: copy, parentID: target, contents: contents, modified: modified))
                conflicts.insert(id)
                log.notice("Conflict on \(id, privacy: .public), saved local copy as \(copy, privacy: .private)")
                return try await save(remote)
            }
        }
        guard name != nil || parent != nil || contents != nil else { return item }
        let file = try await api.update(
            id: id, contents: contents, name: name, newParent: parent, oldParent: parent == nil ? nil : oldParent,
            modified: contents == nil ? nil : modified
        )
        return try await save(file)
    }

    /// True once after `modify` kept Drive's version because of a conflict.
    public func takeConflict(id: String) -> Bool {
        conflicts.remove(id) != nil
    }

    /// Moves the item to the Google Drive trash, so it can be restored for 30 days.
    public func delete(id: String) async throws {
        do {
            try await api.trash(id: id)
        } catch let e as DriveAPIError where e.kind == .notFound {
            // Already gone.
        }
        try store.write { try $0.delete(id: id) }
    }

    static func conflictName(_ filename: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = "conflict from Mac \(f.string(from: date))"
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        return ext.isEmpty ? "\(filename) (\(stamp))" : "\(stem) (\(stamp)).\(ext)"
    }
}
