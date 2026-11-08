# Server backups and account recovery

Configured on 8 November 2026. Run the commands below from the QJotter project
directory, or run the installed manager at
`~/Library/Application Support/NotefileServer/app/manage_server.py`.

## Automatic backups

The `com.example.notefile.backup` LaunchAgent runs every day at **03:00 local
time**, and at macOS login. If the Mac is asleep at 03:00, launchd runs the job
when it wakes. The user must be signed in. The job uses the installed server
tools, so Android Studio and the project directory can be closed.

Snapshots are stored in
`~/Library/Application Support/NotefileServer/backups/`. SQLite's online backup
API includes committed WAL writes while the server remains available. Each
snapshot must pass `PRAGMA integrity_check` before its final filename appears.
Backup files have permissions `0600`; the containing directory is `0700`.

Scheduled files use the prefix `scheduled-`. Successful backups expire scheduled
copies older than 30 days, but always preserve at least the latest 30 scheduled
copies. Manual and pre-update snapshots use `notefile-` and are never pruned
automatically. A failed backup does not trigger pruning. Partial files are not
treated as successful backups.

```sh
python3 server/manage_server.py status
python3 server/manage_server.py backup
python3 server/manage_server.py backups on
python3 server/manage_server.py backups off
```

`status` reports whether the job is loaded, the last verified snapshot time, and
the most recent backup error. The logs are `logs/backup.log` and
`logs/backup-error.log` in the server folder. Check status periodically; there
is no email alert service. To change the time or retention:

```sh
python3 server/manage_server.py backups on --hour 3 --minute 0 --retain-days 30
```

These backups contain notes, password hashes, sessions and recovery-code hashes.
Keep them private. They are on this Mac's disk; they do not protect against loss
of the entire disk. An encrypted backup on a separate device is still needed
for that. TLS private keys and configuration are not inside the database
snapshot; preserve them separately when migrating the server.

For restoration, stop the server and disable scheduled backups, verify the chosen
snapshot, preserve the entire existing `data` folder including WAL/SHM files,
and restore the snapshot as `data/notes.sqlite3` in a new private `data` folder.
Follow the file-permission and verification steps in
[the migration guide](local-server-and-migration.md#move-to-another-machine-on-this-network).
Clear restored `sessions` and `password_resets` tables before restarting so old
access is not revived. Restoring also restores passwords as of that snapshot;
users whose passwords changed later may need a new recovery code. Re-enable
backups after checking the restored server. Restore tests use disposable databases
and never replace the live notebook.

## Recover a forgotten password

Recovery is administrator assisted. Verify the person's identity through a
trusted channel before issuing a code; knowing their email address is not proof
of ownership. On the server Mac, run:

```sh
python3 server/manage_server.py issue-reset person@example.com
```

This takes a pre-recovery database backup and prints a random recovery code.
Give the code privately to that account's verified owner. The command does not
change their password, create a replacement account or sign them out. It is a
local administrative operation, not a public network endpoint. Issuing a new code
invalidates any previous code for that account.

The person then opens **Settings → Forgot password?**, enters their account
email, recovery code and a new password, confirms the password, and taps
**Reset password**. The server address and certificate are the same as for
normal sign-in. They then sign in normally with the new password.

Codes expire after **30 minutes** and work **once**. Only their SHA-256 hashes
are stored. Passwords use individually salted scrypt hashes and must contain
12–1,024 characters. Completing recovery invalidates all existing server sessions
and recovery codes for that account. The account ID, notes and sync history stay
unchanged, and other users are unaffected. Other devices must sign in again;
their cached notes remain on disk. There is no automatic email delivery or email
ownership verification in this private-network recovery process.

Account registration remains enabled for onboarding. To close it after the
intended users have joined, use `python3 server/manage_server.py registration off`.
Recovery and sign-in remain available when registration is disabled.

Implementation references: [SQLite online backup](https://sqlite.org/backup.html),
[Apple scheduling](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html),
and [OWASP password recovery](https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html).
