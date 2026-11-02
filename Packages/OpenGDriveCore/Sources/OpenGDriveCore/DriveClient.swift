import Foundation
import os

public struct DriveAPIError: Error, CustomStringConvertible, Sendable {
    public enum Kind: Sendable { case unauthorized, notFound, rateLimited, server, transport, rejected }
    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

/// Everything the sync engine needs from Google Drive. `GoogleDriveClient` talks to the real API;
/// tests use an in-memory fake.
public protocol DriveAPI: Sendable {
    func about() async throws -> DriveAbout
    /// ID of the "My Drive" root folder.
    func rootFolderID() async throws -> String
    func startPageToken() async throws -> String
    /// Every non-trashed file the user can see, in pages.
    func listAll() async throws -> [DriveFile]
    func listChildren(of folderID: String) async throws -> [DriveFile]
    func changes(pageToken: String) async throws -> DriveChangeList
    func file(id: String) async throws -> DriveFile
    func download(id: String, range: ClosedRange<Int64>?, to url: URL) async throws
    func export(id: String, mimeType: String, to url: URL) async throws
    func createFolder(name: String, parentID: String) async throws -> DriveFile
    func upload(name: String, parentID: String, contents: URL, modified: Date?) async throws -> DriveFile
    /// Changes any of contents, name and parent. Nil means unchanged.
    func update(id: String, contents: URL?, name: String?, newParent: String?, oldParent: String?, modified: Date?) async throws -> DriveFile
    func trash(id: String) async throws
    func thumbnail(id: String) async throws -> Data?
}

/// Google Drive API v3 over URLSession, with token refresh and retries.
public final class GoogleDriveClient: DriveAPI, @unchecked Sendable {
    static let api = "https://www.googleapis.com/drive/v3"
    static let uploadAPI = "https://www.googleapis.com/upload/drive/v3"

    private let tokens: TokenProvider
    private let session: URLSession
    private let log = Logger(subsystem: "OpenGDrive", category: "api")

    public init(tokens: TokenProvider, session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    // MARK: Reads

    public func about() async throws -> DriveAbout {
        try await json(get("about", ["fields": "user(displayName,emailAddress),storageQuota(limit,usage)"]))
    }

    public func rootFolderID() async throws -> String {
        struct Reply: Decodable { let id: String }
        let reply: Reply = try await json(get("files/root", ["fields": "id"]))
        return reply.id
    }

    public func startPageToken() async throws -> String {
        struct Reply: Decodable { let startPageToken: String }
        let reply: Reply = try await json(get("changes/startPageToken", [:]))
        return reply.startPageToken
    }

    public func listAll() async throws -> [DriveFile] {
        try await list(query: "trashed = false")
    }

    public func listChildren(of folderID: String) async throws -> [DriveFile] {
        try await list(query: "'\(folderID.replacingOccurrences(of: "'", with: "\\'"))' in parents and trashed = false")
    }

    private func list(query: String) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var pageToken: String?
        repeat {
            var params = [
                "q": query,
                "pageSize": "1000",
                "spaces": "drive",
                "fields": "nextPageToken,files(\(DriveFile.fields))",
            ]
            if let pageToken { params["pageToken"] = pageToken }
            let page: DriveFileList = try await json(get("files", params))
            all += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    public func changes(pageToken: String) async throws -> DriveChangeList {
        try await json(get("changes", [
            "pageToken": pageToken,
            "pageSize": "1000",
            "includeRemoved": "true",
            "restrictToMyDrive": "true",
            "spaces": "drive",
            "fields": "nextPageToken,newStartPageToken,changes(fileId,removed,changeType,file(\(DriveFile.fields)))",
        ]))
    }

    public func file(id: String) async throws -> DriveFile {
        try await json(get("files/\(id)", ["fields": DriveFile.fields]))
    }

    public func download(id: String, range: ClosedRange<Int64>?, to url: URL) async throws {
        var req = get("files/\(id)", ["alt": "media", "acknowledgeAbuse": "false"])
        if let range { req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        try await downloadFile(req, to: url)
    }

    public func export(id: String, mimeType: String, to url: URL) async throws {
        try await downloadFile(get("files/\(id)/export", ["mimeType": mimeType]), to: url)
    }

    public func thumbnail(id: String) async throws -> Data? {
        struct Reply: Decodable { let thumbnailLink: String? }
        let reply: Reply = try await json(get("files/\(id)", ["fields": "thumbnailLink"]))
        guard let link = reply.thumbnailLink, let url = URL(string: link) else { return nil }
        let (data, _) = try await send(URLRequest(url: url))
        return data
    }

    // MARK: Writes

    public func createFolder(name: String, parentID: String) async throws -> DriveFile {
        var req = request("POST", "\(Self.api)/files", ["fields": DriveFile.fields])
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "mimeType": GoogleMime.folder, "parents": [parentID],
        ])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await json(req)
    }

    public func upload(name: String, parentID: String, contents: URL, modified: Date?) async throws -> DriveFile {
        var meta: [String: Any] = ["name": name, "parents": [parentID]]
        if let modified { meta["modifiedTime"] = RFC3339.format(modified) }
        let start = request("POST", "\(Self.uploadAPI)/files", ["uploadType": "resumable", "fields": DriveFile.fields])
        return try await resumableUpload(start: start, metadata: meta, contents: contents)
    }

    public func update(
        id: String, contents: URL?, name: String?, newParent: String?, oldParent: String?, modified: Date?
    ) async throws -> DriveFile {
        var meta: [String: Any] = [:]
        if let name { meta["name"] = name }
        if let modified { meta["modifiedTime"] = RFC3339.format(modified) }
        var params = ["fields": DriveFile.fields]
        if let newParent {
            params["addParents"] = newParent
            if let oldParent { params["removeParents"] = oldParent }
        }
        if let contents {
            params["uploadType"] = "resumable"
            let start = request("PATCH", "\(Self.uploadAPI)/files/\(id)", params)
            return try await resumableUpload(start: start, metadata: meta, contents: contents)
        }
        var req = request("PATCH", "\(Self.api)/files/\(id)", params)
        req.httpBody = try JSONSerialization.data(withJSONObject: meta)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await json(req)
    }

    /// Moves the item to the Drive trash, where it stays for 30 days.
    public func trash(id: String) async throws {
        var req = request("PATCH", "\(Self.api)/files/\(id)", ["fields": "id"])
        req.httpBody = Data(#"{"trashed":true}"#.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(req)
    }

    /// Starts a resumable session with the metadata, then sends the whole file in one request.
    private func resumableUpload(start: URLRequest, metadata: [String: Any], contents: URL) async throws -> DriveFile {
        var start = start
        let size = (try? contents.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        let (_, response) = try await send(start)
        guard let location = response.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location) else {
            throw DriveAPIError(.server, "Google Drive didn't start the upload")
        }
        var put = URLRequest(url: sessionURL)
        put.httpMethod = "PUT"
        put.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, _) = try await send(put, uploading: contents)
        return try decode(data)
    }

    // MARK: Plumbing

    private func get(_ path: String, _ params: [String: String]) -> URLRequest {
        request("GET", "\(Self.api)/\(path)", params)
    }

    private func request(_ method: String, _ url: String, _ params: [String: String]) -> URLRequest {
        var comps = URLComponents(string: url)!
        if !params.isEmpty {
            comps.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        return req
    }

    private func json<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, _) = try await send(req)
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder.drive.decode(T.self, from: data)
        } catch {
            throw DriveAPIError(.server, "Unexpected reply from Google Drive: \(error)")
        }
    }

