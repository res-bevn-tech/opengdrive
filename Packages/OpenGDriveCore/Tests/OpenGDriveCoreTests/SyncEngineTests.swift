import Foundation
@testable import OpenGDriveCore
import Testing

@Suite struct SyncEngineTests {
    let drive = FakeDrive()
    let engine: SyncEngine

    init() throws {
        engine = SyncEngine(api: drive, store: try ItemStore(url: nil))
    }

    var store: ItemStore { engine.store }

    func names(in parent: String = ItemStore.rootID) throws -> [String] {
        try store.children(of: parent).map(\.filename)
    }

    @Test func firstSyncListsOnlyMyDrive() async throws {
        let docs = drive.add("Docs", folder: true)
        drive.add("a.txt", in: docs)
        drive.add("shared.txt", in: "someone-elses-folder")
        drive.add("Form", mimeType: "application/vnd.google-apps.form")
        drive.add("Plan", mimeType: "application/vnd.google-apps.document")

        try await engine.sync()

        #expect(try names() == ["Docs", "Plan.docx"])
        #expect(try names(in: docs) == ["a.txt"])
    }

    @Test func folderShowsBeforeTheFullSyncFinishes() async throws {
        let docs = drive.add("Docs", folder: true)
        drive.add("a.txt", in: docs)
        drive.add("b.txt")

        try await engine.prepare(folder: ItemStore.rootID)
        #expect(try names() == ["Docs", "b.txt"])
        try await engine.prepare(folder: docs)
        #expect(try names(in: docs) == ["a.txt"])

        // The background full sync then agrees with what was shown.
        try await engine.sync()
        #expect(try names() == ["Docs", "b.txt"])
        #expect(try names(in: docs) == ["a.txt"])
    }

    @Test func duplicateNamesGetUniqueFilenames() async throws {
        drive.add("report.pdf")
        drive.add("report.pdf")
        drive.add("Report.pdf")
        try await engine.sync()
        #expect(try names() == ["Report 3.pdf", "report 2.pdf", "report.pdf"])
    }

    @Test func remoteChangesArriveThroughTheFeed() async throws {
        let docs = drive.add("Docs", folder: true)
        let a = drive.add("a.txt", in: docs)
        let b = drive.add("b.txt")
        try await engine.sync()
        let anchor = try store.currentAnchor()

        drive.editRemotely(a, data: Data("new".utf8))
        drive.trashRemotely(b)
        drive.add("c.txt", in: docs)
        try await engine.sync()

        #expect(try names() == ["Docs"])
        #expect(try names(in: docs) == ["a.txt", "c.txt"])
        let changes = try store.changes(since: anchor)
        #expect(changes.deleted == [b])
        #expect(Set(changes.updated.map(\.filename)) == ["a.txt", "c.txt"])
    }

    @Test func trashingAFolderRemovesItsContents() async throws {
        let docs = drive.add("Docs", folder: true)
        let a = drive.add("a.txt", in: docs)
        try await engine.sync()
        drive.trashRemotely(docs)
        try await engine.sync()
        #expect(try store.item(id: a) == nil)
        #expect(try store.count() == 0)
    }

    @Test func folderMovedInBringsItsContents() async throws {
        let outside = "someone-elses-folder"
        let folder = drive.add("Incoming", in: outside, folder: true)
        drive.add("inside.txt", in: folder)
        try await engine.sync()
        #expect(try store.count() == 0)

        drive.moveRemotely(folder, to: drive.rootID)
        try await engine.sync()
        #expect(try names(in: folder) == ["inside.txt"])
    }

    @Test func localEditsUploadRenameAndMove() async throws {
        let docs = drive.add("Docs", folder: true)
        try await engine.sync()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: tmp)

        let created = try await engine.createFile(parentID: ItemStore.rootID, name: "note.txt", contents: tmp, modified: nil)
        #expect(drive.files[created.id]?.parents == [drive.rootID])

        let moved = try await engine.modify(id: created.id, newName: "renamed.txt", newParentID: docs, contents: nil, modified: nil)
        #expect(moved.parentID == docs)
        #expect(drive.files[created.id]?.name == "renamed.txt")

        try await engine.delete(id: created.id)
        #expect(drive.files[created.id]?.trashed == true)
        #expect(try store.item(id: created.id) == nil)

        // Our own edits come back through the feed without disturbing anything.
        try await engine.sync()
        #expect(try names(in: docs) == [])
    }

    @Test func recreatedItemsAreMatchedInsteadOfUploadedAgain() async throws {
        let docs = drive.add("Docs", folder: true)
        let a = drive.add("a.txt", in: docs, data: Data("abc".utf8))
        try await engine.prepare(folder: ItemStore.rootID)

        #expect(try await engine.existing(named: "Docs", in: ItemStore.rootID, isFolder: true, size: nil, askDrive: false)?.id == docs)
        // Not indexed yet, so only Drive knows it.
        #expect(try await engine.existing(named: "a.txt", in: docs, isFolder: false, size: 3, askDrive: false) == nil)
        #expect(try await engine.existing(named: "a.txt", in: docs, isFolder: false, size: 3, askDrive: true)?.id == a)
        // A different file that happens to share the name is still uploaded.
        #expect(try await engine.existing(named: "a.txt", in: docs, isFolder: false, size: 5, askDrive: true) == nil)
    }

    @Test func conflictingEditKeepsBothVersions() async throws {
        let id = drive.add("todo.txt", data: Data("v1".utf8))
        try await engine.sync()
        drive.editRemotely(id, data: Data("from phone".utf8))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("from mac".utf8).write(to: tmp)
        _ = try await engine.modify(id: id, newName: nil, newParentID: nil, contents: tmp, modified: nil)

        #expect(await engine.takeConflict(id: id))
        #expect(drive.contents[id] == Data("from phone".utf8))
        let copies = drive.files.values.filter { $0.name.hasPrefix("todo (conflict from Mac") }
        #expect(copies.count == 1)
        #expect(drive.contents[copies[0].id] == Data("from mac".utf8))
    }

    @Test func googleDocsExportAndAreReadOnly() async throws {
        let id = drive.add("Plan", mimeType: "application/vnd.google-apps.document")
        try await engine.sync()
        let (url, _) = try await engine.download(id: id)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("exported application/vnd.openxmlformats"))

        // Renaming in Finder keeps the extension off the Drive name.
        _ = try await engine.modify(id: id, newName: "Roadmap.docx", newParentID: nil, contents: nil, modified: nil)
        #expect(drive.files[id]?.name == "Roadmap")
        await #expect(throws: DriveError.self) {
            try await engine.modify(id: id, newName: nil, newParentID: nil, contents: url, modified: nil)
        }
    }

    @Test func conflictNames() {
        let local = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4))!
        #expect(SyncEngine.conflictName("a.txt", date: local) == "a (conflict from Mac 2026-01-02 03.04).txt")
        #expect(SyncEngine.conflictName("Makefile", date: local) == "Makefile (conflict from Mac 2026-01-02 03.04)")
    }
}
