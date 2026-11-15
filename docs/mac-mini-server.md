# QJotter server on the Mac mini

Current migration: 15 November 2026.

- Address: **https://davids-mac-mini.local:8767**
- Server folder: `~/Library/Application Support/NotefileServer` on David’s Mac mini.
- Database: `data/notes.sqlite3` in that folder.
- Public certificate: `QJotter-Mac-mini-Server.pem` in iCloud Drive → QJotter server, and Files → On My iPhone → QJotter.
- Certificate SHA-256 (DER): `cf3073b318e2d297f24000269de1f1e1669ac8bb6ba1c7dcf2d2b17cfb862776`.

Port **8767** avoids the existing BeneEde restaurant service on port 8766. The restaurant service was left untouched. The certificate validates the hostname independently of the port.

## Apps

Build 18 contains the Mac mini address and public certificate. For an existing sign-in to `https://davids-macbook-pro.local:8766`, it first verifies the new server using the transferred session. It then updates the secure session, copies the active cache, selection, pending mutations and persistent outbox, and starts syncing to the Mac mini. Passwords and user IDs are unchanged. A failed destination connection or Keychain update leaves the old sign-in and local edits available for retry on restart.

A stale destination cache is preserved under a separate local archive profile instead of being uploaded. The previous MacBook cache also remains on the device for recovery. A repeated migration does not overwrite subsequent destination edits.

For another device or an older app build, open Settings, use the new address, import the public certificate, and sign in with the existing account. Preserve pending edits before manually signing out of an old server. Update the app first where possible.

## Service and backups

The server starts when David signs into macOS and restarts if it exits. It does not start before login after a reboot. The server is wrapped in `caffeinate -i`, which prevents idle system sleep only while the service is running. The display can still sleep; global power settings were not changed. Keep the Mac mini connected to the network. The MacBook is no longer required.

Run on the Mac mini:

```sh
/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14 \
  "$HOME/Library/Application Support/NotefileServer/app/manage_server.py" status
```

Replace `status` with `start`, `stop`, or `backup` as needed. Automatic backups run at login and daily at 03:00, retaining at least 30 copies and 30 days of scheduled snapshots. See [backup and account recovery details](server-administration.md).

## Preserved migration data

The final MacBook snapshot contained 164 live notes, 227 total note records, 1 user, 4 sessions, 568 operations and 94 operation results. It passed SQLite integrity checking. The snapshot copied to the Mac mini matched SHA-256 exactly:

`a6b764ecdab6cb0024a71dfd0fbb9446dd434b1bed8de2ac33d8e1b83d80c29a`

The old Mac mini database folder is preserved as `data-before-mini-return-20261115` inside the server folder. Private full server archives and device backups are stored on the Mac mini under:

`~/Library/Application Support/QJotterRecovery/20261115-mini-migration/`

These archives contain private notes and server credentials and must remain private. The iPhone’s pending uploads are retained during the app migration, so counts can increase after the final source snapshot.

## Final verification and MacBook removal

Both Mac and iPhone were updated to build 18. The iPhone’s three pending uploads completed. Both caches exactly matched all 230 server note records, including 164 live notes and deletion markers, with zero dirty rows or outbox entries. The Mac also restored its sign-in and showed “Saved to server” after a restart.

After those checks, the MacBook’s `NotefileServer` folder, migration staging folder, and server/backup LaunchAgent plists were removed. Both retired jobs remain disabled. The full MacBook server archive and migration staging archive are preserved only in the Mac mini recovery folder named above. `verification.json` there records the matching cache hashes.

Migration regression tests cover preservation of pending mutations and outbox entries, archival of stale caches, connection failures, Keychain write failures, and repeat attempts. The complete Flutter suite passed 100 tests; the server suite passed 20 tests. Static analysis found no issues.