    private func downloadFile(_ req: URLRequest, to url: URL) async throws {
        try await withRetries { attempt in
            var req = req
            req.setValue("Bearer \(try await self.tokens.accessToken(forceRefresh: attempt.refresh))", forHTTPHeaderField: "Authorization")
            let (temp, response) = try await self.session.download(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                let body = (try? Data(contentsOf: temp)) ?? Data()
                throw Self.error(status: status, body: body)
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    /// Sends an authorized request, optionally uploading a file as the body.
    private func send(_ req: URLRequest, uploading file: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        try await withRetries { attempt in
            var req = req
            req.setValue("Bearer \(try await self.tokens.accessToken(forceRefresh: attempt.refresh))", forHTTPHeaderField: "Authorization")
            let (data, response): (Data, URLResponse)
            if let file {
                (data, response) = try await self.session.upload(for: req, fromFile: file)
            } else {
                (data, response) = try await self.session.data(for: req)
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status), let http else { throw Self.error(status: status, body: data) }
            return (data, http)
        }
    }

    struct Attempt { var number = 0; var refresh = false }

    /// Retries network failures, rate limits and server errors with exponential backoff, and a
    /// rejected token once after refreshing it.
    private func withRetries<T>(_ body: (Attempt) async throws -> T) async throws -> T {
        var attempt = Attempt()
        while true {
            do {
                return try await body(attempt)
            } catch let error as DriveAPIError {
                if error.kind == .unauthorized, !attempt.refresh {
                    attempt.refresh = true
                    continue
                }
                guard [.rateLimited, .server, .transport].contains(error.kind), attempt.number < 5 else { throw error }
            } catch let error as URLError {
                guard attempt.number < 5 else { throw DriveAPIError(.transport, error.localizedDescription) }
            }
            attempt.number += 1
            attempt.refresh = false
            let delay = pow(2, Double(attempt.number)) / 2 + Double.random(in: 0..<0.5)
            log.notice("Retrying Drive request in \(delay, privacy: .public)s")
            try await Task.sleep(for: .seconds(delay))
        }
    }

    static func error(status: Int, body: Data) -> DriveAPIError {
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        switch status {
        case 401: return DriveAPIError(.unauthorized, "Google Drive rejected the sign-in")
        case 404: return DriveAPIError(.notFound, "Not found in Google Drive")
        case 429: return DriveAPIError(.rateLimited, "Google Drive rate limit")
        case 403 where text.contains("ateLimitExceeded"): return DriveAPIError(.rateLimited, "Google Drive rate limit")
        case 500...: return DriveAPIError(.server, "Google Drive error \(status)")
        default: return DriveAPIError(.rejected, "Google Drive refused the request (\(status)): \(text)")
        }
    }
}
