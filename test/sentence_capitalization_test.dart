import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/main.dart';
import 'package:qjotter/notes_store.dart';
import 'package:qjotter/sentence_capitalization.dart';

const formatter = SentenceCapitalizationFormatter();
TextEditingValue value(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);
String type(String text) {
  var current = value('');
  for (final rune in text.runes) {
    current = formatter.formatEditUpdate(
      current,
      value(current.text + String.fromCharCode(rune)),
    );
  }
  return current.text;
}

class CapitalizationStore implements NotesStore {
  @override
  NotesSnapshot get initialSnapshot => NotesSnapshot.empty();
  NotesSnapshot? saved;
  @override
  Future<void> save(NotesSnapshot snapshot) async => saved = snapshot;
}

void main() {
  test(
    'Typed sentences, opening quotes and new paragraphs are capitalised',
    () {
      expect(
        type('hello. next sentence! another? yes\nnew paragraph'),
        'Hello. Next sentence! Another? Yes\nNew paragraph',
      );
      expect(
        type('  “hello.” (another sentence)'),
        '  “Hello.” (Another sentence)',
      );
      expect(type('hello. “next sentence”'), 'Hello. “Next sentence”');
    },
  );

  test('Internal dots, decimals and URL paths keep their original case', () {
    expect(
      type('visit https://example.com/lower.path?q=value and 3.14'),
      'Visit https://example.com/lower.path?q=value and 3.14',
    );
    expect(type('hello.world'), 'Hello.world');
  });

  test('Pasting, deletion and edits inside a sentence do not rewrite text', () {
    const pasted = 'lowercase pasted text. stays exactly the same';
    expect(formatter.formatEditUpdate(value(''), value(pasted)).text, pasted);
    expect(
      formatter.formatEditUpdate(value('Hello.'), value('Hello')).text,
      'Hello',
    );
    expect(
      formatter
          .formatEditUpdate(
            value('Hello wrld'),
            const TextEditingValue(
              text: 'Hello world',
              selection: TextSelection.collapsed(offset: 8),
            ),
          )
          .text,
      'Hello world',
    );
  });

  test(
    'Active composition stays untouched and committed word is capitalised',
    () {
      const composing = TextEditingValue(
        text: 'école',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      expect(formatter.formatEditUpdate(value(''), composing), composing);
      final committed = formatter.formatEditUpdate(composing, value('école'));
      expect(committed.text, 'École');
      expect(committed.selection.baseOffset, 5);
      expect(committed.composing, TextRange.empty);
    },
  );

  test(
    'Accented initial letters are capitalised without moving the cursor',
    () {
      final result = formatter.formatEditUpdate(value(''), value('é'));
      expect(result.text, 'É');
      expect(result.selection.baseOffset, 1);
    },
  );

  testWidgets('Editor capitalises typed sentence starts and saves the result', (
    tester,
  ) async {
    final store = CapitalizationStore();
    await tester.pumpWidget(QJotterApp(store: store));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await tester.showKeyboard(field);
    var text = '';
    for (final letter in 'hello. next'.split('')) {
      tester.testTextInput.updateEditingValue(value(text + letter));
      await tester.pump();
      text = tester.widget<TextField>(field).controller!.text;
    }
    await tester.pumpAndSettle();
    expect(text, 'Hello. Next');
    expect(store.saved!.selected.text, text);
    expect(
      tester.widget<TextField>(field).textCapitalization,
      TextCapitalization.sentences,
    );
  });
}
