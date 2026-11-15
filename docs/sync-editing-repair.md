# Editing while syncing

Fixed in 1.0.0+16 (9 November 2026).

The editor now commits each change directly to SQLite before yielding to a sync response. Previously, a queued save could run after a response refreshed the editor, replacing newly typed text and its composing range with an older saved version. Other asynchronous store implementations still serialize their writes.

When an upload is acknowledged while typing continues, SQLite keeps the newer local text and mutation ID but advances its base version to the accepted server revision. Previously, the next upload used the old version and the server created a false conflict copy. The base version only advances when the acknowledgement matches the uploaded text and deletion state; genuine concurrent edits still use conflict preservation. Older responses cannot replace a newer known server revision.

Regression coverage includes a keyboard event immediately after a queued network completion, preserving composing text, a newer edit during an upload, genuine concurrent edits, stale responses, and five successive edits during uploads against the real server with two clients.

## Recovery performed

Mac, iPhone and server databases were backed up outside the repository and iCloud, under `~/Library/Application Support/QJotterRecovery/20261109-sync/`. The final iPhone backup includes its write-ahead log and was copied to a standalone consistent SQLite snapshot, which passed integrity checking.

Thirteen short Restaurant note entries were verified to contain progressively typed prefixes of the same text once the generated conflict marker and trailing whitespace were removed. The longest saved fragment was retained as one note, and the twelve redundant entries were marked deleted through server revisions. Their original text remains in server tombstones and full database backups. The unrelated Restaurants reference note was left intact. No words absent from the saved copies were invented.

The server also keeps a `before-restaurant-repair-*.sqlite3` backup in its normal backups directory. The recovery folder includes the exact expected versions and repair script, which aborts if any targeted note has changed.

Additional fragments with shortened titles were subsequently found in the same original note creation group. All unique saved fragments are exported to `Recovered Restaurant app.txt` in the recovery folder. Newer user edits and deletions made while verification was underway were preserved; both clients subsequently received server revision 321 for the surviving Restaurant app note. The current server has one live note in that original creation group.

## Follow-up in 1.0.0+17

The client now writes an upload to a persistent SQLite outbox before sending it. A lost response is retried using the same mutation ID and payload, including after restart or continued typing. Once acknowledged, the next edit uses the accepted server revision.

The server now records each accepted operation's destination note and version. A genuine concurrent edit can create one conflict copy, and the client follows that copy for continued typing. The original other-device version remains intact. The server returns the same operation result on retries. Both additions use separate additive SQLite tables and preserve existing accounts and notes.

New empty and whitespace-only drafts remain local. Clearing an existing server note sends a tombstone; its blank capture page remains available locally for typing again. Clearing during an upload first acknowledges the frozen upload and then sends the deletion. The server independently treats whitespace-only content as deletion, ignores never-saved empty drafts, and retires existing empty entries on sync. A stale clear cannot erase newer content from another device.

The five Queensland landscape versions were backed up and exported as complete text files under `~/Library/Application Support/QJotterRecovery/20261109-duplicates/Queensland saved versions/`. Four older generated conflict copies were archived with server deletion revisions; the latest original note was not modified. Text removed during later editing was not silently restored. Server tombstones and pre-archive database backups retain the old versions.

Regression tests cover persistent retry after restart, exact retries after a lost HTTP response, continued typing on a genuine conflict copy through multiple real-server syncs, Unicode whitespace, clearing existing notes, and clearing while an upload is in flight. The real-server integration test verifies removal on a second device and subsequent typing into the same local draft.
