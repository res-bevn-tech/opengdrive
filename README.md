# OpenGDrive

Google Drive in Finder, the way iCloud Drive works: everything is listed, files download when you open them, and **Remove Download** frees the space again. Built on Apple's File Provider framework, so Finder shows sync status, "Keep Downloaded", and works offline with what's already on the Mac.

The architecture is adapted from [GitDrive](https://github.com/deeeeone/gitdrive) (MIT), which does the same for GitHub repositories.

## What it does

- **My Drive** appears under *Locations* in Finder as "Google Drive".
- Files are placeholders until opened. Right-click → *Remove Download* to evict, *Keep Downloaded* to pin.
- Create, rename, move, edit and delete in Finder; changes go to Drive. Deleting moves to the **Drive trash** (recoverable for 30 days).
- Changes made on the web or other devices arrive through Drive's changes feed (polled every 30 s, or *Sync Now*).
- Google Docs, Sheets, Slides and Drawings show as `.docx`, `.xlsx`, `.pptx`, `.pdf` exports. They're read-only here; edit them in the browser.
- If a file changed in Drive while you were editing it on the Mac, both versions are kept: yours is uploaded as `name (conflict from Mac 2026-01-02 03.04).ext`.
- Drive allows two files with the same name in one folder; Finder doesn't. The oldest keeps its name and the others become `name 2.ext`, `name 3.ext` (only on the Mac; Drive is unchanged).
- Thumbnails come from Drive, so icon view doesn't download anything.

Not included: Shared drives, "Shared with me" items that aren't added to My Drive, Google Forms/Sites/shortcuts, and multiple accounts.

## Setup

### 1. Google Cloud OAuth client (once, ~5 minutes)

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project.
2. *APIs & Services → Library*: enable **Google Drive API**.
3. *OAuth consent screen*: User type **External**, fill in the app name and your email, add the scope `.../auth/drive`, add yourself as a test user.
   - Then click **Publish app** so the status is **In production**. You'll see an "unverified app" warning when signing in, which is fine for personal use. In *Testing* status Google expires the refresh token after 7 days and you'd have to sign in again every week.
4. *Credentials → Create credentials → OAuth client ID*, type **iOS** (yes, iOS: it's the type that gives a reversed-client-ID redirect and works without a client secret). Bundle ID: the same value as `OPENGDRIVE_BUNDLE_ID` below.
5. Copy the client ID (`1234-abc.apps.googleusercontent.com`).

### 2. Build and install

Requirements: macOS 14+, Xcode 16+, and an **Apple Development** certificate (a free Apple ID works: Xcode → Settings → Accounts → Manage Certificates). File Provider extensions need a real development signature with app groups; they don't run unsigned.

```bash
./scripts/install.sh --no-install
```

The first run writes `Config/Local.xcconfig` with your team ID. Put the client ID in it:

```
DEVELOPMENT_TEAM = ABCDE12345
OPENGDRIVE_BUNDLE_ID = dev.opengdrive.tabcde12345
OPENGDRIVE_OAUTH_CLIENT_ID = 1234-abc.apps.googleusercontent.com
```

The bundle ID here must match the one on the Google iOS client. Then:

```bash
./scripts/install.sh
```

Click the cloud in the menu bar → **Sign in with Google** → **Open in Finder**.

To work in Xcode instead: `xcodegen generate`, open `OpenGDrive.xcodeproj`, run the *OpenGDrive* scheme.

## How it works

```
OpenGDrive.app (menu bar)                 OpenGDriveFileProvider.appex
  ├─ Google sign-in (PKCE)                  ├─ FileProviderExtension   item / fetch / create / modify / delete
  ├─ adds the File Provider domain          ├─ DriveEnumerator         folders, working set, changes since anchor
  └─ signals the working set every 30 s     └─ DriveItem               ItemRecord → NSFileProviderItem
                  │                                       │
                  └──────── OpenGDriveCore (Swift package) ┘
                            ├─ GoogleOAuth, TokenProvider, CredentialStore (shared keychain group)
                            ├─ GoogleDriveClient       Drive v3: files, changes, export, resumable upload
                            ├─ ItemStore               SQLite (GRDB) in the shared app group container
                            └─ SyncEngine              full listing once, then the changes feed
```

- **Identity**: Drive file IDs are stable, so they're used directly as File Provider item identifiers. Renames and moves need no bookkeeping.
- **Index**: `ItemStore` keeps one row per item plus tombstones, each stamped with an increasing sequence number. That number is the File Provider sync anchor, so "what changed since anchor N" is one query.
- **Pull**: the first sync takes a `startPageToken`, lists all of My Drive, and keeps what hangs under the root. After that only `changes.list` is read. A folder moved into My Drive from elsewhere is listed recursively, since the feed only reports the folder itself.
- **Push**: uploads use Drive's resumable protocol. Before uploading new contents, the file's current `md5Checksum` is compared with the one this Mac last saw; a mismatch produces a conflict copy instead of overwriting.
- **Tokens**: the refresh token lives in a keychain access group shared by the app and extension. Either side refreshes the access token when it's within 60 s of expiry, and retries once on 401.

## Development

```bash
cd Packages/OpenGDriveCore && swift test
```

The sync engine is tested against an in-memory fake Drive (`FakeDrive.swift`): first sync, duplicate names, remote edits/trash/moves through the feed, local create/rename/move/delete, conflicts, and Google Docs exports.

Logs: `log stream --predicate 'subsystem == "OpenGDrive"'`.

If Finder gets confused during development: sign out from the menu (removes the domain and its local index), or `fileproviderctl dump`.

## License

MIT. See [LICENSE](LICENSE).
