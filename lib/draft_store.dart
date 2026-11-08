import 'dart:io';

abstract class DraftStore {
  String get initialText;
  Future<void> save(String text);

  static Future<DraftStore> open(Directory directory) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/quick_capture_draft.txt');
    final text = await file.exists() ? await file.readAsString() : '';
    return _FileDraftStore(file, text);
  }
}

/// A single local scratch draft. Writes replace the previous file atomically.
class _FileDraftStore implements DraftStore {
  _FileDraftStore(this._file, this.initialText);

  final File _file;
  @override
  final String initialText;

  @override
  Future<void> save(String text) async {
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(_file.path);
  }
}
