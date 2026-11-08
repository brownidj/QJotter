# QJotter

*Catch a thought - remember it later*

A quick note-taking app for macOS, iOS, and Windows.

## App icon

The editable source is `assets/icons/notefile.svg`: a folded cream note with
three writing strokes on deep green. It uses flat vector shapes and scales
without losing detail. `notefile-desktop.svg` adds rounded corners and transparent
margins for desktop platforms; iOS uses the opaque square master.

To regenerate the PNG asset catalogs, Windows ICO, and preview, install
`rsvg-convert` and ImageMagick (`magick`), then run:

```sh
python3 tool/generate_icons.py
```

The asset catalogs and Windows runner reference the `notefile-v1` exports.
Rebuild the app fully to see the new launcher icon; hot reload does not update it.

## Test quick capture on macOS

1. In Android Studio, select **macOS (desktop)** and run `lib/main.dart`.
   Stop an existing run first: Swift changes require a full rebuild, not hot reload.
2. Click **?** to open Help and check **⌃⌥⌘N ready · works from other apps**.
   Click the solid left arrowhead to return to the editor.
3. Click another app or the desktop. QJotter’s window should disappear while
   QJotter remains running.
4. Hold **Control + Option + Command** and press **N** once. Release the keys.
   QJotter should appear with the editor focused. Type immediately without clicking.
5. Repeat after clicking the red window-close button, and after minimising the window.
   The same note should remain; invoking the shortcut does not create a new note.
6. Open **?**, wait for any **Saving…** message to disappear, quit with **⌘Q**, and run the app again.
   Your notes and selected note should be restored.

Closing or hiding the window keeps the app and shortcut running. **⌘Q** quits
and releases the shortcut. The shortcut cannot launch an app that has quit.
Settings includes automatic launch at login on macOS 13+ and Windows.

If registration fails, Help reports the error. Close any other running copy
of this prototype, or release the combination in another app, and click **Retry shortcut**.
The Mac implementation registers a specific native hotkey; it does not monitor
general keyboard input or request Accessibility permission.

## Organise notes

The bottom bar shows the note count and the selected note's last-edit date.
Click the count to show or hide the note list. Wider windows show the list beside
the editor; compact windows switch between the list and the editor. Notes appear
with their first nonblank line as the title, most recently edited first.
The search icon at the bottom left searches the full text of all notes. Choose
a result to open it, or close search to return to your current note.

Use **+** to create and open a new blank note. Each press creates a separate note,
which stays open when the app syncs. The **…** menu offers
Copy, Export, Delete, and Share. macOS also offers Print. Export saves plain text
on desktop; on iOS, choose Save to Files in the share sheet. Sharing opens the
system's sharing interface, whose available destinations depend on the device.
Every delete action opens an **Are you sure?** dialog with **Cancel** and
**Delete**. There is no deletion notification. Deleting the last note leaves
zero notes; typing on the empty capture page starts a new note.

The toolbar trash button sits between Settings and Help. It is disabled when
no note is highlighted in the visible list. On desktop, click a row
to highlight it, then press Delete or Backspace, or click the toolbar trash button.
Double-click or press Enter to open it for editing. On iPhone, hold a row to
highlight it, then tap the toolbar trash button. List deletion keeps the list and any
search filter open. Confirmed deletions sync to the server.

Notes save to the signed-in user's server database by default. Account setup
appears before the editor when signed out. A local SQLite database,
`notes.sqlite3`, in Application Support caches notes and queues offline edits.
Existing JSON or single-draft notes migrate automatically; the old files are
retained unchanged as backups. The Settings gear provides startup preferences,
server sign-in, account creation, sign-out and sync controls. Account notebooks
remain separate between users. Existing device notes are automatically added
to the first account used on that device, once only. The editor shows whether
changes have reached the server or are still waiting to upload.

The included server provides authenticated cross-device sync once hosted.
See [storage, accounts, startup and server setup](docs/storage-accounts-and-startup.md).
The server is installed locally; see [LAN connection and migration](docs/local-server-and-migration.md).
A Windows global shortcut is not implemented yet.
The Flutter project includes macOS, iOS, and Windows targets; the global shortcut
is currently implemented only in the macOS runner.

## Install on an iPhone for everyday use

Use a profile or release build when the app needs to launch directly from the
Home Screen. A debug build on a physical iPhone requires launching through
Flutter tooling or Xcode; installing it alone is not sufficient.

```sh
flutter build ios --profile
xcrun devicectl device install app --device 00008110-001E48A02187601E build/ios/iphoneos/Runner.app
```

Profile mode supports standalone launch while retaining profiling tools.
For distribution, use a signed release build and the appropriate distribution
method. Keep the existing bundle identifier to update the app and retain data.

## Checks

```sh
flutter analyze
flutter test --coverage
python3 -m unittest discover -s server -v
```

The Flutter suite covers notebook round trips and draft migration, Unicode,
failed and interrupted writes, save ordering and error recovery, creating and
switching notes, deletion confirmation, compact layouts, action dispatch, editor
focus and selection, shortcut failures and retries, disposal during pending
work, and iOS/Windows platform guards. These tests use temporary files and
in-memory stores; they do not modify your notes.

On a Mac with Xcode installed, run the native window lifecycle tests:

```sh
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/notefile-macos-tests
```

These native tests exercise closing, hiding on focus loss or app deactivation,
reopening, minimising, keeping native dialogs open, and the app's keep-running
policy. The native test host uses isolated temporary note storage. These tests
do not simulate the global keyboard chord.
Use the manual quick-capture steps above to verify the real shortcut from
another app. Flutter platform variants check UI behaviour; they are not native
iOS or Windows build tests.
