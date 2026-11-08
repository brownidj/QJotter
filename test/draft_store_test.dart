import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/draft_store.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('notefile_storage_test_');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('A new store starts empty and creates missing directories', () async {
    final nested = Directory('${directory.path}/notes/drafts');
    final store = await DraftStore.open(nested);
    expect(store.initialText, isEmpty);
    expect(await nested.exists(), isTrue);
  });

  test('The latest completed save survives reopening the store', () async {
    final store = await DraftStore.open(directory);
    await store.save('First draft');
    await store.save('Latest draft');
    expect((await DraftStore.open(directory)).initialText, 'Latest draft');
  });

  test('Unicode, line breaks and whitespace survive a round trip', () async {
    const text = '  Café 📝\n日本語\nCrocodile\n\nTrailing spaces  \n';
    final store = await DraftStore.open(directory);
    await store.save(text);
    expect((await DraftStore.open(directory)).initialText, text);
  });

  test('Clearing a draft stays cleared after reopening', () async {
    final store = await DraftStore.open(directory);
    await store.save('Delete this draft');
    await store.save('');
    expect((await DraftStore.open(directory)).initialText, isEmpty);
  });

  test('A failed write preserves the previously saved draft', () async {
    final store = await DraftStore.open(directory);
    await store.save('Keep the last good draft');
    // A directory at the temporary-file path forces a real filesystem failure.
    await Directory('${directory.path}/quick_capture_draft.txt.tmp').create();
    await expectLater(
      store.save('Unwritten edit'),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      (await DraftStore.open(directory)).initialText,
      'Keep the last good draft',
    );
  });

  test(
    'An interrupted temporary write never replaces a completed save',
    () async {
      final store = await DraftStore.open(directory);
      await store.save('Complete draft');
      await File('${directory.path}/quick_capture_draft.txt.tmp')
          .writeAsString('Interrupted draft');
      expect((await DraftStore.open(directory)).initialText, 'Complete draft');
      await store.save('Recovered draft');
      expect((await DraftStore.open(directory)).initialText, 'Recovered draft');
      expect(
        await File('${directory.path}/quick_capture_draft.txt.tmp').exists(),
        isFalse,
      );
    },
  );

  test(
    'An unreadable draft reports an error instead of opening empty',
    () async {
      await File('${directory.path}/quick_capture_draft.txt')
          .writeAsBytes([0xFF]);
      await expectLater(DraftStore.open(directory), throwsA(isA<Exception>()));
      expect(
        await File('${directory.path}/quick_capture_draft.txt').readAsBytes(),
        [0xFF],
      );
    },
  );
}
