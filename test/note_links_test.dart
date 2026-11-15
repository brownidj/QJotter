import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/main.dart';
import 'package:qjotter/note_links.dart';
import 'package:qjotter/notes_store.dart';

class LinkTestStore implements NotesStore {
  LinkTestStore(String text) : initialSnapshot = NotesSnapshot.fromDraft(text);
  @override
  final NotesSnapshot initialSnapshot;
  NotesSnapshot? saved;
  @override
  Future<void> save(NotesSnapshot snapshot) async {
    saved = snapshot;
  }
}

class RecordingBrowser extends NoteLinkOpener {
  final opened = <Uri>[];
  bool succeeds = true;
  @override
  Future<bool> open(Uri address) async {
    opened.add(address);
    return succeeds;
  }
}

String controllerText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  test('Web address detection preserves paths, queries and balanced punctuation', () {
    const text =
        'See (https://example.com/a_(b)?q=one&next=two#part), '
        'www.example.org/path. example.net/start?x=2; HTTP://localhost:8767/health';
    final links = noteLinks(text);
    expect(links.map((l) => l.address), [
      Uri.parse('https://example.com/a_(b)?q=one&next=two#part'),
      Uri.parse('https://www.example.org/path'),
      Uri.parse('https://example.net/start?x=2'),
      Uri.parse('http://localhost:8767/health'),
    ]);
    for (final link in links) {
      expect(text.substring(link.start, link.end), isNot(endsWith(',')));
    }
  });

  test('Email addresses, unsafe schemes and malformed addresses stay ordinary text', () {
    expect(
      noteLinks(
        'person@example.com user.name+tag@example.org '
        'mailto:someone@example.net javascript:alert(1) file://example.org/a '
        'https:// https://example.org:99999',
      ),
      isEmpty,
    );
  });

  Future<void> load(
    WidgetTester tester,
    String text,
    RecordingBrowser browser, {
    double width = 390,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      QJotterApp(store: LinkTestStore(text), linkOpener: browser),
    );
    await tester.pumpAndSettle();
  }

  Offset character(WidgetTester tester, int offset) {
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final box = editable
        .getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: offset + 1),
        )
        .first
        .toRect();
    return editable.localToGlobal(box.center);
  }

  Future<void> doublePress(
    WidgetTester tester,
    Offset point, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
  }) async {
    await tester.tapAt(point, kind: kind);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(point, kind: kind);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Link styling updates as text is typed and preserves composing text',
    (tester) async {
      final browser = RecordingBrowser();
      await load(tester, 'Plain words', browser);
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      const text = 'Plain https://example.com/path tail';
      controller.value = const TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: 16),
        composing: TextRange(start: 2, end: 16),
      );
      await tester.pump();
      final span = controller.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        style: const TextStyle(fontSize: 18),
        withComposing: true,
      );
      expect(span.toPlainText(), text);
      final children = span.children!.cast<TextSpan>();
      expect(
        children
            .where((s) => s.style?.color == NoteEditingController.linkColor)
            .map((s) => s.text)
            .join(),
        'https://example.com/path',
      );
      expect(
        children
            .where((s) => s.style?.color == NoteEditingController.linkColor)
            .every((s) => s.style?.decoration == TextDecoration.underline),
        isTrue,
      );
      expect(
        children.any(
          (s) =>
              s.text == 'ain ' &&
              s.style?.decoration == TextDecoration.underline,
        ),
        isTrue,
      );
      expect(controller.value.composing, const TextRange(start: 2, end: 16));
      await tester.enterText(find.byType(TextField), 'No address now');
      final plain = controller.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        withComposing: false,
      );
      expect(plain.toPlainText(), 'No address now');
      expect(
        plain.children!.cast<TextSpan>().every((s) => s.style == null),
        isTrue,
      );
    },
  );

  testWidgets(
    'Hovering a URL shows its cursor and tooltip, leaving it clears both',
    (tester) async {
      const text = 'Plain words\nhttps://example.com/path';
      final browser = RecordingBrowser();
      await load(tester, text, browser, width: 900);
      final mouse = TestGesture(
        dispatcher: tester.sendEventToBinding,
        kind: PointerDeviceKind.mouse,
        device: 42,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(character(tester, text.indexOf('example') + 2));
      await tester.pumpAndSettle();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(42),
        SystemMouseCursors.click,
      );
      expect(
        find.text('Double-click to open in your browser.'),
        findsOneWidget,
      );
      expect(browser.opened, isEmpty);
      await mouse.moveTo(character(tester, 2));
      await tester.pumpAndSettle();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(42),
        SystemMouseCursors.text,
      );
      expect(find.text('Double-click to open in your browser.'), findsNothing);
      expect(controllerText(tester), text);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    'Mobile double-tap asks first; No cancels and Yes opens the exact address',
    (tester) async {
      const text =
          'A note\nVisit https://example.com/path?q=notes#section today';
      final browser = RecordingBrowser();
      await load(tester, text, browser);
      final point = character(tester, text.indexOf('example') + 2);
      await doublePress(tester, point);
      expect(find.text('Open link?'), findsOneWidget);
      expect(
        find.text('https://example.com/path?q=notes#section'),
        findsOneWidget,
      );
      expect(browser.opened, isEmpty);
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      expect(browser.opened, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        text,
      );
      await doublePress(tester, point);
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(browser.opened, [
        Uri.parse('https://example.com/path?q=notes#section'),
      ]);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        text,
      );
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'macOS double-click opens directly and single clicks retain normal editing',
    (tester) async {
      const text =
          'Normal words\nhttps://example.com/first\nhttps://example.org/second';
      final browser = RecordingBrowser();
      await load(tester, text, browser, width: 900);
      final point = character(tester, text.indexOf('example.org') + 3);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(browser.opened, isEmpty);
      // Let the first click expire before testing a fresh double click.
      await tester.pump(const Duration(seconds: 1));
      await doublePress(tester, point, kind: PointerDeviceKind.mouse);
      expect(find.text('Open link?'), findsNothing);
      expect(browser.opened, [Uri.parse('https://example.org/second')]);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        text,
      );
      await doublePress(
        tester,
        character(tester, 2),
        kind: PointerDeviceKind.mouse,
      );
      expect(browser.opened, hasLength(1));
      expect(
        tester
            .widget<TextField>(find.byType(TextField))
            .controller!
            .selection
            .isCollapsed,
        isFalse,
      );
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    'Wrapped bare URLs open, but whitespace beside or below them does not',
    (tester) async {
      final url =
          'example.com/${List.filled(18, 'long-path/').join()}?value=123';
      final text = 'Wrapped link\n$url\n';
      final browser = RecordingBrowser();
      await load(tester, text, browser);
      final point = character(tester, text.indexOf(url) + 80);
      await doublePress(tester, point);
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(browser.opened.single, Uri.parse('https://$url'));
      final blank =
          tester.getBottomLeft(find.byType(TextField)) + const Offset(60, -12);
      await doublePress(tester, blank);
      expect(browser.opened, hasLength(1));
      expect(find.text('Open link?'), findsNothing);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'A URL in a vertically scrolled note still opens the correct address',
    (tester) async {
      final text =
          '${List.generate(35, (i) => 'Paragraph $i of this note').join('\n')}\nhttps://example.com/after-scrolling';
      final browser = RecordingBrowser();
      await load(tester, text, browser);
      await tester.drag(find.byType(TextField), const Offset(0, -1800));
      await tester.pumpAndSettle();
      final point = character(tester, text.indexOf('example.com') + 3);
      expect(tester.getRect(find.byType(TextField)).contains(point), isTrue);
      await doublePress(tester, point);
      expect(find.text('Open link?'), findsOneWidget);
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(browser.opened, [
        Uri.parse('https://example.com/after-scrolling'),
      ]);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'Dragging a URL does not open it; launch failure is recoverable',
    (tester) async {
      const text = 'https://example.com/path';
      final browser = RecordingBrowser()..succeeds = false;
      await load(tester, text, browser, width: 900);
      final point = character(tester, 10);
      final drag = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(60, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(browser.opened, isEmpty);
      await doublePress(tester, point, kind: PointerDeviceKind.mouse);
      expect(browser.opened, hasLength(1));
      expect(
        find.text('Could not open this address in your browser.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        text,
      );
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );
}
