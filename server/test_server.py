import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from notefile_server import Api, ApiError


def change(text='A note', version=0, mutation='change-1', deleted=False):
    return {'id': 'note-1', 'text': text, 'createdAt': '2026-01-01T00:00:00Z',
            'updatedAt': '2026-01-02T00:00:00Z', 'baseVersion': version,
            'mutationId': mutation, 'deleted': deleted}


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.api = Api(Path(self.temp.name) / 'server.sqlite3', allow_registration=True)
        self.alice = self.account('alice@example.test')
        self.bob = self.account('bob@example.test')

    def account(self, email):
        return self.api.handle('register', {'email': email, 'password': 'test passphrase only'})

    def sync(self, account, changes):
        return self.api.handle('sync', {'changes': changes}, account['token'])

    def test_accounts_cannot_read_or_delete_each_others_notes(self):
        self.sync(self.alice, [change('Alice private')])
        self.assertEqual(self.sync(self.bob, [])['notes'], [])
        self.sync(self.bob, [change('Bob private')])
        self.sync(self.bob, [change('Bob private', 1, 'delete-bob', True)])
        alice = self.sync(self.alice, [])['notes']
        self.assertEqual([n['text'] for n in alice], ['Alice private'])
        self.assertFalse(alice[0]['deleted'])

    def test_credentials_are_hashed_and_sessions_can_be_revoked(self):
        with self.api.connect() as db:
            user = db.execute('SELECT * FROM users WHERE id=?', (self.alice['userId'],)).fetchone()
            tokens = [r[0] for r in db.execute('SELECT token_hash FROM sessions')]
        self.assertNotEqual(user['password_hash'], b'test passphrase only')
        self.assertNotIn(self.alice['token'], tokens)
        self.api.handle('logout', {}, self.alice['token'])
        with self.assertRaises(ApiError) as error:
            self.sync(self.alice, [])
        self.assertEqual(error.exception.status, 401)

    def test_wrong_password_and_expired_tokens_are_rejected(self):
        with self.assertRaises(ApiError):
            self.api.handle('login', {'email': 'alice@example.test', 'password': 'wrong'})
        with self.api.connect() as db:
            db.execute('UPDATE sessions SET expires=0')
        with self.assertRaises(ApiError):
            self.sync(self.alice, [])

    def test_two_devices_can_sign_into_the_same_account(self):
        other = self.api.handle('login', {'email': 'ALICE@example.test', 'password': 'test passphrase only'})
        self.assertEqual(other['userId'], self.alice['userId'])
        self.sync(self.alice, [change('日本語 📝')])
        self.assertEqual(self.sync(other, [])['notes'][0]['text'], '日本語 📝')

    def test_conflicts_preserve_both_edits_and_retries_are_idempotent(self):
        self.sync(self.alice, [change('Original')])
        self.sync(self.alice, [change('Device A', 1, 'edit-a')])
        stale = change('Device B', 1, 'edit-b')
        result = self.sync(self.alice, [stale])
        self.assertEqual(len(result['notes']), 2)
        self.assertTrue(any(n['text'].startswith('Device B') for n in result['notes']))
        self.assertTrue(any(n['text'] == 'Device A' for n in result['notes']))
        self.assertEqual(self.sync(self.alice, [stale]), result)

    def test_empty_drafts_are_not_created_and_clearing_deletes_saved_note(self):
        for index, text in enumerate(('', ' \t\n', '\u00a0\u2003')):
            result = self.sync(self.alice, [change(text, mutation=f'blank-{index}')])
            self.assertEqual(result['notes'], [])
        self.sync(self.alice, [change('Saved content', mutation='content')])
        result = self.sync(self.alice, [change(' \n', 1, 'clear')])
        self.assertTrue(result['notes'][0]['deleted'])
        self.assertEqual(len(result['notes']), 1)
        self.assertEqual(self.sync(self.alice, [change(' \n', 1, 'clear')]), result)

    def test_stale_empty_edit_does_not_delete_other_devices_newer_content(self):
        self.sync(self.alice, [change('Original')])
        self.sync(self.alice, [change('Newer content', 1, 'newer-content')])
        result = self.sync(self.alice, [change('', 1, 'stale-clear')])
        self.assertEqual(len(result['notes']), 1)
        self.assertEqual(result['notes'][0]['text'], 'Newer content')
        self.assertFalse(result['notes'][0]['deleted'])

    def test_conflict_retry_returns_the_same_resolution(self):
        self.sync(self.alice, [change('Original')])
        self.sync(self.alice, [change('Other device', 1, 'other')])
        stale = change('My edit', 1, 'mine')
        first = self.sync(self.alice, [stale])
        resolution = first['resolved'][0]
        self.assertEqual(resolution['sourceId'], stale['id'])
        self.assertNotEqual(resolution['noteId'], stale['id'])
        self.assertEqual(self.sync(self.alice, [stale])['resolved'], first['resolved'])
        continued = {**change('My continued edit', resolution['version'], 'continued'),
                     'id': resolution['noteId']}
        result = self.sync(self.alice, [continued])
        self.assertEqual(len(result['notes']), 2)
        self.assertTrue(any(n['text'] == 'My continued edit' for n in result['notes']))

    def test_stale_delete_does_not_erase_newer_edit(self):
        self.sync(self.alice, [change()])
        self.sync(self.alice, [change('Newer', 1, 'newer')])
        notes = self.sync(self.alice, [change('Old', 1, 'stale-delete', True)])['notes']
        self.assertEqual(notes[0]['text'], 'Newer')
        self.assertFalse(notes[0]['deleted'])

    def test_invalid_batch_rolls_back_all_changes(self):
        invalid = change('invalid', mutation='invalid')
        invalid['deleted'] = 'false'
        with self.assertRaises(ApiError):
            self.sync(self.alice, [change(), invalid])
        self.assertEqual(self.sync(self.alice, [])['notes'], [])

    def test_registration_policy_and_rate_limits_are_enforced(self):
        self.api.allow_registration = False
        with self.assertRaises(ApiError) as error:
            self.account('closed@example.test')
        self.assertEqual(error.exception.status, 403)
        for _ in range(22):
            try:
                self.api.handle('login', {'email': 'alice@example.test', 'password': 'wrong'}, peer='attempts')
            except ApiError as error:
                last_status = error.status
        self.assertEqual(last_status, 429)

    def test_recovery_preserves_notes_and_revokes_only_recovered_accounts_sessions(self):
        self.sync(self.alice, [change('Alice note')])
        other_device = self.api.handle('login', {'email': self.alice['email'], 'password': 'test passphrase only'})
        code = self.api.issue_password_reset(' ALICE@example.test ')
        # Issuing a code does not change credentials or interrupt devices.
        self.assertEqual(len(self.sync(self.alice, [])['notes']), 1)
        with self.api.connect() as db:
            self.assertNotEqual(db.execute('SELECT token_hash FROM password_resets').fetchone()[0], code)
        result = self.api.handle('reset-password', {
            'email': self.alice['email'], 'code': code, 'password': 'new test passphrase only'})
        self.assertEqual(result, {'ok': True})
        for account in (self.alice, other_device):
            with self.assertRaises(ApiError):
                self.sync(account, [])
        with self.assertRaises(ApiError):
            self.api.handle('login', {'email': self.alice['email'], 'password': 'test passphrase only'})
        recovered = self.api.handle('login', {'email': self.alice['email'], 'password': 'new test passphrase only'})
        self.assertEqual(recovered['userId'], self.alice['userId'])
        self.assertEqual(self.sync(recovered, [])['notes'][0]['text'], 'Alice note')
        self.assertEqual(self.sync(self.bob, [])['notes'], [])
        with self.assertRaises(ApiError):
            self.api.handle('reset-password', {'email': self.alice['email'], 'code': code, 'password': 'another passphrase only'})

    def test_recovery_codes_expire_are_account_bound_and_replace_previous_codes(self):
        old_code = self.api.issue_password_reset(self.alice['email'])
        code = self.api.issue_password_reset(self.alice['email'])
        for email, token in ((self.alice['email'], old_code), (self.bob['email'], code),
                             ('missing@example.test', code), (self.alice['email'], 'wrong')):
            with self.assertRaises(ApiError) as error:
                self.api.handle('reset-password', {'email': email, 'code': token, 'password': 'new test passphrase only'})
            self.assertEqual(error.exception.status, 400)
        with self.assertRaises(ApiError):
            self.api.handle('reset-password', {'email': self.alice['email'], 'code': code, 'password': 'short'})
        with self.api.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM password_resets').fetchone()[0], 1)
            db.execute('UPDATE password_resets SET expires=0')
        with self.assertRaises(ApiError):
            self.api.handle('reset-password', {'email': self.alice['email'], 'code': code, 'password': 'new test passphrase only'})
        with self.assertRaises(ApiError):
            self.api.handle('issue-reset', {'email': self.alice['email']}, self.alice['token'])

    def test_only_one_concurrent_recovery_can_use_the_code(self):
        code = self.api.issue_password_reset(self.alice['email'])
        def recover(_):
            try:
                self.api.handle('reset-password', {
                    'email': self.alice['email'], 'code': code, 'password': 'new test passphrase only'})
                return 200
            except ApiError as error:
                return error.status
        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(recover, range(2))), [200, 400])


if __name__ == '__main__':
    unittest.main()
