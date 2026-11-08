# Storage, accounts and startup

The server is now installed on this Mac for private-network HTTPS access. See
[current server setup and migration](local-server-and-migration.md) for its
address, certificate, service controls and migration steps.

## Server storage and offline cache

The default notebook belongs to a server account. Without a remembered login,
the app opens account setup instead of a device-only editor. Signing in once
allows subsequent launches to open cached account notes immediately, including
when offline. Notes are uploaded automatically, and the editor shows the current
server-save status. **Saved to server** appears only after acknowledgement;
offline edits remain queued until a successful sync.

The app opens `notes.sqlite3` in its Application Support directory on macOS,
iOS and Windows. The database schema is versioned with SQLite `user_version`.
Notes, timestamps, the selected note, sync metadata and app preferences are
stored in tables. Edits are committed in transactions; WAL journaling and a
busy timeout protect writes and allow concurrent readers.

On the first launch with SQLite, `notes.json` is imported transactionally.
If it is absent, the earlier `quick_capture_draft.txt` is imported instead.
Both source files remain untouched as migration backups. Later launches read
SQLite and do not reimport an outdated backup. A malformed source stops the
migration without replacing it with an empty notebook.

Each server account gets a separate local profile, identified by server URL
and server user ID. Device-only notes are separate from every account. UUIDs
avoid collisions between notes created independently on different devices.
Deleting a note stores a tombstone so another device cannot restore it merely
by sending an older snapshot. Undo restores the same note ID.

The SQLite files contain readable note text; app-level database encryption is
not implemented. Signing out removes the remembered login and returns to account
setup. It does not erase cached account notes from disk. OS account security
and disk encryption protect local files; do not treat sign-out as secure erasure.
The app never displays or uploads another account's profile through its UI/API.

## Accounts and sync

Open the gear button → Settings. Enter the server's HTTPS base address, email
and password. Choose **Create an account** if registration is enabled on that
server. The app keeps the returned session in the OS's secure credential store
(Keychain on Apple platforms), not in the SQLite settings table. Passwords are
sent only during sign-in/registration and are not retained by the app.

Use the same server address and account on another device. Sync runs after
edits, every 30 seconds while the app is running, when returning to the app,
and through **Sync now** in Settings. Offline changes stay in local SQLite and
retry when connected. iOS can suspend the app; sync is not guaranteed while it
is suspended or terminated. A restored valid session keeps the account's local
notebook available offline. Sessions expire after 30 days and require sign-in again.

Existing device notes are imported automatically into the first authenticated
account used on this device. The import and its ownership marker are one SQLite
transaction; note IDs and timestamps are preserved. An interrupted upload retries
without importing duplicate notes. Later sign-ins to another account do not
receive those device notes. Original device rows and pre-SQLite migration files
remain as backups, but the app no longer offers a device-only editing mode.

The server authenticates every sync request and restricts every notes query
to the authenticated user ID. It never trusts a client-supplied owner. Passwords
use individually salted scrypt hashes. Random bearer tokens are stored as
SHA-256 hashes on the server, expire, and can be revoked at sign-out. Offline
sign-out removes local credentials immediately; a server session that could
not be contacted remains valid until expiry. Repeated failed sign-in attempts
are rate limited.

Sync sends changed rows, including deletion markers, and returns the account's
complete server snapshot. Server revisions detect simultaneous edits. Both
edits are preserved as separate notes with a conflict-copy annotation; a stale
delete does not erase a newer edit. Persistent mutation IDs make retries
idempotent. Edits made during a request are kept dirty for the next request.

SQLite is not exposed as a network filesystem or a public database port. Each
device communicates with the server API; the server opens its own SQLite file.

## Run the server locally

Python 3.10 or later is sufficient; no third-party server packages are needed.
From the project directory:

```sh
python3 server/notefile_server.py \
  --database "$HOME/Library/Application Support/NotefileServer/notes.sqlite3" \
  --allow-registration
```

The API listens only on `127.0.0.1:8765` by default. In the Mac app's Settings,
enter `http://127.0.0.1:8765`, then create a test account. Loopback HTTP is allowed
for development; other server addresses must use HTTPS. No real account is
created by the automated tests, and they never upload your existing notes.

For cross-device access, deploy the server on the chosen host, configure an
HTTPS reverse proxy with a valid certificate and a request-size limit, and use
that public HTTPS base address on each device. Keep the SQLite file on the
server's local persistent disk, with access restricted to the service user.
Use SQLite's backup API or stop the service before copying its files: copying
only the main file while WAL writes are active may miss recent changes.

Registration is disabled unless `--allow-registration` is supplied. Disable
it after creating the intended accounts. The current server is a small runnable
prototype. Administrator-assisted password recovery and scheduled local backups
are implemented; see [server administration](server-administration.md).
Account deletion, operational monitoring and production deployment configuration
remain work for a public launch.
Its in-process sign-in limiter is per direct peer IP, so a reverse proxy needs
its own per-client rate limiting; forwarded IP headers are not trusted by the API.
Limits are 256 KB per note, 1,000 note rows (including tombstones) and 8 MB of
note text per account. Full snapshots and retained tombstones are deliberate
initial limits, not a design for unlimited scale.

API routes: `POST /v1/register`, `/v1/login`, `/v1/logout`, `/v1/sync`, `/v1/reset-password`;
`GET /health`. The server also supports direct HTTPS with `--tls-cert` and
`--tls-key`; the Mac installer provisions a private certificate for LAN access.

## Automatic startup

On macOS and Windows the app attempts to enable startup on its first SQLite-era
launch. Settings → **Launch when I sign in to this computer** turns it off or on.
Startup happens after OS user login, including login following a reboot.

macOS 13+ uses Apple's `SMAppService.mainApp`. Install the app in Applications
at a stable path for reliable registration. macOS may require approval under
System Settings → General → Login Items. Settings shows actual registration or
pending approval and reports failures, rather than claiming startup is active.
An unsigned or development build may not register; use an installed signed build
for distribution. Older macOS versions show that startup is unavailable.

Windows writes a quoted executable path under the current user's
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run\Notefile`; disabling startup
removes only that app value. No administrator access is required. Windows may
independently disable startup through its own Settings/Task Manager controls.
Use an installed executable at a stable path. The app does not repeatedly
register itself on every launch, so OS-level changes are respected.

iOS does not provide desktop-style automatic launch at reboot for this app.
Settings explains this and offers account access. See
[iOS quick launch](interface-and-ios-quick-launch.md) for shortcuts.

## Validation

```sh
flutter analyze
flutter test
python3 -m unittest discover -s server -v
```

Flutter tests cover transactional migration/rollback, separate profiles,
deletions, concurrent edits, startup preferences and Settings. An integration
test starts a temporary real HTTP server and uses two separate SQLite databases
to test account creation, sign-in, cross-device sync, sign-out and isolation.
Server tests cover ownership, password/session handling, conflict preservation,
idempotency, stale deletions, validation and rate limiting. Test hosts use
temporary storage and never register real login items. Native platform builds
and real startup behaviour must be checked on each target OS.

Platform references: [Apple login items](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp),
[Windows startup registry](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys),
[iOS launch lifecycle](https://developer.apple.com/documentation/uikit/responding-to-the-launch-of-your-app),
[SQLite Dart package](https://pub.dev/packages/sqlite3),
[secure storage configuration](https://pub.dev/packages/flutter_secure_storage).
