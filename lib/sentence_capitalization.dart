import 'package:flutter/services.dart';

/// Capitalise newly typed sentence starts without rewriting pasted notes,
/// existing text or an active input-method composition.
class SentenceCapitalizationFormatter extends TextInputFormatter {
  const SentenceCapitalizationFormatter();

  static final _sentenceStart = RegExp(
    r'''(?:^|[.!?]["'”’)\]}]*\s+|[\r\n])[\s"'“‘(\[{]*$''',
  );

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.composing.isCollapsed) return newValue;
    final before = oldValue.text, after = newValue.text;
    var start = 0;
    while (start < before.length &&
        start < after.length &&
        before.codeUnitAt(start) == after.codeUnitAt(start)) {
      start++;
    }
    var oldEnd = before.length, end = after.length;
    while (oldEnd > start &&
        end > start &&
        before.codeUnitAt(oldEnd - 1) == after.codeUnitAt(end - 1)) {
      oldEnd--;
      end--;
    }
    // Some keyboards commit a composed word without changing its text.
    final committed = oldValue.composing;
    if (before == after &&
        committed.isValid &&
        !committed.isCollapsed &&
        committed.end <= after.length) {
      start = committed.start;
      end =
          start +
          String.fromCharCode(after.substring(start).runes.first).length;
    } else if (after.substring(start, end).runes.length != 1) {
      return newValue;
    }
    if (!_sentenceStart.hasMatch(after.substring(0, start))) return newValue;
    final typed = after.substring(start, end);
    final upper = typed.toUpperCase();
    if (upper == typed) return newValue;
    final delta = upper.length - typed.length;
    int adjusted(int offset) => offset < end ? offset : offset + delta;
    return newValue.copyWith(
      text: after.replaceRange(start, end, upper),
      selection: newValue.selection.isValid
          ? newValue.selection.copyWith(
              baseOffset: adjusted(newValue.selection.baseOffset),
              extentOffset: adjusted(newValue.selection.extentOffset),
            )
          : newValue.selection,
      composing: TextRange.empty,
    );
  }
}
