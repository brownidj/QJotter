import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'note_actions.dart';
import 'notes_store.dart';
import 'app_services.dart';
import 'app_identity.dart';
import 'settings_page.dart';

const quickCaptureChannel = MethodChannel('notefile/quick_capture');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Native XCTest hosts must never migrate or edit the user's real notebook.
  final testing = Platform.environment.containsKey(
    'XCTestConfigurationFilePath',
  );
  final directory = testing
      ? await Directory.systemTemp.createTemp('notefile-native-tests-')
      : await getApplicationSupportDirectory();
  final store = await NotesStore.open(directory);
  final services = testing
      ? null
      : AppServices(
          store: store,
          vault: SecureSessionVault(),
          startup: PlatformStartupManager(),
        );
  await services?.initialize();
  runApp(QJotterApp(store: store, services: services));
}

class QJotterApp extends StatelessWidget {
  const QJotterApp({
    super.key,
    required this.store,
    this.actions = const PlatformNoteActions(),
    this.services,
  });
  final NotesStore store;
  final NoteActions actions;
  final AppServices? services;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: appName,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF38685B)),
      useMaterial3: true,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: EdgeInsets.fromLTRB(16, 5, 16, 64),
      ),
    ),
    home: QuickCapturePage(store: store, actions: actions, services: services),
  );
}

class QuickCapturePage extends StatefulWidget {
  const QuickCapturePage({
    super.key,
    required this.store,
    required this.actions,
    this.services,
  });
  final NotesStore store;
  final NoteActions actions;
  final AppServices? services;
  @override
  State<QuickCapturePage> createState() => _QuickCapturePageState();
}

enum _NoteAction { copy, export, print, delete, share }

class _QuickCapturePageState extends State<QuickCapturePage> {
  final _editorFocus = FocusNode();
  final _searchFocus = FocusNode();
  final _listFocus = FocusNode();
  final _searchText = TextEditingController();
  final _actionsKey = GlobalKey();
  final _editingValues = <String, TextEditingValue>{};
  late final TextEditingController _text;
  late NotesSnapshot _notes;
  Future<void> _pendingSave = Future.value();
  int _saveRevision = 0;
  String? _saveStatus;
  String _shortcutStatus = 'Registering ⌃⌥⌘N…';
  bool _shortcutFailed = false;
  bool _showingHelp = false;
  bool _showingList = false;
  bool _sidebarVisible = true;
  bool _actionBusy = false;
  bool _confirmingDeletion = false;
  bool _searching = false;
  String _query = '';
  int _notebookRevision = 0;
  String? _profile;
  AppLifecycleListener? _lifecycle;
  bool get _isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  bool get _isDesktop => const [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ].contains(defaultTargetPlatform);
  bool get _hasHighlightedNote {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return _notes.notes.isNotEmpty &&
        !_confirmingDeletion &&
        !_showingHelp &&
        (wide ? _sidebarVisible : _showingList) &&
        _notes.selected.text.toLowerCase().contains(
          _query.trim().toLowerCase(),
        );
  }

  @override
  void initState() {
    super.initState();
    _notes = widget.store.initialSnapshot;
    _text = TextEditingController(text: _notes.selected.text);
    _notebookRevision = widget.services?.notebookRevision ?? 0;
    _profile = widget.services?.store.profile;
    widget.services?.addListener(_servicesChanged);
    if (widget.services != null) {
      _lifecycle = AppLifecycleListener(
        onResume: () => unawaited(widget.services!.sync()),
      );
    }
    if (_isMac) {
      quickCaptureChannel.setMethodCallHandler((call) async {
        if (call.method == 'focusEditor') {
          Navigator.of(context).popUntil((route) => route.isFirst);
          _returnToEditor();
        }
      });
      unawaited(_registerShortcut());
    }
  }

  void _servicesChanged() {
    final services = widget.services!;
    if (!mounted) return;
    if (_notebookRevision == services.notebookRevision) {
      setState(() {});
      return;
    }
    _notebookRevision = services.notebookRevision;
    if (_profile != services.store.profile) {
      _editingValues.clear();
      _profile = services.store.profile;
    }
    setState(() {
      _notes = services.store.initialSnapshot;
      if (_text.text != _notes.selected.text) {
        final offset = _text.selection.baseOffset.clamp(
          0,
          _notes.selected.text.length,
        );
        _text.value = TextEditingValue(
          text: _notes.selected.text,
          selection: TextSelection.collapsed(offset: offset),
        );
      }
    });
  }

