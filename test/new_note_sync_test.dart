import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/app_services.dart';
import 'package:qjotter/main.dart';
import 'package:qjotter/notes_store.dart';
import 'package:qjotter/sqlite_notes_store.dart';

import 'support/account_fakes.dart';

class ExistingNoteApi extends AccountApi {
  final note = Note.create(text: 'Existing server note');

  @override
  Future<Map<String, dynamic>> sync(
    AccountSession session,
    List<Map<String, dynamic>> changes,
  ) async => {
    'notes': [
      {...note.toJson(), 'version': 1, 'deleted': false},
      for (final change in changes) {...change, 'version': 1},
    ],
    'acknowledged': [for (final change in changes) change['mutationId']],
  };
}

class DelayedNoteApi extends AccountApi {
  final response = Completer<Map<String, dynamic>>();
  late List<Map<String, dynamic>> sent;

  @override
  Future<Map<String, dynamic>> sync(
    AccountSession session,
    List<Map<String, dynamic>> changes,
  ) {
    sent = changes;
    return response.future;
  }
}

void main() {
  for (final createNew in [false, true]) {
    testWidgets(
      'Typing as a sync response arrives keeps text and composing range (new note: $createNew)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        late Directory directory;
        late SqliteNotesStore store;
        late AppServices services;
        final api = DelayedNoteApi();
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp(
            'qjotter-sync-race-',
          );
          store = await NotesStore.open(directory);
          services = AppServices(
            store: store,
            vault: MemorySessionVault()
              ..session = AccountSession(
                server: 'https://notes.example.test',
                userId: 'alice',
                email: 'alice@example.test',
                token: 'test-token',
              ),
            startup: FakeStartupManager(),
            api: api,
            automaticSync: false,
          );
          await services.initialize();
          await store.save(
            store.initialSnapshot.editSelected('Restaurant app'),
          );
        });
        addTearDown(() async {
          services.dispose();
          store.close();
          await directory.delete(recursive: true);
        });
        await tester.pumpWidget(QJotterApp(store: store, services: services));
        await tester.pumpAndSettle();
        // Open the editor on a phone.
        await tester.tap(find.text('Restaurant app').first);
        await tester.pumpAndSettle();
        await tester.showKeyboard(find.byType(TextField));
        final sync = services.sync();
        final uploadedId = api.sent.single['id'];
        if (createNew) {
          await tester.tap(find.byTooltip('New note'));
          await tester.pumpAndSettle();
        }
        final editingId = store.initialSnapshot.selectedId;
        final remote = Note.create(text: 'Arrived from another device');
        // Queue the network completion immediately BEFORE the keyboard event.
        // A deferred save used to lose this edit when the completion ran first.
        api.response.complete({
          'notes': [
            for (final change in api.sent) {...change, 'version': 1},
            {...remote.toJson(), 'version': 2, 'deleted': false},
          ],
          'acknowledged': [for (final change in api.sent) change['mutationId']],
        });
        const value = TextEditingValue(
          text: 'Restaurant app\nis it better?',
          selection: TextSelection.collapsed(offset: 28),
          composing: TextRange(start: 18, end: 28),
        );
        tester.testTextInput.updateEditingValue(value);
        await tester.pumpAndSettle();
        await sync;
        final editor = tester.widget<TextField>(find.byType(TextField));
        expect(editor.controller!.value, value);
        expect(store.initialSnapshot.selected.text, value.text);
        expect(store.initialSnapshot.selectedId, editingId);
        expect(store.pendingChanges().single['id'], editingId);
        expect(store.pendingChanges().single['baseVersion'], createNew ? 0 : 1);
        expect(store.pendingChanges().single['text'], value.text);
        expect(
          store.initialSnapshot.notes.firstWhere((n) => n.id == remote.id).text,
          remote.text,
        );
        if (createNew) {
          expect(editingId, isNot(uploadedId));
          expect(
            store.initialSnapshot.notes
                .firstWhere((n) => n.id == uploadedId)
                .text,
            'Restaurant app',
          );
        }
        // The next save must retain notes which arrived in the response.
        tester.testTextInput.enterText('Restaurant app\nAnother sentence 📝');
        await tester.pumpAndSettle();
        expect(
          store.initialSnapshot.notes.any((n) => n.id == remote.id),
          isTrue,
        );
        expect(store.pendingChanges().single['deleted'], isFalse);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }),
    );
  }

  for (final width in [390.0, 900.0]) {
    testWidgets(
      'Plus opens a new note that survives sync and accepts typing at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        late Directory directory;
        late SqliteNotesStore store;
        late AppServices services;
        final api = ExistingNoteApi();
        final session = AccountSession(
          server: 'https://notes.example.test',
          userId: 'alice',
          email: 'alice@example.test',
          token: 'test-token',
        );
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp(
            'notefile-new-note-',
          );
          store = await NotesStore.open(directory);
          services = AppServices(
            store: store,
            vault: MemorySessionVault()..session = session,
            startup: FakeStartupManager(),
            api: api,
            automaticSync: false,
          );
          await services.initialize();
          await services.sync();
        });
        addTearDown(() async {
          services.dispose();
          store.close();
          await directory.delete(recursive: true);
        });
        await tester.pumpWidget(QJotterApp(store: store, services: services));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('New note'));
        await tester.pumpAndSettle();
        final newId = store.initialSnapshot.selectedId;
        expect(newId, isNot(api.note.id));
        for (var i = 0; i < 2; i++) {
          await tester.runAsync(services.sync);
          await tester.pumpAndSettle();
          expect(store.initialSnapshot.selectedId, newId);
          final editor = tester.widget<TextField>(find.byType(TextField));
          expect(editor.controller!.text, isEmpty);
          expect(editor.focusNode!.hasFocus, isTrue);
        }
        await tester.enterText(find.byType(TextField), 'My new note');
        await tester.pumpAndSettle();
        await tester.runAsync(services.sync);
        await tester.pumpAndSettle();
        expect(store.initialSnapshot.selectedId, newId);
        expect(store.initialSnapshot.selected.text, 'My new note');
        expect(
          store.initialSnapshot.notes
              .firstWhere((n) => n.id == api.note.id)
              .text,
          'Existing server note',
        );
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }
}
