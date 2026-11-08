import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'sqlite_notes_store.dart';

class Note {
  const Note({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Note.create({String text = '', DateTime? now}) {
    final time = (now ?? DateTime.now()).toUtc();
    return Note(
      id: const Uuid().v4(),
      text: text,
      createdAt: time,
      updatedAt: time,
    );
  }

  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get title {
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return 'Untitled note';
  }

  Note edit(String value, {DateTime? now}) => Note(
    id: id,
    text: value,
    createdAt: createdAt,
    updatedAt: (now ?? DateTime.now()).toUtc(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
  );
}

class NotesSnapshot {
  NotesSnapshot({required Iterable<Note> notes, required this.selectedId})
    : notes = List.unmodifiable(notes) {
    if ((this.notes.isEmpty && selectedId.isNotEmpty) ||
        (this.notes.isNotEmpty &&
            !this.notes.any((note) => note.id == selectedId))) {
      throw const FormatException('A notebook must have a selected note.');
    }
    if (this.notes.map((note) => note.id).toSet().length != this.notes.length) {
      throw const FormatException('Duplicate note identifiers.');
    }
  }

  factory NotesSnapshot.fromDraft(String text, {DateTime? now}) {
    final note = Note.create(text: text, now: now);
    return NotesSnapshot(notes: [note], selectedId: note.id);
  }

  factory NotesSnapshot.empty() =>
      NotesSnapshot(notes: const [], selectedId: '');

  final List<Note> notes;
  final String selectedId;
  Note get selected => notes.isEmpty
      ? Note(
          id: '',
          text: '',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        )
      : notes.firstWhere((note) => note.id == selectedId);
  List<Note> get recentFirst => [...notes]
    ..sort((a, b) {
      final date = b.updatedAt.compareTo(a.updatedAt);
      return date != 0 ? date : b.id.compareTo(a.id);
    });

  NotesSnapshot select(String id) =>
      NotesSnapshot(notes: notes, selectedId: id);
  NotesSnapshot editSelected(String text, {DateTime? now}) => notes.isEmpty
      ? (text.isEmpty ? this : NotesSnapshot.fromDraft(text, now: now))
      : NotesSnapshot(
          notes: notes.map(
            (note) => note.id == selectedId ? note.edit(text, now: now) : note,
          ),
          selectedId: selectedId,
        );
  NotesSnapshot add(Note note) =>
      NotesSnapshot(notes: [...notes, note], selectedId: note.id);
  NotesSnapshot removeSelected() {
    final remaining = recentFirst
        .where((note) => note.id != selectedId)
        .toList();
    return remaining.isEmpty
        ? NotesSnapshot.empty()
        : NotesSnapshot(notes: remaining, selectedId: remaining.first.id);
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'selectedId': selectedId,
    'notes': notes.map((note) => note.toJson()).toList(),
  };

  factory NotesSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported notebook version.');
    }
    return NotesSnapshot(
      notes: (json['notes'] as List).map(
        (note) => Note.fromJson(note as Map<String, dynamic>),
      ),
      selectedId: json['selectedId'] as String,
    );
  }
}

abstract class NotesStore {
  NotesSnapshot get initialSnapshot;
  Future<void> save(NotesSnapshot snapshot);

  static Future<SqliteNotesStore> open(Directory directory) =>
      SqliteNotesStore.open(directory);
}
