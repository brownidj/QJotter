"""Copy Junecloud records individually into an account's local sync queue.

Keep the destination app closed while applying; reopen it to upload normally.
The source database and server database are only read, never modified here.
"""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
import uuid


def readonly(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)


def timestamp(value):
    date = datetime.fromtimestamp(value, timezone.utc)
    # Match Dart DateTime.toIso8601String, including .000 for whole seconds.
    precision = 'milliseconds' if date.microsecond % 1000 == 0 else 'microseconds'
    return date.isoformat(timespec=precision).replace('+00:00', 'Z')


def read_entries(path, include_archived=False):
    with closing(readonly(path)) as db:
        rows = db.execute('''SELECT Z_PK,ZUUID,ZTEXT,ZDATE,ZMODIFIED,ZARCHIVED
            FROM ZNOTE WHERE COALESCE(ZREMOVED,0)=0
            AND (? OR COALESCE(ZARCHIVED,0)=0) ORDER BY Z_PK''',
            (include_archived,)).fetchall()
    entries = []
    for pk, source_id, text, created, modified, archived in rows:
        if not isinstance(source_id, str) or not source_id or not isinstance(text, str):
            raise ValueError(f'Invalid source record {pk}; nothing imported.')
        if len(text.encode('utf-8')) > 256 * 1024:
            raise ValueError(f'Source record {pk} exceeds the server note limit.')
        entries.append({
            'id': 'junecloud-' + hashlib.sha256(source_id.encode()).hexdigest(),
            'sourceId': source_id, 'sourceRecord': pk,
            'text': text, 'archived': bool(archived),
            # Junecloud stores Unix timestamps, rather than Core Data's epoch.
            'createdAt': timestamp(created),
            'updatedAt': timestamp(modified),
        })
    if len({entry['id'] for entry in entries}) != len(entries):
        raise ValueError('Source has duplicate note identifiers; nothing imported.')
    return entries


def import_entries(db, profile, entries):
    """One insert per note, one transaction; retrying never duplicates a note."""
    inserted = skipped = 0
    with db:
        db.execute('BEGIN IMMEDIATE')
        if not profile.startswith('account:') or not db.execute(
            'SELECT 1 FROM profiles WHERE id=?', (profile,),
        ).fetchone():
            raise ValueError('Choose an existing signed-in account profile.')
        for entry in entries:
            old = db.execute('''SELECT text,created_at,updated_at,deleted
                FROM notes WHERE profile=? AND id=?''', (profile, entry['id'])).fetchone()
            expected = (entry['text'], entry['createdAt'], entry['updatedAt'], 0)
            if old is not None:
                if tuple(old) != expected:
                    raise ValueError('An earlier imported entry was edited or deleted; nothing overwritten.')
                skipped += 1
                continue
            db.execute('''INSERT INTO notes
                (profile,id,text,created_at,updated_at,deleted,dirty,server_version,mutation_id)
                VALUES (?,?,?,?,?,0,1,0,?)''',
                (profile, entry['id'], entry['text'], entry['createdAt'],
                 entry['updatedAt'], str(uuid.uuid4())))
            inserted += 1
        count, size = db.execute('''SELECT COUNT(*),COALESCE(SUM(length(CAST(text AS BLOB))),0)
            FROM notes WHERE profile=?''', (profile,)).fetchone()
        if count > 1000 or size > 8 * 1024 * 1024:
            raise ValueError('The import would exceed server capacity; nothing imported.')
    return inserted, skipped


def backup(source, destination):
    with closing(readonly(source)) as src, closing(sqlite3.connect(destination)) as dst:
        src.backup(dst)
        if dst.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Backup integrity check failed.')
    destination.chmod(0o600)


def main():
    home = Path.home()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=home / 'Library/Containers/com.junecloud.mac.Notefile/Data/Library/Application Support/Notefile/Notefile.sqlite')
    parser.add_argument('--destination', type=Path, default=home / 'Library/Containers/com.example.notefile/Data/Library/Application Support/com.example.notefile/notes.sqlite3')
    parser.add_argument('--server-database', type=Path, default=home / 'Library/Application Support/NotefileServer/data/notes.sqlite3')
    parser.add_argument('--backup-root', type=Path, default=home / 'Library/Application Support/NotefileMigrations')
    parser.add_argument('--profile')
    parser.add_argument('--include-archived', action='store_true')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    with closing(readonly(args.destination)) as db:
        profiles = [row[0] for row in db.execute("SELECT id FROM profiles WHERE id LIKE 'account:%'")]
    profile = args.profile or (profiles[0] if len(profiles) == 1 else None)
    if profile not in profiles:
        parser.error('Specify the intended existing account with --profile.')
    entries = read_entries(args.source, args.include_archived)
    print(f'Source: {len(entries)} entries, including {sum(e["archived"] for e in entries)} archived.')
    if not args.apply:
        print('Preview only. Close the destination app and add --apply to copy.')
        return
    folder = args.backup_root / ('junecloud-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
    folder.mkdir(parents=True, mode=0o700)
    backup(args.source, folder / 'junecloud.sqlite3')
    backup(args.destination, folder / 'app-before-import.sqlite3')
    backup(args.server_database, folder / 'server-before-import.sqlite3')
    entries = read_entries(folder / 'junecloud.sqlite3', args.include_archived)
    with closing(sqlite3.connect(args.destination, timeout=10)) as db:
        inserted, skipped = import_entries(db, profile, entries)
    manifest = {
        'profile': profile, 'inserted': inserted, 'skipped': skipped,
        'entries': [{k: v for k, v in entry.items() if k != 'text'} | {
            'sha256': hashlib.sha256(entry['text'].encode()).hexdigest(),
            'utf8Bytes': len(entry['text'].encode()),
        } for entry in entries],
    }
    report = folder / 'manifest.json'
    report.write_text(json.dumps(manifest, indent=2) + '\n')
    report.chmod(0o600)
    print(f'Copied {inserted} separate entries; {skipped} were already copied.')
    print(f'Backups and verification manifest: {folder}')
    print('Reopen Notefile to sync these entries to the server.')


if __name__ == '__main__':
    main()
