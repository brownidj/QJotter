import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'notes_store.dart';

abstract class NoteActions {
  bool get supportsPrinting;
  Future<void> copy(Note note);
  Future<void> export(Note note, Rect origin);
  Future<void> share(Note note, Rect origin);
  Future<void> print(Note note);
}

class PlatformNoteActions implements NoteActions {
  const PlatformNoteActions();
  @override
  bool get supportsPrinting => defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<void> copy(Note note) =>
      Clipboard.setData(ClipboardData(text: note.text));

  static String filename(Note note) {
    final cleaned = note.title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    // Keep names reasonably short without splitting a Unicode character.
    return '${String.fromCharCodes(cleaned.runes.take(80))}.txt';
  }

  @override
  Future<void> export(Note note, Rect origin) async {
    final name = filename(note);
    final file = XFile.fromData(
      utf8.encode(note.text),
      mimeType: 'text/plain',
      name: name,
    );
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      // The iOS share sheet provides Save to Files.
      await SharePlus.instance.share(
        ShareParams(
          files: [file],
          fileNameOverrides: [name],
          sharePositionOrigin: origin,
        ),
      );
      return;
    }
    final destination = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Plain text',
          extensions: ['txt'],
          uniformTypeIdentifiers: ['public.plain-text'],
        ),
      ],
    );
    if (destination != null) await file.saveTo(destination.path);
  }

  @override
  Future<void> share(Note note, Rect origin) async {
    await SharePlus.instance.share(
      ShareParams(
        text: note.text,
        subject: note.title,
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Future<void> print(Note note) async {
    await const MethodChannel(
      'notefile/quick_capture',
    ).invokeMethod<bool>('printNote', {'text': note.text, 'title': note.title});
  }
}
