import FileProvider
import OpenGDriveCore
import os

/// Lists a folder, the root, or the working set, and reports changes since a sync anchor.
final class DriveEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let engine: SyncEngine
    private let log = Logger(subsystem: "OpenGDrive", category: "enumerator")

    init(container: NSFileProviderItemIdentifier, engine: SyncEngine) {
        self.container = container
        self.engine = engine
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Unchecked(observer)
        Task {
            do {
                let items = try await self.listing()
                for chunk in stride(from: 0, to: items.count, by: 200) {
                    observer.value.didEnumerate(items[chunk..<min(chunk + 200, items.count)].map(DriveItem.init))
                }
                observer.value.finishEnumerating(upTo: nil)
            } catch {
                self.log.error("Listing failed: \(String(describing: error), privacy: .public)")
                observer.value.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    private func listing() async throws -> [ItemRecord] {
        let store = engine.store
        switch container {
        case .workingSet:
            try await syncQuietly()
            return try store.allItems()
        case .rootContainer:
            try await engine.prepare(folder: ItemStore.rootID)
            return try store.children(of: ItemStore.rootID)
        default:
            try await engine.prepare(folder: container.rawValue)
            guard let folder = try store.item(id: container.rawValue) else { throw NSFileProviderError(.noSuchItem) }
            return try store.children(of: folder.id)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        let observer = Unchecked(observer)
        let since = syncAnchor.seq
        let parent: String? = switch container {
        case .workingSet: nil
        case .rootContainer: ItemStore.rootID
        default: container.rawValue
        }
        let isWorkingSet = container == .workingSet
        Task {
            do {
                if isWorkingSet { try await self.syncQuietly() }
                let changes = try self.engine.store.changes(since: since, parentID: parent)
                if !changes.updated.isEmpty { observer.value.didUpdate(changes.updated.map(DriveItem.init)) }
                if !changes.deleted.isEmpty {
                    observer.value.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier($0) })
                }
                observer.value.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(changes.anchor), moreComing: false)
            } catch {
                observer.value.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor((try? engine.store.currentAnchor()) ?? 0))
    }

    /// Network trouble shouldn't hide what is already known locally. Only sign-in problems are reported.
    private func syncQuietly() async throws {
        do {
            try await engine.sync()
        } catch let e as DriveAPIError where e.kind == .unauthorized {
            throw e
        } catch {
            log.notice("Sync skipped: \(String(describing: error), privacy: .public)")
        }
    }
}

extension NSFileProviderSyncAnchor {
    init(_ seq: Int64) {
        self.init(withUnsafeBytes(of: seq.bigEndian) { Data($0) })
    }

    var seq: Int64 {
        guard rawValue.count == 8 else { return 0 }
        return Int64(bigEndian: rawValue.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
    }
}

/// Carries a non-Sendable File Provider object into a Task. The system allows calling observers from any thread.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Maps engine errors onto the errors Finder knows how to show.
func fileProviderError(_ error: Error) -> Error {
    if error is NSFileProviderError { return error }
    if let e = error as? DriveAPIError {
        switch e.kind {
        case .unauthorized: return NSFileProviderError(.notAuthenticated)
        case .transport, .rateLimited, .server: return NSFileProviderError(.serverUnreachable)
        case .notFound: return NSFileProviderError(.noSuchItem)
        case .rejected: return withMessage(e.message)
        }
    }
    if let e = error as? DriveError {
        switch e {
        case .noSuchItem: return NSFileProviderError(.noSuchItem)
        case .notSignedIn: return NSFileProviderError(.notAuthenticated)
        case .readOnly: return withMessage(e.description)
        }
    }
    if error is URLError { return NSFileProviderError(.serverUnreachable) }
    return error
}

private func withMessage(_ message: String) -> Error {
    NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [NSLocalizedDescriptionKey: message])
}
