import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/notes_store.dart';
import 'package:qjotter/sqlite_notes_store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  final stores = <SqliteNotesStore>[];
  Future<SqliteNotesStore> open() async {
    final store = await NotesStore.open(directory);
    stores.add(store);
    return store;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'notefile-notebook-test-',
    );
  });
  tearDown(() async {
    for (final store in stores) {
      store.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  test(
    'Migrates the existing draft once, preserving its original file',
    () async {
      final legacy = File('${directory.path}/quick_capture_draft.txt');
      await legacy.writeAsString('Existing note\n日本語 📝');
      final store = await open();
      expect(store.initialSnapshot.notes, hasLength(1));
      expect(store.initialSnapshot.selected.text, 'Existing note\n日本語 📝');
      expect(await legacy.readAsString(), 'Existing note\n日本語 📝');
      await legacy.writeAsString('An old app changed the legacy file');
      expect(
        (await open()).initialSnapshot.selected.text,
        'Existing note\n日本語 📝',
      );
    },
  );

  test('Multiple notes and the selected note survive reopening', () async {
    final store = await open();
    final first = store.initialSnapshot.editSelected('First note\nText');
    final second = Note.create(text: 'Second note\nText');
    final notes = first.add(second).select(first.selectedId);
    await store.save(notes);
    final restored = (await open()).initialSnapshot;
    expect(restored.notes.map((note) => note.text), [
      'First note\nText',
      'Second note\nText',
    ]);
    expect(restored.selectedId, first.selectedId);
  });

  test('Titles use the first nonempty line, including Unicode', () {
    expect(Note.create(text: '\n  日本語 📝  \nBody').title, '日本語 📝');
    expect(Note.create(text: '\n  \n').title, 'Untitled note');
  });

  test('Editing a note updates its date without changing the other notes', () {
    final first = Note.create(text: 'First', now: DateTime.utc(2026, 1, 1));
    final second = Note.create(text: 'Second', now: DateTime.utc(2026, 1, 2));
    final notes = NotesSnapshot(
      notes: [first, second],
      selectedId: first.id,
    ).editSelected('Edited', now: DateTime.utc(2026, 1, 3));
    expect(notes.recentFirst.first.id, first.id);
    expect(notes.selected.createdAt, first.createdAt);
    expect(notes.notes.last.text, 'Second');
    expect(notes.notes.last.updatedAt, second.updatedAt);
  });

  test('Deleting the last note leaves an empty capture page', () {
    final notes = NotesSnapshot.fromDraft('Last note').removeSelected();
    expect(notes.notes, isEmpty);
    expect(notes.selected.text, isEmpty);
  });

  test(
    'Invalid data is reported without replacing the saved notebook',
    () async {
      final file = File('${directory.path}/notes.json');
      const invalid = '{not valid JSON';
      await file.writeAsString(invalid);
      await expectLater(open(), throwsFormatException);
      expect(await file.readAsString(), invalid);
    },
  );

  test(
    'Duplicate IDs, missing selections and unsupported versions are rejected',
    () {
      final note = Note.create();
      expect(
        () => NotesSnapshot(notes: [note, note], selectedId: note.id),
        throwsFormatException,
      );
      expect(
        () => NotesSnapshot(notes: [note], selectedId: 'missing'),
        throwsFormatException,
      );
      final json = NotesSnapshot(notes: [note], selectedId: note.id).toJson();
      json['version'] = 99;
      expect(() => NotesSnapshot.fromJson(json), throwsFormatException);
    },
  );

  test('A failed write leaves the previous notebook intact', () async {
    final store = await open();
    await store.save(store.initialSnapshot.editSelected('Keep me'));
    store.database.execute(
      "CREATE TRIGGER fail_edit BEFORE UPDATE OF text ON notes BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
    );
    await expectLater(
      store.save(store.initialSnapshot.editSelected('Failed edit')),
      throwsA(isA<SqliteException>()),
    );
    expect((await open()).initialSnapshot.selected.text, 'Keep me');
  });

  test(
    'JSON migration is transactional and the original file stays intact',
    () async {
      final snapshot = NotesSnapshot.fromDraft('JSON notebook 📝')
          .add(Note.create(text: 'Second'));
      final original = jsonEncode(snapshot.toJson());
      final file = File('${directory.path}/notes.json');
      await file.writeAsString(original);
      final store = await open();
      final restored = store.initialSnapshot;
      expect(restored.selected.text, 'Second');
      expect(restored.notes, hasLength(2));
      expect(await file.readAsString(), original);
      await store.save(restored.editSelected('Recovered'));
      expect((await open()).initialSnapshot.selected.text, 'Recovered');
      final bytes = await File('${directory.path}/notes.sqlite3')
          .openRead(0, 16)
          .fold<List<int>>([], (a, b) => a..addAll(b));
      expect(ascii.decode(bytes), 'SQLite format 3\u0000');
    },
  );

  test('Account notebooks stay isolated, including pending uploads', () async {
    final store = await open();
    await store.save(store.initialSnapshot.editSelected('Private device note'));
    store.useProfile('alice');
    await store.save(store.initialSnapshot.editSelected('Alice only'));
    store.useProfile('bob');
    await store.save(store.initialSnapshot.editSelected('Bob only'));
    expect(store.pendingChanges().map((item) => item['text']), ['Bob only']);
    store.useProfile('alice');
    expect(store.initialSnapshot.selected.text, 'Alice only');
    store.useProfile('device');
    expect(store.initialSnapshot.selected.text, 'Private device note');
  });

  test('A failed account switch keeps the previous notebook active', () async {
    final store = await open();
    await store.save(store.initialSnapshot.editSelected('Keep device profile'));
    store.database.execute(
      "CREATE TRIGGER fail_account BEFORE INSERT ON profiles BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
    );
    expect(() => store.useProfile('alice'), throwsA(isA<SqliteException>()));
    expect(store.profile, 'device');
    expect(store.initialSnapshot.selected.text, 'Keep device profile');
  });

  test('Sync keeps a newer edit made while a request was in flight', () async {
    final store = await open();
    await store.save(store.initialSnapshot.editSelected('Sent edit'));
    final sent = store.pendingChanges();
    await store.save(store.initialSnapshot.editSelected('Newer offline edit'));
    store.applySync({
      'notes': [
        {...sent.single, 'version': 1},
      ],
      'acknowledged': [sent.single['mutationId']],
    }, sent);
    expect(store.initialSnapshot.selected.text, 'Newer offline edit');
    expect(store.pendingChanges(), hasLength(1));
    final latest = store.pendingChanges();
    expect(latest.single['baseVersion'], 1);
    expect(latest.single['mutationId'], isNot(sent.single['mutationId']));
    store.applySync({
      'notes': [
        {...latest.single, 'version': 2},
      ],
      'acknowledged': [latest.single['mutationId']],
    }, latest);
    expect(store.pendingChanges(), isEmpty);
  });

  test(
    'An acknowledged upload preserves a newer edit across restart',
    () async {
      final store = await open();
      store.useProfile('alice');
      await store.save(store.initialSnapshot.editSelected('Before upload'));
      final sent = store.pendingChanges();
      final id = sent.single['id'];
      await store.save(
        store.initialSnapshot.editSelected('Continued typing 日本語 📝'),
      );
      final newerMutation = store.pendingChanges().single['mutationId'];
      final reply = {
        'notes': [
          {...sent.single, 'version': 7},
        ],
        'acknowledged': [sent.single['mutationId']],
      };
      store.applySync(reply, sent);
      // Replaying an acknowledgement must not clear the newer pending edit.
      store.applySync(reply, sent);
      final reopened = await open();
      reopened.useProfile('alice');
      expect(reopened.initialSnapshot.selectedId, id);
      expect(reopened.initialSnapshot.selected.text, 'Continued typing 日本語 📝');
      expect(reopened.pendingChanges().single['baseVersion'], 7);
      expect(reopened.pendingChanges().single['mutationId'], newerMutation);
    },
  );

  test(
    'Deleting during an upload keeps the deletion and advances its base',
    () async {
      final store = await open();
      await store.save(
        store.initialSnapshot.editSelected('Delete during upload'),
      );
      final sent = store.pendingChanges();
      await store.save(store.initialSnapshot.removeSelected());
      final deletionMutation = store.pendingChanges().single['mutationId'];
      store.applySync({
        'notes': [
          {...sent.single, 'version': 8},
        ],
        'acknowledged': [sent.single['mutationId']],
      }, sent);
      expect(store.initialSnapshot.notes, isEmpty);
      final deletion = store.pendingChanges().single;
      expect(deletion['deleted'], isTrue);
      expect(deletion['baseVersion'], 8);
      expect(deletion['mutationId'], deletionMutation);
      store.applySync(
        {
          'notes': [
            {...deletion, 'version': 9},
          ],
          'acknowledged': [deletionMutation],
        },
        [deletion],
      );
      expect(store.initialSnapshot.notes, isEmpty);
      expect(store.pendingChanges(), isEmpty);
    },
  );

  test('An unacknowledged upload cannot advance a newer edit base', () async {
    final store = await open();
    await store.save(
      store.initialSnapshot.editSelected('Upload not acknowledged'),
    );
    final sent = store.pendingChanges();
    await store.save(
      store.initialSnapshot.editSelected('Keep the pending text'),
    );
    store.applySync({
      'notes': [
        {...sent.single, 'version': 10},
      ],
      'acknowledged': <String>[],
    }, sent);
    expect(store.initialSnapshot.selected.text, 'Keep the pending text');
    expect(store.pendingChanges().single['baseVersion'], 0);
  });

  test(
    'Lost upload responses retry the same mutation after edits and restart',
    () async {
      final store = await open();
      store.useProfile('alice');
      await store.save(
        store.initialSnapshot.editSelected('Sent before disconnect'),
      );
      final first = store.prepareSyncChanges();
      await store.save(
        store.initialSnapshot.editSelected('Typed after disconnect'),
      );
      final reopened = await open();
      reopened.useProfile('alice');
      expect(reopened.prepareSyncChanges(), first);
      reopened.applySync({
        'notes': [
          {...first.single, 'version': 11},
        ],
        'acknowledged': [first.single['mutationId']],
      }, first);
      final next = reopened.prepareSyncChanges().single;
      expect(next['text'], 'Typed after disconnect');
      expect(next['baseVersion'], 11);
      expect(next['mutationId'], isNot(first.single['mutationId']));
    },
  );

  test('New empty and Unicode whitespace drafts never enter uploads', () async {
    final store = await open();
    for (final text in ['', ' \t\n', '\u00a0\u2003']) {
      await store.save(store.initialSnapshot.editSelected(text));
      expect(store.prepareSyncChanges(), isEmpty);
      expect(store.initialSnapshot.selected.text, text);
    }
  });

  test(
    'Clearing a saved note deletes its server copy and retains a local draft',
    () async {
      final store = await open();
      await store.save(store.initialSnapshot.editSelected('Previously saved'));
      final original = store.prepareSyncChanges();
      store.applySync({
        'notes': [
          {...original.single, 'version': 1},
        ],
        'acknowledged': [original.single['mutationId']],
      }, original);
      final id = store.initialSnapshot.selectedId;
      await store.save(store.initialSnapshot.editSelected(' \n'));
      final cleared = store.prepareSyncChanges();
      expect(cleared.single['deleted'], isTrue);
      store.applySync({
        'notes': [
          {...cleared.single, 'version': 2},
        ],
        'acknowledged': [cleared.single['mutationId']],
      }, cleared);
      expect(store.prepareSyncChanges(), isEmpty);
      expect(store.initialSnapshot.selectedId, id);
      expect(store.initialSnapshot.selected.text.trim(), isEmpty);
      await store.save(store.initialSnapshot.editSelected('A fresh thought'));
      final fresh = store.prepareSyncChanges().single;
      expect(fresh['deleted'], isFalse);
      expect(fresh['baseVersion'], 2);
    },
  );

  test(
    'Clearing during an upload follows the acknowledgement with a deletion',
    () async {
      final store = await open();
      await store.save(store.initialSnapshot.editSelected('Uploading'));
      final sent = store.prepareSyncChanges();
      await store.save(store.initialSnapshot.editSelected(''));
      expect(store.prepareSyncChanges(), sent);
      store.applySync({
        'notes': [
          {...sent.single, 'version': 1},
        ],
        'acknowledged': [sent.single['mutationId']],
      }, sent);
      final deletion = store.prepareSyncChanges().single;
      expect(deletion['deleted'], isTrue);
      expect(deletion['baseVersion'], 1);
      expect(store.initialSnapshot.selected.text, isEmpty);
    },
  );

  test(
    'A conflict resolution keeps continued typing on its own copy',
    () async {
      final store = await open();
      store.useProfile('alice');
      await store.save(store.initialSnapshot.editSelected('My first edit'));
      final sent = store.prepareSyncChanges();
      final source = sent.single['id'];
      await store.save(store.initialSnapshot.editSelected('My continued edit'));
      store.applySync({
        'notes': [
          {...sent.single, 'text': 'Other device edit', 'version': 2},
          {...sent.single, 'id': 'my-conflict-copy', 'version': 3},
        ],
        'resolved': [
          {
            'mutationId': sent.single['mutationId'],
            'sourceId': source,
            'noteId': 'my-conflict-copy',
            'version': 3,
          },
        ],
        'acknowledged': [sent.single['mutationId']],
      }, sent);
      expect(store.initialSnapshot.selectedId, 'my-conflict-copy');
      expect(store.initialSnapshot.selected.text, 'My continued edit');
      expect(
        store.initialSnapshot.notes.firstWhere((n) => n.id == source).text,
        'Other device edit',
      );
      final next = store.prepareSyncChanges().single;
      expect(next['id'], 'my-conflict-copy');
      expect(next['baseVersion'], 3);
    },
  );

  test(
    'Pending count includes deletions and retries once, excluding blank drafts',
    () async {
      final store = await open();
      store.useProfile('alice');
      final b = Note.create(text: 'B');
      await store.save(store.initialSnapshot.editSelected('A').add(b));
      final a = store.initialSnapshot.notes.firstWhere((n) => n.id != b.id);
      expect(store.pendingSyncCount, 2);
      final sent = store.prepareSyncChanges();
      await store.save(
        store.initialSnapshot.select(a.id).editSelected('A continued'),
      );
      expect(store.pendingSyncCount, 2);
      await store.save(store.initialSnapshot.removeSelected());
      expect(store.pendingSyncCount, 2);
      store.applySync({
        'notes': [
          for (final c in sent) {...c, 'version': 1},
        ],
        'acknowledged': [for (final c in sent) c['mutationId']],
      }, sent);
      expect(store.pendingSyncCount, 1);
      final deletion = store.prepareSyncChanges();
      expect(deletion.single['deleted'], isTrue);
      store.applySync({
        'notes': [
          {...deletion.single, 'version': 2},
        ],
        'acknowledged': [deletion.single['mutationId']],
      }, deletion);
      expect(store.pendingSyncCount, 0);
      await store.save(store.initialSnapshot.add(Note.create()));
      await store.save(store.initialSnapshot.editSelected(' \t\n'));
      expect(store.pendingSyncCount, 0);
      store.useProfile('bob');
      expect(store.pendingSyncCount, 0);
    },
  );

  test('A stale response cannot replace a newer server revision', () async {
    final store = await open();
    store.useProfile('alice');
    final note = Note.create(text: 'Original');
    Map<String, dynamic> response(String text, int version) => {
      'notes': [
        {...note.toJson(), 'text': text, 'version': version, 'deleted': false},
      ],
      'acknowledged': <String>[],
    };
    store.applySync(response('Latest from another device', 3), []);
    store.applySync(response('Older server text', 2), []);
    expect(store.initialSnapshot.selected.text, 'Latest from another device');
  });

  test(
    'A genuine concurrent remote edit does not rebase unsent text',
    () async {
      final store = await open();
      await store.save(store.initialSnapshot.editSelected('Sent edit'));
      final sent = store.pendingChanges();
      await store.save(
        store.initialSnapshot.editSelected('Still typing locally'),
      );
      store.applySync({
        'notes': [
          {...sent.single, 'text': 'Different device edit', 'version': 5},
        ],
        'acknowledged': [sent.single['mutationId']],
      }, sent);
      expect(store.initialSnapshot.selected.text, 'Still typing locally');
      expect(store.pendingChanges().single['baseVersion'], 0);
    },
  );

  test(
    'Remote deletions cannot reappear when the app saves its next snapshot',
    () async {
      final store = await open();
      await store.save(
        store.initialSnapshot.editSelected('Delete from other device'),
      );
      final sent = store.pendingChanges();
      store.applySync({
        'notes': [
          {...sent.single, 'version': 1},
        ],
        'acknowledged': [sent.single['mutationId']],
      }, sent);
      store.applySync({
        'notes': [
          {...sent.single, 'deleted': true, 'version': 2},
        ],
        'acknowledged': [],
      }, []);
      expect(store.initialSnapshot.selected.text, isEmpty);
      await store.save(store.initialSnapshot.editSelected('New note'));
      expect(
        store.pendingChanges().where((item) => item['id'] == sent.single['id']),
        isEmpty,
      );
    },
  );

  test('Remote notes replace unsynced blank capture placeholders', () async {
    final store = await open();
    store.useProfile('alice');
    expect(store.pendingChanges(), isEmpty);
    final remote = Note.create(text: 'From a different device');
    store.applySync({
      'notes': [
        {...remote.toJson(), 'version': 1, 'deleted': false},
      ],
      'acknowledged': [],
    }, []);
    expect(store.initialSnapshot.notes, hasLength(1));
    expect(store.initialSnapshot.selected.text, remote.text);
  });

  test(
    'A blank note created before first sync survives sync and reopening',
    () async {
      final store = await open();
      store.useProfile('alice');
      final blank = Note.create();
      await store.save(store.initialSnapshot.add(blank));
      final remote = Note.create(text: 'Existing remote note');
      final response = {
        'notes': [
          {...remote.toJson(), 'version': 1, 'deleted': false},
        ],
        'acknowledged': <String>[],
      };
      store.applySync(response, []);
      expect(store.initialSnapshot.notes, hasLength(2));
      expect(store.initialSnapshot.selectedId, blank.id);
      final reopened = await open();
      reopened.useProfile('alice');
      reopened.applySync(response, []);
      expect(reopened.initialSnapshot.selectedId, blank.id);
      expect(reopened.initialSnapshot.selected.text, isEmpty);
    },
  );
  test('An empty notebook survives saving, reopening and sync without a replacement note', () async {
    final store = await open();
    store.useProfile('empty-account');
    await store.save(store.initialSnapshot.editSelected('Delete me'));
    await store.save(store.initialSnapshot.removeSelected());
    expect(store.initialSnapshot.notes, isEmpty);
    final changes = store.pendingChanges();
    store.applySync({'notes': [], 'acknowledged': []}, changes);
    expect(store.initialSnapshot.notes, isEmpty);
    final reopened = await open();
    reopened.useProfile('empty-account');
    expect(reopened.initialSnapshot.notes, isEmpty);
    await reopened.save(reopened.initialSnapshot.editSelected('New thought'));
    expect(reopened.initialSnapshot.notes.single.text, 'New thought');
  });
}
