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
    store.applySync({
      'notes': [
        {...latest.single, 'version': 2},
      ],
      'acknowledged': [latest.single['mutationId']],
    }, latest);
    expect(store.pendingChanges(), isEmpty);
  });

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
