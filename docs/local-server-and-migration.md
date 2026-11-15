> **Current server, 15 November 2026:** `https://davids-mac-mini.local:8767`.
> See [Mac mini server administration](mac-mini-server.md).
> The older port 8766 configuration below is historical; BeneEde now uses that port.

# This Mac’s QJotter server

Installed on 7 November 2026. The server is running independently of Android
Studio and the project checkout as the current macOS user's LaunchAgent.

| Item | Current setting |
| --- | --- |
| Preferred address | `https://davids-mac-mini.local:8766` |
| Current IPv4 alternative | `https://192.168.50.164:8766` |
| Service | `com.example.notefile.server` |
| Installed folder | `/Users/david/Library/Application Support/NotefileServer` |
| Database | `data/notes.sqlite3` inside that folder |
| Configuration | `config.json` inside that folder |
| Installed server code | `app/notefile_server.py` inside that folder |
| Public certificate | `tls/notefile-server.pem` inside that folder |
| Private key | `tls/notefile-server-key.pem` inside that folder; keep on the server |
| Logs | `logs/server.log` and `logs/server-error.log` |
| LaunchAgent | `/Users/david/Library/LaunchAgents/com.example.notefile.server.plist` |

Port 8765 belongs to another application and was left untouched. The server
listens on IPv4 network interfaces on port 8766, with HTTPS and authenticated
account access. No router port forwarding or system-wide certificate trust was
configured. The host name is preferable to an IP that may change with DHCP.

The service starts when David signs into macOS and restarts if it exits. It
does not depend on the terminal or IDE staying open. This is a per-user service,
so it is unavailable while this Mac is asleep, shut down or the user is logged
out. The next dedicated server can run as a system service if it must operate
before anyone signs into that machine.

## Finish setting up your account

The Mac app's server address and public certificate have been preconfigured.
Open **Settings → Account → Create an account**, enter your email and a password
of at least 12 characters, then create the account. No account/password was
invented on your behalf. Account setup is now required before editing. Existing
device notes are added automatically to the first account you sign in to, then
uploaded to the server. A local cache keeps notes available offline; the editor
shows whether changes have reached the server.

On another device on the same network:

1. Install the updated QJotter app and open Settings.
2. Enter `https://davids-mac-mini.local:8766` and save the address. If `.local`
   naming is unavailable, the current IP alternative above is also in the certificate.
3. Transfer the **public** `notefile-server.pem` file to that device and choose
   **Import server certificate…** in Settings. Do not transfer the private key.
4. Sign in with the same email and password. Account notes will sync.

This private certificate is trusted only by QJotter for the configured server
address. TLS checks for hostname, certificate validity and expiry still apply;
the app does not accept arbitrary invalid certificates. The generated certificate
expires after 825 days. Renew it before expiry and import the new public
certificate on each device. No certificate was added to the system trust store.

Private builds may preconfigure the address and public certificate using
`NOTEFILE_SERVER` and `NOTEFILE_SERVER_CERTIFICATE_BASE64` in a Flutter
`--dart-define-from-file` JSON file. The certificate value is the Base64-encoded
public PEM text. Existing user settings are preserved, and the added trust is scoped to
that exact server address inside QJotter. Never put passwords, session tokens
or private keys in build configuration. The iPhone build installed on
8 November 2026 includes this Mac server's public certificate.

Certificate SHA-256 fingerprint (DER):

```text
cf3073b318e2d297f24000269de1f1e1669ac8bb6ba1c7dcf2d2b17cfb862776
```

Account registration is enabled for setup. After creating the accounts you
want, it can be disabled with the command below. Existing users can still sign in.

## Manage the service

Run these from `/Users/david/Documents/ChatGPT/QJotter`:

```sh
python3 server/manage_server.py status
python3 server/manage_server.py stop
python3 server/manage_server.py start
python3 server/manage_server.py backup
python3 server/manage_server.py registration off
python3 server/manage_server.py registration on
```

`stop` stops the current service; it remains registered for the next login.
`backup` creates a dated, integrity-checked SQLite snapshot under `backups/`.
It includes committed WAL changes and can run while the server is running.
Backups contain account password hashes and note contents, so keep them private.
Automatic backups run daily at 03:00 local time and at login, with 30-day
retention and at least 30 scheduled copies preserved. See
[server administration](server-administration.md) for backup status, restoration
and the administrator-assisted password recovery process.

To update the installed server after editing its source:

```sh
python3 server/manage_server.py install --hostname Davids-Mac-mini.local
```

This preserves configuration, certificates and the database, makes a pre-update
database backup, copies the new server code, and restarts the service.

## Move to another machine on this network

1. On every device, use **Sync now** and confirm notes are up to date. Leave
   further edits until the migration finishes so nothing remains only on a client.
2. Stop the old server and take a final snapshot:

   ```sh
   python3 server/manage_server.py stop
   launchctl disable "gui/$(id -u)/com.example.notefile.server"
   python3 server/manage_server.py backup
   ```

   Copy the resulting dated `.sqlite3` file to the new machine. The snapshot
   contains accounts, password hashes, notes, deletion markers and sync history.
   Do not copy only a live `notes.sqlite3` file while its WAL may contain changes.

3. Copy the project's `server/` directory to the new machine and install Python
   3.10 or later. If the destination is a Mac, install with that Mac's hostname
   and IP, then stop its newly installed service:

   ```sh
   python3 server/manage_server.py install --hostname NEW-MAC.local --lan-ip NEW-IP --port 8766
   python3 server/manage_server.py stop
   ```

4. On the **new Mac only**, preserve its newly created `data` folder by renaming
   the whole folder to a dated `data-before-restore` name. Create a replacement
   `data` folder with permissions `0700`. Put the transferred snapshot there as
   `notes.sqlite3` with permissions `0600`. Preserving the whole previous folder
   keeps any old WAL/SHM files from being mixed with the restored database.
5. Start the new service and check its health:

   ```sh
   python3 server/manage_server.py start
   python3 server/manage_server.py status
   ```

6. On each device, sign out, save the new HTTPS server address, import the new
   machine's public certificate, and sign in with the **same email and password**.
   The account IDs and notes are preserved by the database snapshot. The new
   address has its own local cache; old cached profiles remain separate. No
   password reset or new account is needed.
7. Keep the old server stopped and disabled so edits cannot split between two
   independent databases. Preserve its files and the final snapshot until the
   new server is verified. Step 2 disables future automatic starts as well as
   stopping the current process. To roll back, `manage_server.py start` explicitly
   re-enables the old service; stop/disable the new service first.

For a Windows or Linux destination, the Python server and SQLite snapshot are
portable, but `manage_server.py` installs macOS LaunchAgents only. Use that OS's
service manager to run `notefile_server.py` with `--database`, `--host`, `--port`,
`--tls-cert` and `--tls-key`, or put it behind an HTTPS reverse proxy. Issue a
certificate for the new hostname and update/import it on clients as above.

The underlying API remains a prototype with the account/sync limits described
in [storage and accounts](storage-accounts-and-startup.md). This setup is for a
private local network, with no public internet deployment configured.

References: [Apple LaunchAgents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html),
[SQLite online backup](https://docs.python.org/3/library/sqlite3.html#sqlite3.Connection.backup).
