import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/app_services.dart';
import 'package:qjotter/main.dart';
import 'package:qjotter/notes_store.dart';
import 'package:qjotter/sqlite_notes_store.dart';

import 'support/account_fakes.dart';

class ControlledSyncApi extends AccountApi {
  bool offline = false;
  final requests = <List<Map<String, dynamic>>>[];
  final responses = <Completer<Map<String, dynamic>>>[];
  final notes = <String, Map<String, dynamic>>{};
  int version = 0;
  @override
  Future<Map<String, dynamic>> sync(
    AccountSession session,
    List<Map<String, dynamic>> changes,
  ) {
    if (offline) throw const AccountError('Cannot reach the server.');
    requests.add(changes);
    final reply = Completer<Map<String, dynamic>>();
    responses.add(reply);
    return reply.future;
  }

  void acknowledge(int index) {
    for (final change in requests[index]) {
      notes[change['id'] as String] = {...change, 'version': ++version};
    }
    responses[index].complete({
      'notes': notes.values.toList(),
      'acknowledged': [for (final c in requests[index]) c['mutationId']],
    });
  }
}

void main() {
  for (final width in [390.0, 900.0]) {
    testWidgets(
      'Sync LED counts records until acknowledgement at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        late Directory directory;
        late SqliteNotesStore store;
        late AppServices services;
        final api = ControlledSyncApi();
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp('qjotter-led-');
          store = await NotesStore.open(directory);
          services = AppServices(
            store: store,
            vault: MemorySessionVault()
              ..session = const AccountSession(
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
        });
        addTearDown(() async {
          services.dispose();
          store.close();
          await directory.delete(recursive: true);
        });
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(QJotterApp(store: store, services: services));
          await tester.pumpAndSettle();
          final led = find.byKey(const ValueKey('server-sync-led'));
          Color color() =>
              (tester.widget<AnimatedContainer>(led).decoration!
                      as BoxDecoration)
                  .color!;
          final verify = services.sync();
          api.acknowledge(0);
          await verify;
          await tester.pumpAndSettle();
          expect(color(), const Color(0xFF22A447));
          expect(tester.getSize(led).width, 10);
          expect(find.text('Saved to server'), findsNothing);
          expect(
            find.byTooltip('All notes synced with the server'),
            findsOneWidget,
          );
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer();
          await mouse.moveTo(tester.getCenter(led));
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('All notes synced with the server'), findsOneWidget);
          await mouse.removePointer();
          await tester.pumpAndSettle();

          expect(find.bySemanticsLabel('Server sync'), findsOneWidget);
          final settings = find.byTooltip('Settings');
          expect(
            tester.getCenter(led).dy,
            closeTo(tester.getCenter(settings).dy, 1),
          );
          expect(
            tester.getCenter(led).dx,
            lessThan(tester.getCenter(settings).dx),
          );
          for (final text in ['First note', 'Second note']) {
            await tester.tap(find.byTooltip('New note'));
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField), text);
            await tester.pumpAndSettle();
          }
          expect(color(), const Color(0xFFF59E0B));
          expect(tester.getSize(led).width, 32);
          expect(
            find.descendant(of: led, matching: find.text('2')),
            findsOneWidget,
          );
          final upload = services.sync();
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: led, matching: find.text('2')),
            findsOneWidget,
          );
          await tester.enterText(
            find.byType(TextField),
            'Second note continued while syncing',
          );
          await tester.pumpAndSettle();
          expect(
            services.pendingSyncCount,
            2,
          ); // Same record is not counted twice.
          api.acknowledge(1);
          await upload;
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: led, matching: find.text('1')),
            findsOneWidget,
          );
          expect(color(), const Color(0xFFF59E0B));
          final next = services.sync();
          api.acknowledge(2);
          await next;
          await tester.pumpAndSettle();
          expect(color(), const Color(0xFF22A447));
          expect(tester.getSize(led).width, 10);
          await tester.tap(find.byTooltip('New note'));
          await tester.pumpAndSettle();
          expect(
            services.pendingSyncCount,
            0,
          ); // A blank capture is not an upload.
          expect(color(), const Color(0xFF22A447));
          api.offline = true;
          await services.sync();
          await tester.pumpAndSettle();
          expect(color(), const Color(0xFF858E8A));
          expect(
            find.byTooltip(
              'Sync with the server has not been confirmed.\nCannot reach the server.',
            ),
            findsOneWidget,
          );
          await tester.enterText(find.byType(TextField), 'An offline note');
          await tester.pumpAndSettle();
          expect(color(), const Color(0xFFF59E0B));
          expect(
            find.descendant(of: led, matching: find.text('1')),
            findsOneWidget,
          );
          api.offline = false;
          final retry = services.sync();
          api.acknowledge(3);
          await retry;
          await tester.pumpAndSettle();
          expect(color(), const Color(0xFF22A447));
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }),
    );
  }
}
