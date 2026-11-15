import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/main.dart';
import 'package:qjotter/notes_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quickCaptureChannel, null);
  });

  testWidgets(
    'The note view has only the editor and a question-mark help button',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        quickCaptureChannel,
        (_) async => null,
      );
      await tester.pumpWidget(QJotterApp(store: MemoryDraft('A note')));
      await tester.pumpAndSettle();
      expect(find.text('?'), findsOneWidget);
      expect(find.byTooltip('Help'), findsOneWidget);
      expect(find.text('Hide'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(Divider), findsNothing);
      expect(find.text('Notes saved locally'), findsNothing);
      expect(find.textContaining('⌃⌥⌘N'), findsNothing);
      expect(find.textContaining('keeps running'), findsNothing);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    'Help explains the shortcut and closing without a saved-status message',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        quickCaptureChannel,
        (_) async => null,
      );
      await tester.pumpWidget(
        QJotterApp(store: MemoryDraft('Keep this draft')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('?'));
      await tester.pumpAndSettle();
      expect(find.text('Help'), findsOneWidget);
      expect(find.text('?'), findsNothing);
      expect(find.byIcon(Icons.arrow_left_rounded), findsOneWidget);
      expect(find.byTooltip('Return to note'), findsOneWidget);
      expect(find.text('Back to note'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(find.text('Notes saved locally'), findsNothing);
      expect(find.textContaining('Notes save automatically'), findsNothing);
      expect(
        find.textContaining('Hold Control + Option + Command together'),
        findsOneWidget,
      );
      expect(find.textContaining('⌃ means Control'), findsOneWidget);
      expect(find.textContaining('from any app'), findsOneWidget);
      expect(find.textContaining('launch QJotter'), findsOneWidget);
      expect(find.text('⌃⌥⌘N ready · works from other apps'), findsOneWidget);
      expect(find.textContaining('Click outside this window'), findsOneWidget);
      expect(
        find.textContaining('QJotter keeps running in the background'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Return to note'));
      await tester.pumpAndSettle();
      expect(find.text('?'), findsOneWidget);
      expect(find.byTooltip('Help'), findsOneWidget);
      final editor = tester.widget<TextField>(find.byType(TextField));
      expect(editor.controller!.text, 'Keep this draft');
      expect(editor.focusNode!.hasFocus, isTrue);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets('Restores the draft and saves subsequent edits', (tester) async {
    final draft = MemoryDraft('Existing draft');
    await tester.pumpWidget(QJotterApp(store: draft));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Existing draft',
    );

    await tester.enterText(find.byType(TextField), 'Updated draft');
    await tester.pumpAndSettle();
    expect(draft.saved, 'Updated draft');
    expect(find.text('Notes saved locally', skipOffstage: false), findsNothing);
  });

  testWidgets('Typing is available immediately without clicking the editor', (
    tester,
  ) async {
    final draft = MemoryDraft('');
    await tester.pumpWidget(QJotterApp(store: draft));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.enterText('A quick thought');
    await tester.pumpAndSettle();
    expect(draft.saved, 'A quick thought');
  });

  testWidgets(
    'Rapid edits save in order and stay pending until the last write',
    (tester) async {
      final draft = ControlledDraft();
      await tester.pumpWidget(QJotterApp(store: draft));
      await tester.enterText(find.byType(TextField), 'A');
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'AB');
      await tester.pump();
      expect(draft.writes, ['A']);
      expect(find.text('Saving…', skipOffstage: false), findsOneWidget);

      draft.pending[0].complete();
      await tester.pump();
      expect(draft.writes, ['A', 'AB']);
      expect(find.text('Saving…', skipOffstage: false), findsOneWidget);
      draft.pending[1].complete();
      await tester.pump();
      expect(
        find.text('Notes saved locally', skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Returning to earlier text does not report an older write as saved',
    (tester) async {
      final draft = ControlledDraft();
      await tester.pumpWidget(QJotterApp(store: draft));
      for (final text in ['A', 'B', 'A']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
      }
      draft.pending[0].complete();
      await tester.pump();
      expect(find.text('Saving…', skipOffstage: false), findsOneWidget);
      draft.pending[1].complete();
      await tester.pump();
      expect(find.text('Saving…', skipOffstage: false), findsOneWidget);
      draft.pending[2].complete();
      await tester.pump();
      expect(draft.writes, ['A', 'B', 'A']);
      expect(
        find.text('Notes saved locally', skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets('A save failure is visible and a subsequent edit can recover', (
    tester,
  ) async {
    final draft = ControlledDraft();
    await tester.pumpWidget(QJotterApp(store: draft));
    await tester.enterText(find.byType(TextField), 'Unsaved');
    await tester.pump();
    draft.pending[0].completeError(StateError('Disk unavailable'));
    await tester.pump();
    expect(
      find.text('Could not save notes', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Unsaved',
    );

    await tester.enterText(find.byType(TextField), 'Try again');
    await tester.pump();
    draft.pending[1].complete();
    await tester.pump();
    expect(find.text('Notes saved locally', skipOffstage: false), findsNothing);
    expect(draft.writes, ['Unsaved', 'Try again']);
  });

  testWidgets(
    'An older failed write does not replace the status of a pending edit',
    (tester) async {
      final draft = ControlledDraft();
      await tester.pumpWidget(QJotterApp(store: draft));
      await tester.enterText(find.byType(TextField), 'Old edit');
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Latest edit');
      await tester.pump();
      draft.pending[0].completeError(StateError('Temporary failure'));
      await tester.pump();
      expect(find.text('Saving…', skipOffstage: false), findsOneWidget);
      draft.pending[1].complete();
      await tester.pump();
      expect(
        find.text('Notes saved locally', skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets('Queued edits finish safely after the editor is disposed', (
    tester,
  ) async {
    final draft = ControlledDraft();
    await tester.pumpWidget(QJotterApp(store: draft));
    await tester.enterText(find.byType(TextField), 'First');
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Final');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    draft.pending[0].complete();
    await tester.pump();
    expect(draft.writes, ['First', 'Final']);
    draft.pending[1].complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Non-Mac targets never attempt to use the Mac shortcut channel',
    (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        quickCaptureChannel,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      await tester.pumpWidget(QJotterApp(store: MemoryDraft('')));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.text('Hide'), findsNothing);
      expect(find.text('Retry shortcut'), findsNothing);
      expect(find.textContaining('⌃⌥⌘N'), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('The editor fits an iPhone-sized viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(QJotterApp(store: MemoryDraft('')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Mac activation focuses the editor and preserves its draft', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      quickCaptureChannel,
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    await tester.pumpWidget(QJotterApp(store: MemoryDraft('Keep this note')));
    await tester.pumpAndSettle();
    expect(calls, ['registerShortcut']);
    expect(
      find.text('⌃⌥⌘N ready · works from other apps', skipOffstage: false),
      findsOneWidget,
    );

    final editor = tester.widget<TextField>(find.byType(TextField));
    const selection = TextSelection(baseOffset: 5, extentOffset: 9);
    editor.controller!.selection = selection;
    await tester.tap(find.text('?'));
    await tester.pumpAndSettle();
    expect(find.text('Help'), findsOneWidget);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      quickCaptureChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('focusEditor'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('Help'), findsNothing);
    expect(editor.focusNode!.hasFocus, isTrue);
    expect(editor.controller!.text, 'Keep this note');
    expect(editor.controller!.selection, selection);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('Shows a shortcut conflict and allows a retry', (tester) async {
    var attempts = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      quickCaptureChannel,
      (call) async {
        if (attempts++ == 0) {
          throw PlatformException(
            code: 'shortcut_unavailable',
            message: 'Shortcut already in use',
          );
        }
        return null;
      },
    );
    await tester.pumpWidget(QJotterApp(store: MemoryDraft('')));
    await tester.pumpAndSettle();
    expect(
      find.text('Shortcut already in use', skipOffstage: false),
      findsOneWidget,
    );
    await tester.tap(find.text('?'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Retry shortcut'));
    await tester.tap(find.text('Retry shortcut'));
    await tester.pumpAndSettle();
    expect(
      find.text('⌃⌥⌘N ready · works from other apps', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Retry shortcut'), findsNothing);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
  testWidgets('A missing Mac bridge shows rebuild instructions and can retry', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      quickCaptureChannel,
      (_) async => throw MissingPluginException(),
    );
    await tester.pumpWidget(QJotterApp(store: MemoryDraft('')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Stop and rebuild the Mac app to enable the shortcut.',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      quickCaptureChannel,
      (_) async => null,
    );
    await tester.tap(find.text('?'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Retry shortcut'));
    await tester.tap(find.text('Retry shortcut'));
    await tester.pumpAndSettle();
    expect(
      find.text('⌃⌥⌘N ready · works from other apps', skipOffstage: false),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets(
    'Registration finishing after disposal cannot update a dead editor',
    (tester) async {
      final registration = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        quickCaptureChannel,
        (_) => registration.future,
      );
      await tester.pumpWidget(QJotterApp(store: MemoryDraft('')));
      await tester.pump();
      expect(
        find.text('Registering ⌃⌥⌘N…', skipOffstage: false),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      registration.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );
}

class MemoryDraft implements NotesStore {
  MemoryDraft(this.initialText);
  final String initialText;
  @override
  NotesSnapshot get initialSnapshot => NotesSnapshot.fromDraft(initialText);
  String? saved;
  @override
  Future<void> save(NotesSnapshot snapshot) async {
    saved = snapshot.selected.text;
  }
}

class ControlledDraft implements NotesStore {
  @override
  NotesSnapshot get initialSnapshot => NotesSnapshot.fromDraft('');
  final writes = <String>[];
  final pending = <Completer<void>>[];

  @override
  Future<void> save(NotesSnapshot snapshot) {
    writes.add(snapshot.selected.text);
    final completion = Completer<void>();
    pending.add(completion);
    return completion.future;
  }
}
