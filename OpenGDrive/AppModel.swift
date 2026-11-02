import AppKit
import AuthenticationServices
@preconcurrency import FileProvider
import Observation
import OpenGDriveCore
import os
import ServiceManagement

/// App state behind the menu bar UI: sign-in, the File Provider domain, and polling.
@MainActor
@Observable
final class AppModel {
    enum Account: Equatable {
        case unknown
        case signedOut
        case signingIn
        case signedIn(email: String)
    }

    enum Status: Equatable {
        case idle
        case syncing
        case paused
        case error(String)
    }

    var account: Account = .unknown
    var status: Status = AppConfig.paused ? .paused : .idle
    var about: DriveAbout?
    var lastSync: Date?
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let credentials = CredentialStore()
    @ObservationIgnored private let oauth = GoogleOAuth(clientID: AppConfig.oauthClientID)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = PresentationAnchor()
    @ObservationIgnored private let log = Logger(subsystem: "OpenGDrive", category: "app")

    static let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("googledrive"), displayName: "Google Drive")
    private var manager: NSFileProviderManager? { NSFileProviderManager(for: Self.domain) }
    private var client: GoogleDriveClient { GoogleDriveClient(tokens: TokenProvider(oauth: oauth, store: credentials)) }

    var hasOAuthClientID: Bool { !AppConfig.oauthClientID.isEmpty }
    var isPaused: Bool { status == .paused }

    var menuBarSymbol: String {
        switch (account, status) {
        case (.signedIn, .syncing): "arrow.triangle.2.circlepath.icloud"
        case (.signedIn, .error): "exclamationmark.icloud"
        case (.signedIn, .paused): "icloud.slash"
        case (.signedIn, .idle): "checkmark.icloud"
        default: "icloud"
        }
    }

    init() {
        Task { await start() }
    }

    // MARK: Lifecycle

    func start() async {
        guard credentials.read() != nil else {
            account = .signedOut
            return
        }
        do {
            let about = try await client.about()
            self.about = about
            account = .signedIn(email: about.user?.emailAddress ?? "")
            try await NSFileProviderManager.add(Self.domain)
            startPolling()
        } catch let e as DriveAPIError where e.kind == .unauthorized {
            // The refresh token was revoked or expired.
            credentials.delete()
            account = .signedOut
        } catch {
            // Offline at launch: stay signed in and keep retrying through the poller.
            account = .signedIn(email: "")
            status = .error(error.localizedDescription)
            startPolling()
        }
    }

    /// Asks the extension to pull Drive's changes. It syncs whenever the working set is enumerated.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func syncNow() async {
        guard case .signedIn = account, !isPaused, let manager else { return }
        status = .syncing
        do {
            try await manager.signalEnumerator(for: .workingSet)
            about = try await client.about()
            if case let .signedIn(email) = account, email.isEmpty {
                account = .signedIn(email: about?.user?.emailAddress ?? "")
            }
            lastSync = Date()
            status = .idle
        } catch let e as DriveAPIError where e.kind == .unauthorized {
            status = .error("Google sign-in expired. Sign out and sign in again.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: Sign in

    func signIn() {
        guard hasOAuthClientID else { return }
        let attempt = GoogleOAuth.Attempt()
        account = .signingIn
        let session = ASWebAuthenticationSession(
            url: oauth.authorizationURL(for: attempt), callbackURLScheme: oauth.callbackScheme
        ) { [weak self] url, error in
            Task { @MainActor in
                await self?.finishSignIn(callback: url, error: error, attempt: attempt)
            }
        }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        NSApp.activate(ignoringOtherApps: true)
        if !session.start() {
            account = .signedOut
        }
    }

    private func finishSignIn(callback: URL?, error: Error?, attempt: GoogleOAuth.Attempt) async {
        authSession = nil
        guard let callback else {
            if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                status = .error(error.localizedDescription)
            }
            account = .signedOut
            return
        }
        do {
            let creds = try await oauth.finish(callback: callback, attempt: attempt)
            try credentials.save(creds)
            status = AppConfig.paused ? .paused : .idle
            await start()
        } catch {
            log.error("Sign-in failed: \(String(describing: error), privacy: .public)")
            status = .error(error.localizedDescription)
            account = .signedOut
        }
    }

    func signOut() async {
        pollTask?.cancel()
        // Removing the domain deletes the local copies. Everything is still in Google Drive.
        try? await NSFileProviderManager.remove(Self.domain)
        credentials.delete()
        if let db = AppConfig.sharedContainer?.appendingPathComponent("Library/Application Support/OpenGDrive") {
            try? FileManager.default.removeItem(at: db)
        }
        about = nil
        lastSync = nil
        account = .signedOut
    }

    // MARK: Actions

    func openInFinder() async {
        guard let manager else { return }
        do {
            // The URL is security-scoped: the sandbox blocks opening it until access starts.
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if !NSWorkspace.shared.open(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func setPaused(_ paused: Bool) async {
        AppConfig.paused = paused
        status = paused ? .paused : .idle
        if !paused { await syncNow() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Launch at login: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// A menu bar app has no window of its own, so the sign-in sheet gets a fresh one.
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSWindow() }
    }
}
