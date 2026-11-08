import sqlite3
from contextlib import closing
import tempfile
import unittest
from pathlib import Path

from import_junecloud_notes import import_entries, read_entries


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / 'source.sqlite'
        with closing(sqlite3.connect(self.source)) as db, db:
            db.execute('CREATE TABLE ZNOTE (Z_PK,ZUUID,ZTEXT,ZDATE,ZMODIFIED,ZARCHIVED,ZREMOVED)')
            db.executemany('INSERT INTO ZNOTE VALUES (?,?,?,?,?,?,?)', [
                (1, 'one', 'Title\n\nExact Unicode 📝\r\nlast line  ', 1347087139, 1791785482.233024, 0, 0),
                (2, 'two', 'An archived entry', 1347087139, 1791785482, 1, 0),
                (3, 'three', 'Removed entry', 1347087139, 1791785482, 0, 1),
            ])
        self.db = sqlite3.connect(':memory:')
        self.addCleanup(self.db.close)
        self.db.executescript('''CREATE TABLE profiles(id TEXT PRIMARY KEY);
            INSERT INTO profiles VALUES ('account:test');
            CREATE TABLE notes(profile,id,text,created_at,updated_at,deleted,dirty,server_version,mutation_id,
              PRIMARY KEY(profile,id));''')

    def test_separate_entries_preserve_text_dates_archive_and_repeat_safely(self):
        self.assertEqual(len(read_entries(self.source)), 1)
        entries = read_entries(self.source, include_archived=True)
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[0]['createdAt'], '2012-09-08T06:52:19.000Z')
        self.assertEqual(import_entries(self.db, 'account:test', entries), (2, 0))
        self.assertEqual(import_entries(self.db, 'account:test', entries), (0, 2))
        self.assertEqual(self.db.execute('SELECT text FROM notes WHERE id=?', (entries[0]['id'],)).fetchone()[0],
                         'Title\n\nExact Unicode 📝\r\nlast line  ')
        self.assertEqual(self.db.execute('SELECT SUM(dirty),SUM(server_version) FROM notes').fetchone(), (2, 0))
        self.assertEqual(len(read_entries(self.source, True)), 2)

    def test_failure_rolls_back_all_entries_and_preserves_earlier_edits(self):
        entries = read_entries(self.source, True)
        import_entries(self.db, 'account:test', [entries[1]])
        self.db.execute('UPDATE notes SET text=?', ('User edited this copy',))
        self.db.commit()
        with self.assertRaises(ValueError):
            import_entries(self.db, 'account:test', entries)
        self.assertEqual(self.db.execute('SELECT text FROM notes').fetchall(), [('User edited this copy',)])

    def test_device_profile_is_never_a_destination(self):
        with self.assertRaises(ValueError):
            import_entries(self.db, 'device', read_entries(self.source))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM notes').fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()
