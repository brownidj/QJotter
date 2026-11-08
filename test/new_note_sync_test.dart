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

void main() {
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
          directory = await Directory.systemTemp.createTemp('notefile-new-note-');
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
          store.initialSnapshot.notes.firstWhere((n) => n.id == api.note.id).text,
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
