import Foundation
import GRDB

/// One file or folder in the drive. The ID is Google Drive's own file ID, which never changes.
public struct ItemRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "items"

    public var id: String
    /// `ItemStore.rootID` for items directly in My Drive.
    public var parentID: String
    /// The name in Google Drive.
    public var name: String
    /// The name Finder shows. Unique within the folder, since Drive allows duplicate names and Finder doesn't.
    public var filename: String
    public var isDirectory: Bool
    public var mimeType: String
    public var size: Int64
    public var modified: Date
    public var created: Date
    /// MD5 of the contents for regular files, nil for folders and Google documents.
    public var md5: String?
    /// Drive's version counter. Used as the content version of Google documents, which have no MD5.
    public var driveVersion: String
    public var canEdit: Bool
    /// Change sequence number, used as the File Provider sync anchor.
    public var seq: Int64

    public init(
        id: String, parentID: String, name: String, filename: String? = nil, isDirectory: Bool, mimeType: String,
        size: Int64, modified: Date, created: Date, md5: String?, driveVersion: String, canEdit: Bool, seq: Int64 = 0
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.filename = filename ?? name
        self.isDirectory = isDirectory
        self.mimeType = mimeType
        self.size = size
        self.modified = modified
        self.created = created
        self.md5 = md5
        self.driveVersion = driveVersion
        self.canEdit = canEdit
        self.seq = seq
    }

    /// The Office format a Google document is exported as, or nil for regular files.
    public var export: GoogleMime.Export? { GoogleMime.exports[mimeType] }

    /// The name before uniquing, with the export extension for Google documents.
    var preferredFilename: String {
        let base = name.replacingOccurrences(of: "/", with: ":")
        guard let export else { return base }
        return base + "." + export.fileExtension
    }

    /// Same item, ignoring the bookkeeping columns.
    func sameContent(as other: ItemRecord) -> Bool {
        var a = self, b = other
        a.seq = 0; b.seq = 0
        a.filename = ""; b.filename = ""
        return a == b
    }
}

public struct ChangeSet: Sendable {
    public let updated: [ItemRecord]
    public let deleted: [String]
    public let anchor: Int64
}

/// SQLite index of everything in the drive. Owned by the File Provider extension.
public final class ItemStore: Sendable {
    /// Raw value of `NSFileProviderItemIdentifier.rootContainer`.
    public static let rootID = "NSFileProviderRootContainerItemIdentifier"

