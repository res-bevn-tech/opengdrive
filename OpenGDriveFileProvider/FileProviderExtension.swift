import FileProvider
import OpenGDriveCore
import os
import UniformTypeIdentifiers

/// Entry point the system loads for the Google Drive domain. All real work happens in `SyncEngine`.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let manager: NSFileProviderManager?
    private let lock = NSLock()
    private var cachedEngine: SyncEngine?
    let log = Logger(subsystem: "OpenGDrive", category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        manager = NSFileProviderManager(for: domain)
        super.init()
    }

    func invalidate() {}

    func engine() throws -> SyncEngine {
        if AppConfig.paused { throw NSFileProviderError(.serverUnreachable) }
        return try lock.withLock {
            if let cachedEngine { return cachedEngine }
            guard CredentialStore().read() != nil else { throw NSFileProviderError(.notAuthenticated) }
            let db = AppConfig.sharedContainer?
                .appendingPathComponent("Library/Application Support/OpenGDrive", isDirectory: true)
                .appendingPathComponent("\(domain.identifier.rawValue).sqlite")
            let tokens = TokenProvider(oauth: GoogleOAuth(clientID: AppConfig.oauthClientID))
            let engine = SyncEngine(api: GoogleDriveClient(tokens: tokens), store: try ItemStore(url: db))
            cachedEngine = engine
            return engine
        }
    }

    // MARK: Items

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        if identifier == .rootContainer {
            completionHandler(DriveItem.root, nil)
        } else {
            do {
                guard let record = try engine().store.item(id: identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
                completionHandler(DriveItem(record), nil)
            } catch {
                completionHandler(nil, fileProviderError(error))
            }
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // Deleting moves items to the Google Drive trash, which isn't mirrored locally.
        if containerItemIdentifier == .trashContainer { return EmptyEnumerator() }
        return DriveEnumerator(container: containerItemIdentifier, engine: try engine())
    }

    // MARK: Contents

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        Task {
            do {
                var (downloaded, record) = try await self.engine().download(id: itemIdentifier.rawValue)
                let url = try self.moveToTemporaryDirectory(downloaded)
                if record.export != nil {
                    record.size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
                done.value(url, DriveItem(record), nil)
            } catch {
                self.log.error("Download failed: \(String(describing: error), privacy: .public)")
                done.value(nil, nil, fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    /// The system clones the file from here, so it must live on the same volume as the domain.
    func moveToTemporaryDirectory(_ url: URL) throws -> URL {
        guard let dir = try manager?.temporaryDirectoryURL() else { return url }
        let target = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    // MARK: Changes from Finder

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        let name = itemTemplate.filename
        let parent = itemTemplate.parentItemIdentifier.storeID
        let type = itemTemplate.contentType ?? .data
        let modified = itemTemplate.contentModificationDate ?? nil
        let contents = url
        Task {
            do {
                if Reserved.isIgnored(filename: name) || type.conforms(to: .symbolicLink) {
                    throw NSFileProviderError(.excludedFromSync)
                }
                let engine = try self.engine()
                let isFolder = type.conforms(to: .folder) || type.conforms(to: .directory)
                let size = isFolder ? nil : (itemTemplate.documentSize ?? nil).map { $0.int64Value }
                if let existing = try await engine.existing(
                    named: name, in: parent, isFolder: isFolder, size: size, askDrive: options.contains(.mayAlreadyExist)
                ) {
                    done.value(DriveItem(existing), [], false, nil)
                    progress.completedUnitCount = 1
                    return
                }
                let record: ItemRecord
                if isFolder {
                    record = try await engine.createFolder(parentID: parent, name: name)
                } else {
                    record = try await engine.createFile(
                        parentID: parent, name: name, contents: contents ?? Self.emptyFile(), modified: modified
                    )
                }
                done.value(DriveItem(record), [], false, nil)
            } catch {
                self.log.error("Create failed: \(String(describing: error), privacy: .public)")
                done.value(nil, [], false, fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        let id = item.itemIdentifier.rawValue
        let newName = changedFields.contains(.filename) ? item.filename : nil
        let newParent = changedFields.contains(.parentItemIdentifier) ? item.parentItemIdentifier.storeID : nil
        let contents = changedFields.contains(.contents) ? newContents : nil
        let modified = changedFields.contains(.contentModificationDate) ? (item.contentModificationDate ?? nil) : nil
        Task {
            do {
                let engine = try self.engine()
                let record = try await engine.modify(
                    id: id, newName: newName, newParentID: newParent, contents: contents, modified: modified
                )
                // After a conflict the item holds Drive's version and the local edit lives on as the
                // conflict copy, so macOS must download the original again.
                let refetch = await engine.takeConflict(id: id)
                done.value(DriveItem(record), [], refetch, nil)
            } catch {
                self.log.error("Modify failed: \(String(describing: error), privacy: .public)")
                done.value(nil, [], false, fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        Task {
            do {
                try await self.engine().delete(id: identifier.rawValue)
                done.value(nil)
            } catch {
                self.log.error("Delete failed: \(String(describing: error), privacy: .public)")
                done.value(fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    private static func emptyFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        return url
    }
}

// MARK: Thumbnails

/// Icon view thumbnails from Drive's own previews, so nothing has to download.
extension FileProviderExtension: NSFileProviderThumbnailing {
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let each = Unchecked(perThumbnailCompletionHandler)
        let done = Unchecked(completionHandler)
        Task {
            let engine = try? self.engine()
            for id in itemIdentifiers {
                each.value(id, await engine?.thumbnail(id: id.rawValue), nil)
                progress.completedUnitCount += 1
            }
            done.value(nil)
        }
        return progress
    }
}

extension NSFileProviderItemIdentifier {
    /// The ID used in `ItemStore`, where the root has its own fixed name.
    var storeID: String { self == .rootContainer ? ItemStore.rootID : rawValue }
}

/// Lists nothing and never changes. Used for the trash.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Int64(0)))
    }
}
