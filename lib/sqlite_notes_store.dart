import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'draft_store.dart';
import 'notes_store.dart';

/// Each account has a separate notebook. Only its dirty rows enter sync requests.
class SqliteNotesStore implements NotesStore {
  SqliteNotesStore._(this.database);
  final Database database;
  String profile = 'device';
  void Function()? onSaved;

  static Future<SqliteNotesStore> open(Directory directory) async {
    await directory.create(recursive: true);
    final db = sqlite3.open('${directory.path}/notes.sqlite3');
    final store = SqliteNotesStore._(db);
    try {
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA journal_mode = WAL');
      final version =
          db.select('PRAGMA user_version').first.values.first as int;
      if (version > 1) {
        throw const FormatException('Unsupported database version.');
      }
      store.transaction(() {
        db.execute('''CREATE TABLE IF NOT EXISTS profiles (
          id TEXT PRIMARY KEY, selected_id TEXT)''');
        db.execute('''CREATE TABLE IF NOT EXISTS notes (
          profile TEXT NOT NULL REFERENCES profiles(id), id TEXT NOT NULL,
          text TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          deleted INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1,
          server_version INTEGER NOT NULL DEFAULT 0, mutation_id TEXT NOT NULL,
          PRIMARY KEY (profile, id))''');
        db.execute(
          'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        db.execute('PRAGMA user_version = 1');
      });
      if (db.select("SELECT id FROM profiles WHERE id = 'device'").isEmpty) {
        // Parse before inserting a profile: failed migrations can be retried safely.
        final json = File('${directory.path}/notes.json');
        final snapshot = await json.exists()
            ? NotesSnapshot.fromJson(
                jsonDecode(await json.readAsString()) as Map<String, dynamic>,
              )
            : NotesSnapshot.fromDraft(
                (await DraftStore.open(directory)).initialText,
              );
        store.transaction(() {
          db.execute("INSERT INTO profiles (id) VALUES ('device')");
          store._save(snapshot);
        });
      }
      // JSON and the old draft stay untouched as migration backups.
      return store;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  T transaction<T>(T Function() action) {
    database.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      database.execute('COMMIT');
      return result;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  String? setting(String key) =>
      database.select('SELECT value FROM settings WHERE key = ?', [
            key,
          ]).firstOrNull?['value']
          as String?;

  void setSetting(String key, String value) => database.execute(
    'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
    [key, value],
  );

  void useProfile(String id, {String? server, bool importDeviceNotes = false}) {
    final previous = profile;
    try {
      transaction(() {
        database.execute('INSERT OR IGNORE INTO profiles (id) VALUES (?)', [
          id,
        ]);
        profile = id;
        if (importDeviceNotes && id != 'device') _importDeviceNotesOnce();
        if (server != null) setSetting('server', server);
      });
    } catch (_) {
      profile = previous;
      rethrow;
    }
  }

  // Claim legacy device notes for the first authenticated account only. Keep
  // their IDs and timestamps so retries cannot create duplicate uploads.
  void _importDeviceNotesOnce() {
    if (setting('deviceNotesAccount') != null) return;
    final rows = database.select(
      "SELECT * FROM notes WHERE profile='device' AND deleted=0",
    );
    final notes = rows.where(
      (row) => (row['text'] as String).trim().isNotEmpty,
    );
    final existing = database.select(
      'SELECT id, text FROM notes WHERE profile=? AND deleted=0',
      [profile],
    );
    final assigned = <String>{};
    final importedIds = <String, String>{};
    for (final row in notes) {
      // Earlier versions offered a manual copy action that generated new IDs.
      // Reuse those copies one-for-one instead of importing the same text again.
      final match = existing
          .where(
            (item) =>
                !assigned.contains(item['id']) &&
                (item['id'] == row['id'] || item['text'] == row['text']),
          )
          .firstOrNull;
      if (match != null) {
        final id = match['id'] as String;
        assigned.add(id);
        importedIds[row['id'] as String] = id;
        continue;
      }
      database.execute(
        '''INSERT OR IGNORE INTO notes
        (profile, id, text, created_at, updated_at, deleted, dirty, server_version, mutation_id)
        VALUES (?, ?, ?, ?, ?, 0, 1, 0, ?)''',
        [
          profile,
          row['id'],
          row['text'],
          row['created_at'],
          row['updated_at'],
          const Uuid().v4(),
        ],
      );
      importedIds[row['id'] as String] = row['id'] as String;
    }
    if (notes.isNotEmpty) {
      database.execute(
        "DELETE FROM notes WHERE profile=? AND text='' AND deleted=0 AND server_version=0",
        [profile],
      );
      final selected = database
          .select("SELECT selected_id FROM profiles WHERE id='device'")
          .first['selected_id'];
      database.execute('UPDATE profiles SET selected_id=? WHERE id=?', [
        importedIds[selected] ?? importedIds.values.first,
        profile,
      ]);
    }
    setSetting('deviceNotesAccount', profile);
  }

  @override
  NotesSnapshot get initialSnapshot {
    final rows = database.select(
      'SELECT * FROM notes WHERE profile = ? AND deleted = 0 ORDER BY rowid',
      [profile],
    );
    final notes = rows.map(_note).toList();
    if (notes.isEmpty) return NotesSnapshot.empty();
    final selected = database.select(
      'SELECT selected_id FROM profiles WHERE id = ?',
      [profile],
    ).first['selected_id'];
    return NotesSnapshot(
      notes: notes,
      selectedId: notes.any((note) => note.id == selected)
          ? selected as String
          : notes.first.id,
    );
  }

  static Note _note(Row row) => Note(
    id: row['id'] as String,
    text: row['text'] as String,
    createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
    updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
  );

  @override
  Future<void> save(NotesSnapshot snapshot) async {
    transaction(() => _save(snapshot));
    onSaved?.call();
  }

  void _save(NotesSnapshot snapshot) {
    final present = snapshot.notes.map((note) => note.id).toSet();
    final oldRows = database.select('SELECT * FROM notes WHERE profile = ?', [
      profile,
    ]);
    final old = {for (final row in oldRows) row['id'] as String: row};
    for (final note in snapshot.notes) {
      final previous = old[note.id];
      if (previous != null &&
          previous['deleted'] == 0 &&
          previous['text'] == note.text &&
          previous['created_at'] == note.createdAt.toIso8601String() &&
          previous['updated_at'] == note.updatedAt.toIso8601String()) {
        continue;
      }
      database.execute(
        '''INSERT INTO notes
        (profile, id, text, created_at, updated_at, deleted, dirty, server_version, mutation_id)
        VALUES (?, ?, ?, ?, ?, 0, 1, ?, ?)
        ON CONFLICT(profile, id) DO UPDATE SET text=excluded.text,
          updated_at=excluded.updated_at, deleted=0, dirty=1, mutation_id=excluded.mutation_id''',
        [
          profile,
          note.id,
          note.text,
          note.createdAt.toIso8601String(),
          note.updatedAt.toIso8601String(),
          previous?['server_version'] ?? 0,
          const Uuid().v4(),
        ],
      );
    }
    for (final row in oldRows) {
      if (row['deleted'] == 0 && !present.contains(row['id'])) {
        database.execute(
          'UPDATE notes SET deleted=1, dirty=1, mutation_id=? WHERE profile=? AND id=?',
          [const Uuid().v4(), profile, row['id']],
        );
      }
    }
    database.execute('UPDATE profiles SET selected_id=? WHERE id=?', [
      snapshot.selectedId,
      profile,
    ]);
    final placeholder = setting('capturePlaceholder:$profile');
    if (placeholder != null &&
        !snapshot.notes.any(
          (note) => note.id == placeholder && note.text.isEmpty,
        )) {
      database.execute('DELETE FROM settings WHERE key=?', [
        'capturePlaceholder:$profile',
      ]);
    }
  }

  List<Map<String, dynamic>> pendingChanges() => database
      .select(
        "SELECT * FROM notes WHERE profile=? AND dirty=1 AND NOT (text='' AND deleted=0 AND server_version=0)",
        [profile],
      )
      .map(
        (row) => <String, dynamic>{
          ..._note(row).toJson(),
          'deleted': row['deleted'] == 1,
          'baseVersion': row['server_version'],
          'mutationId': row['mutation_id'],
        },
      )
      .toList();

  /// A response must never overwrite an edit made while the request was in flight.
  void applySync(
    Map<String, dynamic> response,
    List<Map<String, dynamic>> sent,
  ) {
    final acknowledged = (response['acknowledged'] as List)
        .cast<String>()
        .toSet();
    final mutations = {
      for (final change in sent) change['id']: change['mutationId'],
    };
    transaction(() {
      final remoteIds = (response['notes'] as List)
          .map((item) => item['id'])
          .toSet();
      if ((response['notes'] as List).any((item) => item['deleted'] != true)) {
        // Only the automatic starter page is disposable. A blank note made
        // with + must stay selected while the user is about to type in it.
        final placeholder = setting('capturePlaceholder:$profile');
        for (final row in database.select(
          "SELECT id FROM notes WHERE profile=? AND id=? AND text='' AND server_version=0 AND deleted=0",
          [profile, placeholder],
        )) {
          if (!remoteIds.contains(row['id'])) {
            database.execute('DELETE FROM notes WHERE profile=? AND id=?', [
              profile,
              row['id'],
            ]);
          }
        }
        database.execute('DELETE FROM settings WHERE key=?', [
          'capturePlaceholder:$profile',
        ]);
      }
      for (final item in response['notes'] as List) {
        final note = Note.fromJson(item as Map<String, dynamic>);
        final local = database.select(
          'SELECT dirty, mutation_id FROM notes WHERE profile=? AND id=?',
          [profile, note.id],
        ).firstOrNull;
        if (local != null &&
            local['dirty'] == 1 &&
            (local['mutation_id'] != mutations[note.id] ||
                !acknowledged.contains(local['mutation_id']))) {
          continue;
        }
        database.execute(
          '''INSERT INTO notes
          (profile, id, text, created_at, updated_at, deleted, dirty, server_version, mutation_id)
          VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
          ON CONFLICT(profile, id) DO UPDATE SET text=excluded.text,
          created_at=excluded.created_at, updated_at=excluded.updated_at,
          deleted=excluded.deleted, dirty=0, server_version=excluded.server_version''',
          [
            profile,
            note.id,
            note.text,
            note.createdAt.toIso8601String(),
            note.updatedAt.toIso8601String(),
            item['deleted'] == true ? 1 : 0,
            item['version'],
            const Uuid().v4(),
          ],
        );
      }
    });
  }

  void copyDeviceNotes() {
    if (profile == 'device') return;
    final deviceNotes = database
        .select("SELECT * FROM notes WHERE profile='device' AND deleted=0")
        .map(_note)
        .where((note) => note.text.trim().isNotEmpty);
    var snapshot = initialSnapshot;
    for (final note in deviceNotes) {
      snapshot = snapshot.add(Note.create(text: note.text));
    }
    transaction(() => _save(snapshot));
    onSaved?.call();
  }

  void close() => database.close();
}