  Future<void> _openSettings() async {
    _editorFocus.unfocus();
    _searchFocus.unfocus();
    Future<void> pending;
    do {
      pending = _pendingSave;
      await pending;
    } while (pending != _pendingSave);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(services: widget.services!),
      ),
    );
  }

  Future<void> _registerShortcut() async {
    try {
      await quickCaptureChannel.invokeMethod<void>('registerShortcut');
      if (!mounted) return;
      setState(() {
        _shortcutStatus = '⌃⌥⌘N ready · works from other apps';
        _shortcutFailed = false;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _shortcutStatus = error.message ?? 'Shortcut unavailable';
        _shortcutFailed = true;
      });
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _shortcutStatus =
            'Stop and rebuild the Mac app to enable the shortcut.';
        _shortcutFailed = true;
      });
    }
  }

  void _persist() {
    final snapshot = _notes;
    final revision = ++_saveRevision;
    setState(() => _saveStatus = 'Saving…');
    _pendingSave = _pendingSave.then((_) async {
      try {
        await widget.store.save(snapshot);
        if (!mounted || revision != _saveRevision) return;
        setState(() => _saveStatus = null);
      } catch (_) {
        if (!mounted || revision != _saveRevision) return;
        setState(() => _saveStatus = 'Could not save notes');
      }
    });
  }

  void _editNote(String text) {
    setState(() => _notes = _notes.editSelected(text));
    _persist();
  }

  void _returnToEditor() {
    _listFocus.unfocus();
    _searchText.clear();
    setState(() {
      _showingHelp = false;
      _showingList = false;
      _searching = false;
      _query = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editorFocus.requestFocus();
    });
  }

  void _openSearch() {
    _listFocus.unfocus();
    _editorFocus.unfocus();
    setState(() {
      _showingHelp = false;
      _searching = true;
      _showingList = true;
      _sidebarVisible = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _loadSelection(NotesSnapshot snapshot, {bool returnToEditor = true}) {
    _editingValues[_notes.selectedId] = _text.value;
    setState(() {
      _notes = snapshot;
      final cached = _editingValues[snapshot.selectedId];
      _text.value =
          (cached?.text == snapshot.selected.text ? cached : null) ??
          TextEditingValue(
            text: snapshot.selected.text,
            selection: TextSelection.collapsed(
              offset: snapshot.selected.text.length,
            ),
          );
    });
    _persist();
    if (returnToEditor) _returnToEditor();
  }

  void _addNote() {
    _loadSelection(_notes.add(Note.create()));
  }

  Future<void> _deleteNote({bool fromList = false}) async {
    if (_confirmingDeletion || _notes.notes.isEmpty) return;
    final targetId = _notes.selectedId;
    final targetProfile = _profile;
    final title = _notes.selected.title;
    setState(() => _confirmingDeletion = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Are you sure?'),
        content: Text(
          'Delete “$title”? This will delete the note from your synced devices too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirmingDeletion = false);
    if (confirmed != true ||
        targetProfile != _profile ||
        !_notes.notes.any((note) => note.id == targetId)) {
      return;
    }
    var next = _notes.select(targetId).removeSelected();
    if (fromList) {
      final matches = next.recentFirst.where(
        (note) => note.text.toLowerCase().contains(_query.trim().toLowerCase()),
      );
      if (matches.isNotEmpty) next = next.select(matches.first.id);
    }
    _editingValues.remove(targetId);
    _loadSelection(next, returnToEditor: !fromList);
    if (fromList) _listFocus.requestFocus();
  }

  void _highlightNote(Note note) {
    _editorFocus.unfocus();
    _searchFocus.unfocus();
    _loadSelection(_notes.select(note.id), returnToEditor: false);
    _listFocus.requestFocus();
  }

  KeyEventResult _listKeyEvent(FocusNode node, KeyEvent event) {
    if (!_hasHighlightedNote) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      if (event is KeyDownEvent) {
        _deleteNote(fromList: true);
      }
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
      _returnToEditor();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Rect get _shareOrigin {
    final box = _actionsKey.currentContext?.findRenderObject() as RenderBox?;
    return box == null
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _performAction(_NoteAction action) async {
    if (action == _NoteAction.delete) {
      _deleteNote();
      return;
    }
    final note = _notes.selected;
    final origin = _shareOrigin;
    setState(() => _actionBusy = true);
    var suspended = false;
    try {
      if (_isMac && action != _NoteAction.copy) {
        await quickCaptureChannel.invokeMethod<void>('beginExternalAction');
        suspended = true;
      }
      switch (action) {
        case _NoteAction.copy:
          await widget.actions.copy(note);
        case _NoteAction.export:
          await widget.actions.export(note, origin);
        case _NoteAction.share:
          await widget.actions.share(note, origin);
        case _NoteAction.print:
          await widget.actions.print(note);
        case _NoteAction.delete:
          break;
      }
      if (mounted && action == _NoteAction.copy) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Note copied')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not complete this action. Please try again.'),
          ),
        );
      }
    } finally {
      if (suspended) {
        try {
          await quickCaptureChannel.invokeMethod<void>('endExternalAction');
        } on PlatformException {
          /* The window may already have closed. */
        } on MissingPluginException {
          /* A native restart may be in progress. */
        }
      }
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  String _date(DateTime value, {bool compact = false}) {
    final local = value.toLocal();
    final pattern = compact
        ? 'd MMM'
        : local.year == DateTime.now().year
        ? 'd MMMM'
        : 'd MMMM yyyy';
    return DateFormat(pattern).format(local);
  }

  Widget _noteList() {
    final query = _query.trim().toLowerCase();
    final notes = _notes.recentFirst
        .where((note) => note.text.toLowerCase().contains(query))
        .toList();
    if (notes.isEmpty) {
      return Center(
        child: Text(
          _notes.notes.isEmpty ? 'No notes yet' : 'No matching notes',
        ),
      );
    }
    return Focus(
      focusNode: _listFocus,
      onKeyEvent: _listKeyEvent,
      child: ListView.separated(
        key: const ValueKey('notes-list'),
        itemCount: notes.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final note = notes[index];
          final selected = note.id == _notes.selectedId;
          return Listener(
            key: ValueKey('note-${note.id}'),
            // Highlight on mouse-down so a quick Delete cannot target the
            // previous row while the double-click recognizer is waiting.
            onPointerDown: _isDesktop
                ? (event) {
                    if (event.buttons == kPrimaryMouseButton) {
                      _highlightNote(note);
                    }
                  }
                : null,
            child: GestureDetector(
              onDoubleTap: _isDesktop
                  ? () => _loadSelection(_notes.select(note.id))
                  : null,
              child: ListTile(
                selected: selected,
                selectedTileColor: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.45),
                title: Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                trailing: Text(
                  _date(note.updatedAt, compact: true),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onTap: _isDesktop
                    ? () => _highlightNote(note)
                    : () => _loadSelection(_notes.select(note.id)),
                onLongPress: () => _highlightNote(note),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _footer(bool wide) {
    final count = _notes.notes.length;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.25),
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Search notes',
                onPressed: _openSearch,
                icon: const Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: () {
                _editorFocus.unfocus();
                _searchFocus.unfocus();
                _searchText.clear();
                setState(() {
                  _showingHelp = false;
                  _searching = false;
                  _query = '';
                  if (wide) {
                    _sidebarVisible = !_sidebarVisible;
                  } else {
                    _showingList = !_showingList;
                  }
                });
                if ((wide && _sidebarVisible) || (!wide && _showingList)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _listFocus.requestFocus();
                  });
                } else {
                  _returnToEditor();
                }
              },
              child: Text(
                count == 0
                    ? '0 notes'
                    : '$count ${count == 1 ? 'note' : 'notes'} · ${_date(_notes.selected.updatedAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          PopupMenuButton<_NoteAction>(
            key: _actionsKey,
            tooltip: 'Note actions',
            enabled: !_actionBusy,
            icon: const Icon(Icons.more_horiz),
            onSelected: _performAction,
            itemBuilder: (_) => [
              const PopupMenuItem(value: _NoteAction.copy, child: Text('Copy')),
              const PopupMenuItem(
                value: _NoteAction.export,
                child: Text('Export…'),
              ),
              if (widget.actions.supportsPrinting)
                const PopupMenuItem(
                  value: _NoteAction.print,
                  child: Text('Print…'),
                ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: _NoteAction.delete,
                enabled: _notes.notes.isNotEmpty && !_confirmingDeletion,
                child: const Text('Delete'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: _NoteAction.share,
                enabled: _notes.selected.text.isNotEmpty,
                child: const Text('Share…'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'New note',
            onPressed: _addNote,
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildHelp(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(appName, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(appStrapline),
        const SizedBox(height: 24),
        Text('Help', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        const Text(
          'Use + to add a note, '
          'and click the note count at the bottom to show or hide your notes. '
          'Use the search icon at the bottom left to search the text of all your notes. '
          'The first line of each note becomes its title. The … menu has copy, '
          'export, sharing and delete options. You will be asked to confirm before a note is deleted.',
        ),
        const SizedBox(height: 8),
        Text(
          _isDesktop
              ? 'Click a note in the list to highlight it. Click the trash button at the top or press Delete or Backspace to delete it. Double-click the note or press Enter to open it for editing.'
              : 'Hold a note in the list to highlight it, then tap the trash button at the top to delete it. Tap a note to open it.',
        ),
        const SizedBox(height: 8),
        const Text(
          'The trash button is disabled when no note is highlighted in the visible list.',
        ),
        if (_saveStatus != null) ...[
          const SizedBox(height: 8),
          Text(_saveStatus!),
        ],
        if (_isMac) ...[
          const SizedBox(height: 20),
          Text(_shortcutStatus),
          if (_shortcutFailed)
            TextButton(
              onPressed: _registerShortcut,
              child: const Text('Retry shortcut'),
            ),
          const SizedBox(height: 8),
          const Text(
            'On macOS, ⌃ means Control, ⌥ means Option (Alt), and ⌘ means Command. '
            'Hold Control + Option + Command together, press N once, then release '
            'the keys. This brings $appName to the front from any app and focuses '
            'your current note so you can start typing immediately. '
            'It reopens the same note rather than creating a new one.',
          ),
          const SizedBox(height: 20),
          const Text(
            'Click outside this window, or click its red close button, '
            'to close the window. $appName keeps running in the background. '
            'Press ⌃⌥⌘N to reopen your note. ⌘Q (Command + Q) quits $appName '
            'and turns off the shortcut. If you have quit, launch $appName '
            'from its app icon before using the shortcut again.',
          ),
        ],
      ],
    ),
  );

  @override
  void dispose() {
    if (_isMac) quickCaptureChannel.setMethodCallHandler(null);
    widget.services?.removeListener(_servicesChanged);
    _lifecycle?.dispose();
    _text.dispose();
    _editorFocus.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    if (services != null && services.session == null) {
      return SettingsPage(services: services, accountRequired: true);
    }
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (widget.services != null)
            IconButton(
              tooltip: 'Settings',
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          IconButton(
            tooltip: 'Delete highlighted note',
            icon: const Icon(Icons.delete_outline),
            onPressed: _hasHighlightedNote
                ? () => _deleteNote(fromList: true)
                : null,
          ),
          Tooltip(
            message: _showingHelp ? 'Return to note' : 'Help',
            child: TextButton(
              onPressed: () {
                if (_showingHelp) {
                  _returnToEditor();
                } else {
                  _editorFocus.unfocus();
                  _searchFocus.unfocus();
                  _listFocus.unfocus();
                  setState(() => _showingHelp = true);
                }
              },
              child: _showingHelp
                  ? const Icon(Icons.arrow_left_rounded, size: 32)
                  : const Text('?', style: TextStyle(fontSize: 24)),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            return Column(
              children: [
                if (_searching && !_showingHelp)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      key: const ValueKey('note-search'),
                      controller: _searchText,
                      focusNode: _searchFocus,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search notes…',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          tooltip: 'Close search',
                          onPressed: _returnToEditor,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _showingHelp ? 1 : 0,
                    children: [
                      Row(
                        children: [
                          if (wide && _sidebarVisible) ...[
                            SizedBox(width: 240, child: _noteList()),
                            const VerticalDivider(width: 1),
                          ],
                          Expanded(
                            child: IndexedStack(
                              index: !wide && _showingList ? 1 : 0,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    8,
                                    24,
                                    16,
                                  ),
                                  child: TextField(
                                    controller: _text,
                                    focusNode: _editorFocus,
                                    autofocus: true,
                                    expands: true,
                                    minLines: null,
                                    maxLines: null,
                                    textAlignVertical: TextAlignVertical.top,
                                    keyboardType: TextInputType.multiline,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      height: 1.5,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: 'Start typing a note…',
                                      border: InputBorder.none,
                                    ),
                                    onChanged: _editNote,
                                  ),
                                ),
                                if (!wide) _noteList() else const SizedBox(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                        child: _buildHelp(context),
                      ),
                    ],
                  ),
                ),
                if (!_showingHelp && services != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Tooltip(
                      message: _saveStatus ?? services.syncStatus,
                      child: Text(
                        _saveStatus ?? services.syncStatus,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                if (!_showingHelp) _footer(wide),
              ],
            );
          },
        ),
      ),
    );
  }
}
