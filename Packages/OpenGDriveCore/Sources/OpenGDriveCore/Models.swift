import Foundation

/// A file or folder as Google Drive API v3 returns it. Only the fields in `DriveFile.fields` are filled.
public struct DriveFile: Codable, Sendable, Equatable {
    public struct Capabilities: Codable, Sendable, Equatable {
        public var canEdit: Bool?
        public var canRename: Bool?
        public var canTrash: Bool?
        public var canAddChildren: Bool?
        public var canMoveItemWithinDrive: Bool?

        public init(canEdit: Bool? = true, canRename: Bool? = true, canTrash: Bool? = true,
                    canAddChildren: Bool? = true, canMoveItemWithinDrive: Bool? = true) {
            self.canEdit = canEdit
            self.canRename = canRename
            self.canTrash = canTrash
            self.canAddChildren = canAddChildren
            self.canMoveItemWithinDrive = canMoveItemWithinDrive
        }
    }

    public var id: String
    public var name: String
    public var mimeType: String
    public var parents: [String]?
    /// Drive sends int64 values as strings.
    public var size: String?
    public var modifiedTime: Date?
    public var createdTime: Date?
    public var md5Checksum: String?
    /// Increases on every change to the file, contents or metadata.
    public var version: String?
    public var trashed: Bool?
    public var capabilities: Capabilities?

    /// Partial-response field list used for every file request.
    public static let fields =
        "id,name,mimeType,parents,size,modifiedTime,createdTime,md5Checksum,version,trashed," +
        "capabilities(canEdit,canRename,canTrash,canAddChildren,canMoveItemWithinDrive)"

    public init(
        id: String, name: String, mimeType: String, parents: [String]? = nil, size: String? = nil,
        modifiedTime: Date? = nil, createdTime: Date? = nil, md5Checksum: String? = nil, version: String? = nil,
        trashed: Bool? = nil, capabilities: Capabilities? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.parents = parents
        self.size = size
        self.modifiedTime = modifiedTime
        self.createdTime = createdTime
        self.md5Checksum = md5Checksum
        self.version = version
        self.trashed = trashed
        self.capabilities = capabilities
    }

    public var isFolder: Bool { mimeType == GoogleMime.folder }
}

public struct DriveFileList: Codable, Sendable {
    public var files: [DriveFile]
    public var nextPageToken: String?
}

public struct DriveChange: Codable, Sendable {
    public var fileId: String?
    public var removed: Bool?
    public var file: DriveFile?
    /// "file" or "drive". Shared drive changes are ignored.
    public var changeType: String?

    public init(fileId: String?, removed: Bool? = nil, file: DriveFile? = nil, changeType: String? = "file") {
        self.fileId = fileId
        self.removed = removed
        self.file = file
        self.changeType = changeType
    }
}

public struct DriveChangeList: Codable, Sendable {
    public var changes: [DriveChange]
    /// Set when there are more pages for this round.
    public var nextPageToken: String?
    /// Set on the last page: where the next round starts.
    public var newStartPageToken: String?

    public init(changes: [DriveChange], nextPageToken: String? = nil, newStartPageToken: String? = nil) {
        self.changes = changes
        self.nextPageToken = nextPageToken
        self.newStartPageToken = newStartPageToken
    }
}

public struct DriveAbout: Codable, Sendable, Equatable {
    public struct User: Codable, Sendable, Equatable {
        public var displayName: String?
        public var emailAddress: String?
    }

    public struct Quota: Codable, Sendable, Equatable {
        /// Missing for unlimited plans.
        public var limit: String?
        public var usage: String?
    }

    public var user: User?
    public var storageQuota: Quota?

    public var usedBytes: Int64 { Int64(storageQuota?.usage ?? "") ?? 0 }
    public var limitBytes: Int64? { storageQuota?.limit.flatMap { Int64($0) } }
}

/// Google's own document types. They have no bytes of their own, so they're shown as Office exports.
public enum GoogleMime {
    public static let folder = "application/vnd.google-apps.folder"
    public static let prefix = "application/vnd.google-apps."

    public struct Export: Sendable, Equatable {
        public let mimeType: String
        public let fileExtension: String
    }

    /// Google types that can be shown in Finder, and what they're exported as. Forms, Sites, shortcuts
    /// and the like have no useful file form and are left out of the drive.
    public static let exports: [String: Export] = [
        "application/vnd.google-apps.document": Export(
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", fileExtension: "docx"
        ),
        "application/vnd.google-apps.spreadsheet": Export(
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileExtension: "xlsx"
        ),
        "application/vnd.google-apps.presentation": Export(
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", fileExtension: "pptx"
        ),
        "application/vnd.google-apps.drawing": Export(mimeType: "application/pdf", fileExtension: "pdf"),
    ]

    /// True for folders, regular files and the Google types listed in `exports`.
    public static func isSupported(_ mimeType: String) -> Bool {
        mimeType == folder || !mimeType.hasPrefix(prefix) || exports[mimeType] != nil
    }
}

/// Names that stay on the Mac and are never uploaded.
public enum Reserved {
    public static func isIgnored(filename: String) -> Bool {
        filename == ".DS_Store" || filename.hasPrefix("._") || filename == ".localized"
    }
}

/// Errors the sync engine raises itself.
public enum DriveError: Error, CustomStringConvertible, Sendable {
    case noSuchItem
    case notSignedIn
    case readOnly(String)

    public var description: String {
        switch self {
        case .noSuchItem: "The item no longer exists in Google Drive."
        case .notSignedIn: "Sign in to Google Drive from the menu bar."
        case let .readOnly(name): "\(name) is a Google document. Edit it in the browser; it's shown here as a read-only export."
        }
    }
}

extension JSONDecoder {
    /// Decodes Drive's RFC 3339 timestamps, with or without fractional seconds.
    static let drive: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            if let date = RFC3339.parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date \(text)"))
        }
        return decoder
    }()
}

enum RFC3339 {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
