import json
import plistlib
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch, Mock

import manage_server as management
from notefile_server import Api


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.patch = patch.object(management, 'ROOT', self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.config = {'database': str(self.root / 'live.sqlite3'), 'python': 'python3',
                       'backups_enabled': True, 'backup_hour': 3, 'backup_minute': 0,
                       'backup_retention_days': 30}

    def test_server_prevents_idle_sleep_only_while_running(self):
        config = {**self.config, 'listen_host': '0.0.0.0', 'port': 8767,
                  'certificate': 'public.pem', 'private_key': 'private.pem',
                  'allow_registration': False}
        plist = self.root / 'agents/server.plist'
        with patch.object(management, 'PLIST', plist), patch.object(management, 'run', return_value=Mock(returncode=0)):
            management.write_plist(config)
            data = plistlib.loads(plist.read_bytes())
            self.assertEqual(data['ProgramArguments'][:3], ['/usr/bin/caffeinate', '-i', 'python3'])
            self.assertTrue(data['KeepAlive'])
            self.assertNotIn('-d', data['ProgramArguments'])
            management.write_plist({**config, 'keep_awake': False})
            data = plistlib.loads(plist.read_bytes())
            self.assertEqual(data['ProgramArguments'][0], 'python3')

    def test_backup_restores_committed_wal_and_accounts_with_private_permissions(self):
        api = Api(self.config['database'], allow_registration=True)
        user = api.handle('register', {'email': 'alice@example.test', 'password': 'test passphrase only'})
        api.handle('sync', {'changes': [{
            'id': 'note-1', 'text': 'A backed-up note',
            'createdAt': '2026-01-01T00:00:00Z', 'updatedAt': '2026-01-01T00:00:00Z',
            'mutationId': 'test-mutation', 'baseVersion': 0, 'deleted': False,
        }]}, user['token'])
        # Keep a WAL reader alive to prove the backup includes committed WAL data.
        with api.connect() as live:
            live.execute('BEGIN')
            live.execute('SELECT * FROM users').fetchall()
            api.handle('register', {'email': 'bob@example.test', 'password': 'test passphrase only'})
            target = management.backup(self.config)
        restored = Api(target)
        logged_in = restored.handle('login', {'email': user['email'], 'password': 'test passphrase only'})
        self.assertEqual(logged_in['userId'], user['userId'])
        self.assertEqual(restored.handle('sync', {'changes': []}, logged_in['token'])['notes'][0]['text'], 'A backed-up note')
        with restored.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM users').fetchone()[0], 2)
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)

    def test_failed_backup_leaves_no_final_or_partial_copy_and_records_failure(self):
        Path(self.config['database']).write_text('not a database')
        with self.assertRaises(sqlite3.DatabaseError):
            management.scheduled_backup(self.config)
        self.assertEqual(list((self.root / 'backups').glob('*.sqlite3*')), [])
        state = json.loads((self.root / 'backup-status.json').read_text())
        self.assertIsNotNone(state['error'])
        self.assertNotIn('last_success', state)

    def test_retention_preserves_manual_copies_and_at_least_thirty_scheduled_copies(self):
        directory = self.root / 'backups'
        directory.mkdir()
        old = datetime.now(timezone.utc) - timedelta(days=90)
        for index in range(35):
            stamp = (old + timedelta(days=index)).strftime('%Y%m%dT%H%M%S%fZ')
            (directory / f'scheduled-{stamp}.sqlite3').touch()
        manual = directory / 'notefile-20200101T000000000000Z.sqlite3'
        manual.touch()
        management.prune_backups(self.config)
        self.assertEqual(len(list(directory.glob('scheduled-*.sqlite3'))), 30)
        self.assertTrue(manual.exists())

    def test_successful_scheduled_backup_records_verified_snapshot(self):
        Api(self.config['database'])
        management.scheduled_backup(self.config)
        state = json.loads((self.root / 'backup-status.json').read_text())
        self.assertIsNone(state['error'])
        self.assertTrue(Path(state['path']).is_file())
        self.assertEqual((self.root / 'backup-status.json').stat().st_mode & 0o777, 0o600)

    def test_schedule_runs_at_login_and_three_am_from_installed_copy(self):
        (self.root / 'agents').mkdir()
        plist = self.root / 'agents/backup.plist'
        with patch.object(management, 'BACKUP_PLIST', plist), patch.object(management, 'run', return_value=Mock(returncode=0)):
            management.configure_backups(self.config)
        data = plistlib.loads(plist.read_bytes())
        self.assertEqual(data['StartCalendarInterval'], {'Hour': 3, 'Minute': 0})
        self.assertTrue(data['RunAtLoad'])
        self.assertNotIn('KeepAlive', data)
        self.assertEqual(data['ProgramArguments'][-2:], [str(self.root / 'app/manage_server.py'), 'scheduled-backup'])
        self.assertEqual(plist.stat().st_mode & 0o777, 0o600)
        for name in ('backup.log', 'backup-error.log'):
            self.assertEqual((self.root / 'logs' / name).stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
