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
      db.execute('''CREATE TABLE IF NOT EXISTS sync_outbox (
        profile TEXT NOT NULL, id TEXT NOT NULL, change_json TEXT NOT NULL,
        PRIMARY KEY(profile, id))''');
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

  /// Copy the active cache and outbox when the same server database moves.
  /// Preserve an older destination cache separately, rather than uploading it.
  /// The marker prevents a later retry from recopying a stale source cache.
  void migrateServerProfile(String source, String target, {String? server}) {
    if (source == target) return;
    transaction(() {
      final marker = 'serverMigration:$source:$target';
      if (setting(marker) != null) return;
      final current = database.select(
        'SELECT selected_id FROM profiles WHERE id=?',
        [source],
      ).firstOrNull;
      if (current == null) throw StateError('Missing migration source profile');
      final existing = database.select(
        'SELECT selected_id FROM profiles WHERE id=?',
        [target],
      ).firstOrNull;
      if (existing != null) {
        final archive = '$target:before-migration:${const Uuid().v4()}';
        database.execute('INSERT INTO profiles VALUES (?,?)', [
          archive,
          existing['selected_id'],
        ]);
        database.execute('UPDATE notes SET profile=? WHERE profile=?', [
          archive,
          target,
        ]);
        database.execute('UPDATE sync_outbox SET profile=? WHERE profile=?', [
          archive,
          target,
        ]);
        database.execute('DELETE FROM profiles WHERE id=?', [target]);
      }
      database.execute('INSERT INTO profiles VALUES (?,?)', [
        target,
        current['selected_id'],
      ]);
      database.execute(
        'INSERT INTO notes SELECT ?,id,text,created_at,updated_at,deleted,dirty,server_version,mutation_id FROM notes WHERE profile=?',
        [target, source],
      );
      database.execute(
        'INSERT INTO sync_outbox SELECT ?,id,change_json FROM sync_outbox WHERE profile=?',
        [target, source],
      );
      final placeholder = setting('capturePlaceholder:$source');
      if (placeholder != null) {
        setSetting('capturePlaceholder:$target', placeholder);
      }
      if (setting('deviceNotesAccount') == source) {
        setSetting('deviceNotesAccount', target);
      }
      if (server != null) setSetting('server', server);
      setSetting(marker, 'complete');
    });
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
      .select('SELECT * FROM notes WHERE profile=? AND dirty=1', [profile])
      .where(
        (row) =>
            (row['text'] as String).trim().isNotEmpty ||
            row['deleted'] == 1 ||
            (row['server_version'] as int) > 0,
      )
      .map(
        (row) => <String, dynamic>{
          ..._note(row).toJson(),
          'deleted':
              row['deleted'] == 1 || (row['text'] as String).trim().isEmpty,
          'baseVersion': row['server_version'],
          'mutationId': row['mutation_id'],
        },
      )
      .toList();

  /// Count records, not mutations: a retry and a newer edit of the same note
  /// share one LED count. Empty never-uploaded drafts are excluded.
  int get pendingSyncCount => <String>{
    for (final change in pendingChanges()) change['id'] as String,
    for (final row in database.select(
      'SELECT id FROM sync_outbox WHERE profile=?',
      [profile],
    ))
      row['id'] as String,
  }.length;

  /// Persist the exact upload before sending it. If the response is lost,
  /// retry that mutation before sending text typed in the meantime.
  List<Map<String, dynamic>> prepareSyncChanges() => transaction(() {
    final changes = <String, Map<String, dynamic>>{
      for (final row in database.select(
        'SELECT id,change_json FROM sync_outbox WHERE profile=?',
        [profile],
      ))
        row['id'] as String:
            jsonDecode(row['change_json'] as String) as Map<String, dynamic>,
    };
    for (final change in pendingChanges()) {
      final id = change['id'] as String;
      if (changes.containsKey(id)) continue;
      database.execute('INSERT INTO sync_outbox VALUES (?,?,?)', [
        profile,
        id,
        jsonEncode(change),
      ]);
      changes[id] = change;
    }
    return changes.values.toList();
  });

  /// A response must never overwrite an edit made while the request was in flight.
  void applySync(
    Map<String, dynamic> response,
    List<Map<String, dynamic>> sent,
  ) {
    final acknowledged = (response['acknowledged'] as List)
        .cast<String>()
        .toSet();
    final mutations = {for (final change in sent) change['id']: change};
    transaction(() {
      final resolutions = <String, Map<String, dynamic>>{};
      for (final raw in (response['resolved'] as List? ?? const [])) {
        final result = raw as Map<String, dynamic>;
        final source = result['sourceId'] as String;
        final uploaded = mutations[source];
        if (uploaded == null ||
            result['mutationId'] != uploaded['mutationId'] ||
            !acknowledged.contains(result['mutationId'])) {
          continue;
        }
        final target = result['noteId'] as String;
        resolutions[target] = result;
        if (source != target) {
          // Follow our own conflict copy. Continued typing belongs to this
          // copy, not to the other device's version of the original note.
          final local = database.select(
            'SELECT * FROM notes WHERE profile=? AND id=?',
            [profile, source],
          ).firstOrNull;
          if (local != null && local['dirty'] == 1) {
            database.execute('DELETE FROM notes WHERE profile=? AND id=?', [
              profile,
              target,
            ]);
            database.execute(
              'UPDATE notes SET id=?,server_version=? WHERE profile=? AND id=?',
              [target, result['version'], profile, source],
            );
            database.execute(
              'UPDATE profiles SET selected_id=? WHERE id=? AND selected_id=?',
              [target, profile, source],
            );
          }
          mutations[target] = uploaded;
        }
      }
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
          'SELECT dirty, mutation_id, server_version, text FROM notes WHERE profile=? AND id=?',
          [profile, note.id],
        ).firstOrNull;
        if (local != null &&
            (item['version'] as int) < (local['server_version'] as int)) {
          continue;
        }
        final uploaded = mutations[note.id];
        if (local != null &&
            local['dirty'] == 1 &&
            (local['mutation_id'] != uploaded?['mutationId'] ||
                !acknowledged.contains(local['mutation_id']))) {
          // An earlier edit of THIS note was accepted while the user kept
          // typing. Keep the new text and mutation, but base its next upload
          // on that accepted revision. A genuine conflict has different
          // remote text, so must not advance the local edit's base version.
          final resolvedVersion = resolutions[note.id]?['version'];
          if (uploaded != null &&
              acknowledged.contains(uploaded['mutationId']) &&
              (resolvedVersion != null ||
                  (uploaded['text'] == note.text &&
                      uploaded['deleted'] == (item['deleted'] == true)))) {
            database.execute(
              'UPDATE notes SET server_version=? WHERE profile=? AND id=?',
              [resolvedVersion ?? item['version'], profile, note.id],
            );
          }
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
            item['deleted'] == true &&
                    !(local != null &&
                        (local['text'] as String).trim().isEmpty &&
                        uploaded?['deleted'] == true &&
                        acknowledged.contains(uploaded?['mutationId']))
                ? 1
                : 0,
            item['version'],
            const Uuid().v4(),
          ],
        );
      }
      for (final change in sent) {
        if (acknowledged.contains(change['mutationId'])) {
          database.execute(
            'DELETE FROM sync_outbox WHERE profile=? AND id=? AND change_json=?',
            [profile, change['id'], jsonEncode(change)],
          );
        }
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
