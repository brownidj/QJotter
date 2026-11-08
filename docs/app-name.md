# QJotter

**Catch a thought - remember it later**

The app's display name changed to QJotter on 9 November 2026, beginning
with build 12. It was previously called Take this down, and originally used
the working name Notefile. The strapline appears in Help and Settings.
The existing note icon and ⌃⌥⌘N shortcut continue to represent the app.

The macOS bundle is `QJotter.app`, with the same bundle identifier
`com.example.notefile`. The iOS app updates the existing installation using
that same identifier. Existing SQLite notebooks, Keychain sessions, server
addresses and trusted certificates remain associated with the app.

The project is named `QJotter` in Android Studio and lives at
`/Users/david/Documents/ChatGPT/QJotter`. Its Dart package is `qjotter`
(Dart package names use lowercase), and the root app widget is `QJotterApp`.

Compatibility identifiers such as the Swift module and executable, Windows
executable and storage product namespace, method channels, startup registration
keys, server service labels, database paths and certificate names remain stable.
Windows storage plugins derive their paths from the resource ProductName;
changing that value would move both note storage and secure credentials.
Its window title and FileDescription use QJotter.

When launching the Mac build directly, choose `QJotter.app`. The original
Junecloud Notefile application is a separate product and is not renamed.

Validation for build 12: Flutter analysis reports no issues and all 82 Flutter
tests pass. macOS debug build succeeded and QJotter launched with the existing
165-note notebook. The signed iOS Debug build succeeded using the connected
iPhone destination in Xcode and was installed on device
`00008110-001E48A02187601E`; its bundle display name is QJotter. Windows display
metadata was updated but a Windows build was not run on this Mac.

See [protecting the name](name-protection.md) for the registration plan.

The initial iPhone Debug installation was replaced with a signed Profile build
on 9 November 2026 so QJotter can launch from the Home Screen without a debugger.
The Profile build succeeded, installation completed, and standalone launch via
devicectl succeeded. Use Profile or Release for future everyday iPhone installs.

Build 13 was installed on the iPhone to refresh launcher metadata. Both
CFBundleName and CFBundleDisplayName are QJotter; the device's installed-app
registry confirms name QJotter and version 13. The Home Screen label itself
has not been visually verified; an old label may be cached or belong to a
separately named Home Screen shortcut.
