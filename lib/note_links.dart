import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:url_launcher/url_launcher.dart';

abstract class NoteLinkOpener {
  const NoteLinkOpener();
  Future<bool> open(Uri address);
}

class BrowserNoteLinkOpener extends NoteLinkOpener {
  const BrowserNoteLinkOpener();
  @override
  Future<bool> open(Uri address) =>
      launchUrl(address, mode: LaunchMode.externalApplication);
}

class NoteLink {
  const NoteLink(this.start, this.end, this.address);
  final int start, end;
  final Uri address;
}

/// Find web addresses without treating email addresses or other URI schemes as
/// links. Display wrapping is handled by RenderEditable, not by splitting text.
List<NoteLink> noteLinks(String text) {
  final pattern = RegExp(
    r'''https?://[^\s<>"'“”‘’]+|www\.[^\s<>"'“”‘’]+|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?::[0-9]{1,5})?(?:[/?#][^\s<>"'“”‘’]*)?''',
    caseSensitive: false,
  );
  final links = <NoteLink>[];
  for (final match in pattern.allMatches(text)) {
    if (match.start > 0 &&
        RegExp(r'[\w@./:+-]').hasMatch(text[match.start - 1])) {
      continue;
    }
    var raw = match.group(0)!;
    final explicit = RegExp(r'^https?://', caseSensitive: false).hasMatch(raw);
    if (!explicit) {
      var left = match.start, right = match.end;
      while (left > 0 && !RegExp(r'''[\s<>"']''').hasMatch(text[left - 1])) {
        left--;
      }
      while (right < text.length &&
          !RegExp(r'''[\s<>"']''').hasMatch(text[right])) {
        right++;
      }
      if (text
          .substring(left, right)
          .split(RegExp(r'[/#?]'))
          .first
          .contains('@')) {
        continue;
      }
    }
    while (raw.isNotEmpty) {
      final last = raw[raw.length - 1];
      final opening = {')': '(', ']': '[', '}': '{'}[last];
      final unbalanced =
          opening != null &&
          last.allMatches(raw).length > opening.allMatches(raw).length;
      if (!'.,;!?:'.contains(last) && !unbalanced) break;
      raw = raw.substring(0, raw.length - 1);
    }
    try {
      final uri = Uri.tryParse(explicit ? raw : 'https://$raw');
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme.toLowerCase()) ||
          uri.host.isEmpty ||
          uri.port > 65535) {
        continue;
      }
      links.add(NoteLink(match.start, match.start + raw.length, uri));
    } on FormatException {
      // Malformed addresses remain ordinary editable text.
    }
  }
  return links;
}

/// Render links without inserting formatting into the persisted plain text.
class NoteEditingController extends TextEditingController {
  NoteEditingController({super.text});

  static const linkColor = Color(0xFF1565C0);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final links = noteLinks(text);
    final composing = value.composing;
    final showComposing =
        withComposing &&
        composing.isValid &&
        !composing.isCollapsed &&
        composing.end <= text.length;
    final boundaries = <int>{
      0,
      text.length,
      for (final link in links) ...[link.start, link.end],
      if (showComposing) ...[composing.start, composing.end],
    }.toList()..sort();
    final spans = <TextSpan>[];
    var linkIndex = 0;
    for (var i = 0; i < boundaries.length - 1; i++) {
      final start = boundaries[i], end = boundaries[i + 1];
      while (linkIndex < links.length && links[linkIndex].end <= start) {
        linkIndex++;
      }
      final isLink =
          linkIndex < links.length &&
          links[linkIndex].start <= start &&
          end <= links[linkIndex].end;
      final isComposing =
          showComposing && composing.start <= start && end <= composing.end;
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: isLink
              ? const TextStyle(
                  color: linkColor,
                  decoration: TextDecoration.underline,
                  decorationColor: linkColor,
                )
              : isComposing
              ? const TextStyle(decoration: TextDecoration.underline)
              : null,
        ),
      );
    }
    return TextSpan(style: style, children: spans);
  }
}

/// Observe pointer events without competing with the editor's selection,
/// scrolling, dragging or keyboard gestures.
class NoteLinkListener extends StatefulWidget {
  const NoteLinkListener({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.child,
  });
  final TextEditingController controller;
  final ValueChanged<Uri> onOpen;
  final Widget child;
  @override
  State<NoteLinkListener> createState() => _NoteLinkListenerState();
}

class _NoteLinkListenerState extends State<NoteLinkListener> {
  NoteLink? _hovered;
  PointerDownEvent? _down;
  NoteLink? _previous;
  Offset? _previousPosition;
  Duration? _previousTime;
  String? _previousText;

  void _reset() {
    _previous = null;
    _previousPosition = null;
    _previousTime = null;
    _previousText = null;
  }

  NoteLink? _linkAt(Offset position) {
    RenderEditable? editable;
    void visit(RenderObject object) {
      if (object is RenderEditable) {
        editable = object;
        return;
      }
      object.visitChildren(visit);
    }

    final root = context.findRenderObject();
    if (root == null) return null;
    visit(root);
    if (editable == null) return null;
    final local = editable!.globalToLocal(position);
    final offset = editable!.getPositionForPoint(position).offset;
    for (final link in noteLinks(widget.controller.text)) {
      if (offset < link.start || offset > link.end) continue;
      final boxes = editable!.getBoxesForSelection(
        TextSelection(baseOffset: link.start, extentOffset: link.end),
      );
      if (boxes.any((box) => box.toRect().inflate(1).contains(local))) {
        return link;
      }
    }
    return null;
  }

  void _hover(Offset? position) {
    final link = position == null ? null : _linkAt(position);
    if (link?.start != _hovered?.start || link?.end != _hovered?.end) {
      setState(() => _hovered = link);
    }
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: _hovered == null
        ? SystemMouseCursors.text
        : SystemMouseCursors.click,
    onEnter: (event) => _hover(event.position),
    onHover: (event) => _hover(event.position),
    onExit: (_) => _hover(null),
    child: Tooltip(
      message: _hovered == null ? '' : 'Double-click to open in your browser.',
      triggerMode: TooltipTriggerMode.manual,
      child: Listener(
        onPointerSignal: (_) => _reset(),
        onPointerDown: (event) {
          if (_down != null || event.buttons != kPrimaryButton) {
            _down = null;
            _reset();
            return;
          }
          _down = event;
        },
        onPointerMove: (event) {
          if (_down != null &&
              (event.position - _down!.position).distance > kTouchSlop) {
            _down = null;
            _reset();
          }
        },
        onPointerCancel: (_) {
          _down = null;
          _reset();
        },
        onPointerUp: (event) {
          final down = _down;
          _down = null;
          if (down == null ||
              down.pointer != event.pointer ||
              event.timeStamp - down.timeStamp > kLongPressTimeout) {
            _reset();
            return;
          }
          final link = _linkAt(event.position);
          if (link == null) {
            _reset();
            return;
          }
          if (_previous?.start == link.start &&
              _previous?.end == link.end &&
              _previousText == widget.controller.text &&
              _previousTime != null &&
              down.timeStamp - _previousTime! <= kDoubleTapTimeout &&
              (event.position - _previousPosition!).distance <=
                  kDoubleTapSlop) {
            _reset();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onOpen(link.address);
            });
          } else {
            _previous = link;
            _previousPosition = event.position;
            _previousTime = event.timeStamp;
            _previousText = widget.controller.text;
          }
        },
        child: widget.child,
      ),
    ),
  );
}