    private let db: DatabaseQueue

    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try DatabaseQueue(path: url.path)
        } else {
            db = try DatabaseQueue()
        }
        try migrator.migrate(db)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("parentID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("isDirectory", .boolean).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("modified", .datetime).notNull()
                t.column("created", .datetime).notNull()
                t.column("md5", .text)
                t.column("driveVersion", .text).notNull()
                t.column("canEdit", .boolean).notNull()
                t.column("seq", .integer).notNull().indexed()
            }
            try db.create(table: "tombstones") { t in
                t.primaryKey("id", .text)
                t.column("parentID", .text).notNull()
                t.column("seq", .integer).notNull().indexed()
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // Builds before this reported Google documents as empty, so the system kept 0-byte copies.
        // Sending them again with their new content version makes it fetch them.
        m.registerMigration("v2-resend-google-documents") { db in
            var seq = try Writer.seq(in: db)
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM items WHERE isDirectory = 0 AND mimeType LIKE 'application/vnd.google-apps.%'
                """)
            for id in ids {
                seq += 1
                try db.execute(sql: "UPDATE items SET seq = ? WHERE id = ?", arguments: [seq, id])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('seq', ?)", arguments: [String(seq)])
        }
        return m
    }

    // MARK: Reads

    public func item(id: String) throws -> ItemRecord? {
        try db.read { try ItemRecord.fetchOne($0, key: id) }
    }

    public func children(of parentID: String) throws -> [ItemRecord] {
        try db.read { try ItemRecord.filter(Column("parentID") == parentID).order(Column("filename")).fetchAll($0) }
    }

    public func allItems() throws -> [ItemRecord] {
        try db.read { try ItemRecord.fetchAll($0) }
    }

    public func count() throws -> Int {
        try db.read { try ItemRecord.fetchCount($0) }
    }

    public func currentAnchor() throws -> Int64 {
        try db.read { try Writer.seq(in: $0) }
    }

    public func meta(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    /// Items and deletions after `anchor`. Pass `parentID` to limit to one folder.
    public func changes(since anchor: Int64, parentID: String? = nil) throws -> ChangeSet {
        try db.read { db in
            var updated = ItemRecord.filter(Column("seq") > anchor)
            var deleted = Table("tombstones").filter(Column("seq") > anchor)
            if let parentID {
                updated = updated.filter(Column("parentID") == parentID)
                deleted = deleted.filter(Column("parentID") == parentID)
            }
            let ids = try String.fetchAll(db, deleted.select(Column("id")))
            return ChangeSet(updated: try updated.fetchAll(db), deleted: ids, anchor: try Writer.seq(in: db))
        }
    }

    // MARK: Writes

    public func write<T>(_ body: (Writer) throws -> T) throws -> T {
        try db.write { db in try body(Writer(db: db)) }
    }

    /// Write access inside one transaction. Every change gets the next sequence number.
    public struct Writer {
        let db: Database

        static func seq(in db: Database) throws -> Int64 {
            Int64(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'seq'") ?? "0") ?? 0
        }

        public func nextSeq() throws -> Int64 {
            let next = try Self.seq(in: db) + 1
            try setMeta("seq", String(next))
            return next
        }

        public func setMeta(_ key: String, _ value: String?) throws {
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            }
        }

        public func meta(_ key: String) throws -> String? {
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }

        public func item(id: String) throws -> ItemRecord? {
            try ItemRecord.fetchOne(db, key: id)
        }

        public func allIDs() throws -> Set<String> {
            Set(try String.fetchAll(db, sql: "SELECT id FROM items"))
        }

        /// Saves the item unless nothing changed. Returns the stored version.
        @discardableResult
        public func upsert(_ item: ItemRecord) throws -> ItemRecord {
            var item = item
            let existing = try self.item(id: item.id)
            if let existing, existing.sameContent(as: item) { return existing }
            item.filename = try uniqueFilename(for: item, keeping: existing)
            item.seq = try nextSeq()
            try item.save(db)
            try db.execute(sql: "DELETE FROM tombstones WHERE id = ?", arguments: [item.id])
            return item
        }

        /// Removes the item and everything inside it.
        public func delete(id: String) throws {
            guard let item = try self.item(id: id) else { return }
            for child in try ItemRecord.filter(Column("parentID") == id).fetchAll(db) {
                try delete(id: child.id)
            }
            let seq = try nextSeq()
            _ = try ItemRecord.deleteOne(db, key: id)
            try db.execute(
                sql: "INSERT OR REPLACE INTO tombstones (id, parentID, seq) VALUES (?, ?, ?)",
                arguments: [id, item.parentID, seq]
            )
        }

        /// Keeps the current Finder name when it's still right, otherwise adds " 2", " 3"… before the extension.
        private func uniqueFilename(for item: ItemRecord, keeping existing: ItemRecord?) throws -> String {
            let wanted = item.preferredFilename
            let taken = Set(try String.fetchAll(
                db, sql: "SELECT filename FROM items WHERE parentID = ? AND id != ?", arguments: [item.parentID, item.id]
            ).map { $0.lowercased() })
            if let existing, existing.parentID == item.parentID, existing.preferredFilename == wanted,
               !taken.contains(existing.filename.lowercased()) {
                return existing.filename
            }
            if !taken.contains(wanted.lowercased()) { return wanted }
            let ext = (wanted as NSString).pathExtension
            let stem = ext.isEmpty || item.isDirectory ? wanted : (wanted as NSString).deletingPathExtension
            var n = 2
            while true {
                let candidate = ext.isEmpty || item.isDirectory ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                if !taken.contains(candidate.lowercased()) { return candidate }
                n += 1
            }
        }
    }
}
