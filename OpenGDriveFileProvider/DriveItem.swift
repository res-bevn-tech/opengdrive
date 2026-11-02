import FileProvider
import OpenGDriveCore
import UniformTypeIdentifiers

/// Finder's view of one `ItemRecord`. A nil record is the drive's root.
final class DriveItem: NSObject, NSFileProviderItem {
    let record: ItemRecord?

    init(_ record: ItemRecord?) {
        self.record = record
    }

    static let root = DriveItem(nil)

    var itemIdentifier: NSFileProviderItemIdentifier {
        record.map { NSFileProviderItemIdentifier($0.id) } ?? .rootContainer
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let record, record.parentID != ItemStore.rootID else { return .rootContainer }
        return NSFileProviderItemIdentifier(record.parentID)
    }

    var filename: String { record?.filename ?? "Google Drive" }

    var contentType: UTType {
        guard let record, !record.isDirectory else { return .folder }
        return UTType(filenameExtension: (filename as NSString).pathExtension) ?? UTType(mimeType: record.mimeType) ?? .data
    }

    /// A Google document's real size is only known once it's exported, so Drive's figure stands in until then.
    /// It must not be zero: the system treats an empty file as already downloaded and never fetches it.
    var documentSize: NSNumber? {
        guard let record, !record.isDirectory else { return nil }
        return NSNumber(value: record.export == nil ? record.size : max(record.size, 1))
    }

    /// Eviction ("Remove Download") is allowed by default since macOS 13, so it isn't listed here.
    var capabilities: NSFileProviderItemCapabilities {
        guard let record else { return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
        if record.isDirectory {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming,
                    .allowsReparenting, .allowsDeleting]
        }
        var caps: NSFileProviderItemCapabilities = [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        if record.canEdit, record.export == nil { caps.insert(.allowsWriting) }
        return caps
    }

    var itemVersion: NSFileProviderItemVersion {
        guard let record else {
            return NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8))
        }
        // "export-" replaces "v" so copies saved empty by builds that reported no size get fetched again.
        let content = record.isDirectory ? "folder" : (record.md5 ?? "export-\(record.driveVersion)")
        let metadata = "\(record.parentID)/\(record.filename)/\(record.modified.timeIntervalSince1970)/\(record.canEdit)"
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data(metadata.utf8))
    }

    var contentModificationDate: Date? { record?.modified }
    var creationDate: Date? { record?.created }
}
