import OpenGDriveCore
import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            switch model.account {
            case .unknown:
                ProgressView().frame(maxWidth: .infinity)
            case .signedOut, .signingIn:
                signedOut
            case .signedIn:
                signedIn
            }
            Divider()
            HStack {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Image(systemName: model.menuBarSymbol).font(.title2)
            VStack(alignment: .leading) {
                Text("Google Drive").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var statusText: String {
        switch model.status {
        case .paused: return "Paused"
        case .syncing: return "Syncing…"
        case let .error(message): return message
        case .idle:
            guard let last = model.lastSync else { return "Up to date" }
            return "Updated \(last.formatted(.relative(presentation: .named)))"
        }
    }

    @ViewBuilder private var signedOut: some View {
        if model.hasOAuthClientID {
            Text("Sign in to show your Drive in Finder. Files download when you open them.")
                .font(.callout).foregroundStyle(.secondary)
            Button(model.account == .signingIn ? "Waiting for browser…" : "Sign in with Google") { model.signIn() }
                .buttonStyle(.borderedProminent)
                .disabled(model.account == .signingIn)
        } else {
            Text("No OAuth client ID. Set OPENGDRIVE_OAUTH_CLIENT_ID in Config/Local.xcconfig and rebuild.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var signedIn: some View {
        if case let .signedIn(email) = model.account, !email.isEmpty {
            Text(email).font(.callout)
        }
        if let about = model.about {
            quota(about)
        }
        HStack {
            Button("Open in Finder") { Task { await model.openInFinder() } }
                .buttonStyle(.borderedProminent)
            Button("Sync Now") { Task { await model.syncNow() } }
                .disabled(model.isPaused)
        }
        HStack {
            Button(model.isPaused ? "Resume" : "Pause") { Task { await model.setPaused(!model.isPaused) } }
            Spacer()
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        }
        .font(.callout)
    }

    private func quota(_ about: DriveAbout) -> some View {
        let used = ByteCountFormatter.string(fromByteCount: about.usedBytes, countStyle: .file)
        return VStack(alignment: .leading, spacing: 4) {
            if let limit = about.limitBytes, limit > 0 {
                ProgressView(value: Double(about.usedBytes), total: Double(limit))
                Text("\(used) of \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) used")
            } else {
                Text("\(used) used")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
