import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/main.dart';
import 'package:qjotter/note_actions.dart';
import 'package:qjotter/notes_store.dart';

class TestNotesStore implements NotesStore {
  TestNotesStore(this.initialSnapshot);
  @override
  final NotesSnapshot initialSnapshot;
  NotesSnapshot? saved;
  @override
  Future<void> save(NotesSnapshot snapshot) async {
    saved = snapshot;
  }
}

class TestNoteActions implements NoteActions {
  final calls = <String>[];
  final texts = <String>[];
  bool fail = false;
  void record(String action, Note note) {
    calls.add(action);
    texts.add(note.text);
    if (fail) throw StateError('Action failed');
  }

  @override
  bool get supportsPrinting => true;
  @override
  Future<void> copy(Note note) async => record('copy', note);
  @override
  Future<void> export(Note note, Rect origin) async => record('export', note);
  @override
  Future<void> share(Note note, Rect origin) async => record('share', note);
  @override
  Future<void> print(Note note) async => record('print', note);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> menu(WidgetTester tester, String action) async {
    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  String editorText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets(
    'New notes have their own text and switching restores each note',
    (tester) async {
      final initial = NotesSnapshot.fromDraft('First note\nFirst body');
      final store = TestNotesStore(initial);
      await tester.pumpWidget(QJotterApp(store: store));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 note ·'), findsOneWidget);
      await tester.tap(find.byTooltip('New note'));
      await tester.pumpAndSettle();
      expect(editorText(tester), isEmpty);
      expect(find.textContaining('2 notes ·'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'Second note\nSecond body',
      );
      await tester.pumpAndSettle();
      final secondId = store.saved!.selectedId;
      await tester.tap(find.byKey(ValueKey('note-${initial.selectedId}')));
      await tester.pumpAndSettle();
      expect(editorText(tester), 'First note\nFirst body');
      await tester.tap(find.byKey(ValueKey('note-$secondId')));
      await tester.pumpAndSettle();
      expect(editorText(tester), 'Second note\nSecond body');
      expect(store.saved!.notes, hasLength(2));
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
    },
  );

  testWidgets('Each plus press opens a distinct blank note', (tester) async {
    final store = TestNotesStore(NotesSnapshot.fromDraft(''));
    await tester.pumpWidget(QJotterApp(store: store));
    await tester.pumpAndSettle();
    final ids = {store.initialSnapshot.selectedId};
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('New note'));
      await tester.pumpAndSettle();
      expect(editorText(tester), isEmpty);
      expect(ids.add(store.saved!.selectedId), isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
    }
    expect(find.textContaining('4 notes ·'), findsOneWidget);
  });

  for (final key in [LogicalKeyboardKey.delete, LogicalKeyboardKey.backspace]) {
    testWidgets(
      'Desktop ${key.keyLabel} confirms deletion of the highlighted row',
      (tester) async {
        tester.view.physicalSize = const Size(560, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.binding.setSurfaceSize(const Size(560, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final first = NotesSnapshot.fromDraft('First note');
        final other = Note.create(text: 'Keep this note');
        final store = TestNotesStore(first.add(other));
        await tester.pumpWidget(QJotterApp(store: store));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.delete_outline),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.textContaining('2 notes ·'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('note-${first.selectedId}')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('notes-list')), findsOneWidget);
        expect(find.byTooltip('Delete highlighted note'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.delete_outline),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('notes-list')),
            matching: find.byIcon(Icons.delete_outline),
          ),
          findsNothing,
        );
        expect(
          tester
              .widget<ListTile>(
                find.descendant(
                  of: find.byKey(ValueKey('note-${first.selectedId}')),
                  matching: find.byType(ListTile),
                ),
              )
              .selected,
          isTrue,
        );
        await tester.sendKeyDownEvent(key);
        await tester.pumpAndSettle();
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyUpEvent(key);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(store.saved!.notes, hasLength(2));
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(store.saved!.notes.map((n) => n.text), ['Keep this note']);
        expect(find.byKey(const ValueKey('notes-list')), findsOneWidget);
        expect(find.text('Note deleted'), findsNothing);
        expect(store.saved!.notes, hasLength(1));
      },
      variant: TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'Double-click opens a desktop row and Help never handles list deletion keys',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(560, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final snapshot = NotesSnapshot.fromDraft('Open this note');
      final store = TestNotesStore(snapshot);
      await tester.pumpWidget(QJotterApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('1 note ·'));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('note-${snapshot.selectedId}'));
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-list')), findsNothing);
      expect(editorText(tester), 'Open this note');
      await tester.tap(find.textContaining('1 note ·'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Help'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.delete_outline),
            )
            .onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('Note deleted'), findsNothing);
      expect(store.saved!.notes.single.text, 'Open this note');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'Desktop Enter opens the highlighted note and editing keys do not delete notes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(560, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = TestNotesStore(
        NotesSnapshot.fromDraft('Keep the whole note'),
      );
      await tester.pumpWidget(QJotterApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('1 note ·'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-list')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(find.text('Note deleted'), findsNothing);
      expect(find.textContaining('1 note ·'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'Holding a filtered list entry enables its trash button without clearing search',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final first = NotesSnapshot.fromDraft('Remove this matching note');
      final other = Note.create(text: 'Keep this matching note');
      final store = TestNotesStore(first.add(other));
      await tester.pumpWidget(QJotterApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search notes'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('note-search')),
        'matching',
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(ValueKey('note-${first.selectedId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete highlighted note'));
      await tester.pumpAndSettle();
      expect(find.text('Are you sure?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(store.saved!.notes.map((n) => n.text), [
        'Keep this matching note',
      ]);
      expect(find.byKey(const ValueKey('notes-list')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('note-search')))
            .controller!
            .text,
        'matching',
      );
      expect(find.text('Note deleted'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Cancel leaves the note intact and confirmation removes only that note',
    (tester) async {
      final first = NotesSnapshot.fromDraft('First');
      final deleted = Note.create(text: 'Second');
      final store = TestNotesStore(first.add(deleted));
      await tester.pumpWidget(QJotterApp(store: store));
      await tester.pumpAndSettle();
      await menu(tester, 'Delete');
      expect(find.text('Are you sure?'), findsOneWidget);
      expect(editorText(tester), 'Second');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(editorText(tester), 'Second');
      await menu(tester, 'Delete');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(editorText(tester), 'First');
      expect(store.saved!.notes.map((n) => n.text), ['First']);
      expect(find.text('Note deleted'), findsNothing);
      expect(find.text('Undo'), findsNothing);
    },
  );

  testWidgets(
    'Deleting the last note leaves zero notes and typing starts a real note',
    (tester) async {
      final store = TestNotesStore(NotesSnapshot.fromDraft('Only note'));
      await tester.pumpWidget(QJotterApp(store: store));
      await tester.pumpAndSettle();
      await menu(tester, 'Delete');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(store.saved!.notes, isEmpty);
      expect(editorText(tester), isEmpty);
      expect(find.text('0 notes'), findsOneWidget);
      expect(find.text('Untitled note'), findsNothing);
      await tester.enterText(find.byType(TextField), 'A new thought');
      await tester.pumpAndSettle();
      expect(store.saved!.notes.single.text, 'A new thought');
    },
  );

  testWidgets(
    'On small screens the count switches between the list and editor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final snapshot = NotesSnapshot.fromDraft('My note');
      await tester.pumpWidget(QJotterApp(store: TestNotesStore(snapshot)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-list')), findsNothing);
      await tester.tap(find.textContaining('1 note ·'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(ValueKey('note-${snapshot.selectedId}')));
      await tester.pumpAndSettle();
      expect(editorText(tester), 'My note');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('The ellipsis menu operates on the selected note', (
    tester,
  ) async {
    final actions = TestNoteActions();
    await tester.pumpWidget(
      QJotterApp(
        store: TestNotesStore(NotesSnapshot.fromDraft('Selected note')),
        actions: actions,
      ),
    );
    await tester.pumpAndSettle();
    for (final action in ['Copy', 'Export…', 'Print…', 'Share…']) {
      await menu(tester, action);
    }
    expect(actions.calls, ['copy', 'export', 'print', 'share']);
    expect(actions.texts, everyElement('Selected note'));
  });

  for (final width in [390.0, 900.0]) {
    testWidgets('Search finds note body text at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final first = NotesSnapshot.fromDraft('Shopping\nBuy apples');
      final second = Note.create(text: 'Travel\nVisit Brisbane');
      final store = TestNotesStore(first.add(second));
      await tester.pumpWidget(QJotterApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search notes'));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('note-search'));
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
      await tester.enterText(search, 'APPLES');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('note-${first.selectedId}')), findsOneWidget);
      expect(find.byKey(ValueKey('note-${second.id}')), findsNothing);
      expect(store.saved, isNull);
      await tester.enterText(search, 'no such note');
      await tester.pumpAndSettle();
      expect(find.text('No matching notes'), findsOneWidget);
      await tester.enterText(search, 'apples');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('note-${first.selectedId}')));
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      expect(editorText(tester), 'Shopping\nBuy apples');
      expect(store.saved!.notes, hasLength(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Closing search restores the current note without edits', (
    tester,
  ) async {
    final store = TestNotesStore(NotesSnapshot.fromDraft('Keep this note'));
    await tester.pumpWidget(QJotterApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search notes'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('note-search')),
      'missing',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(editorText(tester), 'Keep this note');
    expect(store.saved, isNull);
    await tester.tap(find.byTooltip('Search notes'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('note-search')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('No matching notes'), findsNothing);
  });

  testWidgets(
    'Native action failures restore click-away behaviour and show an error',
    (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        quickCaptureChannel,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          quickCaptureChannel,
          null,
        ),
      );
      final actions = TestNoteActions()..fail = true;
      await tester.pumpWidget(
        QJotterApp(
          store: TestNotesStore(NotesSnapshot.fromDraft('A note')),
          actions: actions,
        ),
      );
      await tester.pumpAndSettle();
      await menu(tester, 'Share…');
      expect(calls, [
        'registerShortcut',
        'beginExternalAction',
        'endExternalAction',
      ]);
      expect(
        find.text('Could not complete this action. Please try again.'),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  test('Export filenames are safe on Windows and preserve Unicode', () {
    final name = PlatformNoteActions.filename(
      Note.create(text: '日本語: what/where?\nBody'),
    );
    expect(name, '日本語_ what_where_.txt');
  });
}
