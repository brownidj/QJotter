> **Historical guide:** QJotter returned to the Mac mini on 15 November 2026.
> Use `https://davids-mac-mini.local:8767`; see [current server instructions](mac-mini-server.md).
> The MacBook service described below is retired.

# QJotter server on David’s MacBook Pro

Migration completed 9 November 2026.

## Current connection

- HTTPS address: `https://Davids-MacBook-Pro.local:8766`
- Current LAN IP alternative: `https://192.168.50.163:8766`
- Machine verified as MacBookPro16,1, macOS 26.7.1, user `david`.
- Installed Python: `/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14`.
- Server folder on the **MacBook**: `~/Library/Application Support/NotefileServer`.
- Public certificate in iCloud Drive: `QJotter server/QJotter-MacBook-Server.pem`.
- Public certificate SHA-256 (DER):
  `5ebb276da109a6e52bcb1f6c5284bff028483d8fdaa8be19511918a0d054911a`.

The private key stays on the MacBook. No system-wide certificate trust or router
port forwarding was added.

## Switch each app

In QJotter Settings, sign out of the old server, save the new HTTPS address,
import the public certificate from iCloud Drive → QJotter server, and sign in
using the existing email and password. Do not create a replacement account.
The new address has its own local cache. Old cached profiles remain preserved.
If a device has edits still waiting for the old server, preserve those edits
before signing out; they will not automatically transfer between server profiles.

## Verification and preserved data

The old service was stopped for the final SQLite online backup. The transferred
snapshot and restored database matched SHA-256 exactly and passed SQLite
integrity checking. All table counts matched: 1 account, 197 total note records
(165 live notes and 32 deletion markers), plus sessions, operations and recovery
records. No passwords were reset. HTTPS health succeeded locally on the MacBook
and from the Mac mini with certificate and hostname verification enabled.

The new service runs as `com.example.notefile.server` in David's macOS login
session, restarts if it exits, and starts when David signs in. It does not run
before login after a reboot. Locking the screen does not log out. Automatic
backups run at login and daily at 03:00 with the existing 30-day retention policy.
An immediate verified backup was created. Mains sleep was already disabled;
keep mains connected and leave the lid open unless using supported clamshell mode.

On the Mac mini, both server and backup LaunchAgents were stopped and disabled
for future logins. Their files were retained. Its final snapshot and manifest are
in `~/Library/Application Support/NotefileServer/` (manifest
`migration-20261109.json`, snapshot path recorded inside). The MacBook's initial
empty data folder was preserved as `data-before-migration-*`.

## Administration

Run these on the **MacBook**, not the old Mac mini:

```sh
/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14 \
  "$HOME/Library/Application Support/NotefileServer/app/manage_server.py" status
```

From the Mac mini, remote status can be checked with:

```sh
ssh david@Davids-MacBook-Pro.local \
  '/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14 "$HOME/Library/Application Support/NotefileServer/app/manage_server.py" status'
```

The same manager supports `backup`, `start`, `stop`, `registration on/off`,
`backups on/off` and `issue-reset`. Starting the old Mac mini server would
re-enable it, so do not do that while the MacBook server is active.

To roll back, first stop and disable the MacBook service. If it has accepted
new edits, take a fresh snapshot there and migrate that database back; starting
the stale Mac mini database would omit those edits. Restore only after preserving
the current data folders and WAL/SHM files. Then start the selected server and
update client addresses/certificate trust as needed.

## Certificate stored locally on the iPhone

Build 15 enables QJotter Documents access in Files using UIFileSharingEnabled
and LSSupportsOpeningDocumentsInPlace. The public certificate was copied into
`Documents/QJotter-MacBook-Server.pem` on iPhone 00008110-001E48A02187601E.
A copy read back from the phone matched the server certificate fingerprint.
Import it from Settings → Import server certificate → Browse → On My iPhone
→ QJotter → QJotter-MacBook-Server.pem. No private key was copied.
