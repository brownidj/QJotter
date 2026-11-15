# Running QJotter

QJotter — **Catch a thought - remember it later**.

These instructions use the current project folder on David’s Mac. Run Flutter commands from the folder containing `pubspec.yaml`, rather than the old `Documents/ChatGPT/Notefile` folder.

## Open the project

In Terminal:

```sh
cd "/Users/david/Library/Mobile Documents/com~apple~CloudDocs/android_projects/QJotter"
flutter pub get
```

In Android Studio, choose **Open**, select this same folder, and open `lib/main.dart`. Use the Flutter run configuration and select the desired device. For an iPhone installation that can be opened independently from the Home Screen, use the release script below.

If Flutter or a platform tool is unavailable, check the development environment:

```sh
flutter doctor -v
flutter devices
```

macOS and iOS builds require Xcode on a Mac. Physical iPhone installation also requires working Apple development signing, pairing/trust, and Developer Mode on the phone.

## macOS: build and launch a release

```sh
cd "/Users/david/Library/Mobile Documents/com~apple~CloudDocs/android_projects/QJotter"
flutter build macos --release
open "build/macos/Build/Products/Release/QJotter.app"
```

If QJotter is already running, quit it from **QJotter → Quit QJotter** before opening the rebuilt app. Otherwise the old process may remain active.

To launch the existing build without rebuilding:

```sh
open "/Users/david/Library/Mobile Documents/com~apple~CloudDocs/android_projects/QJotter/build/macos/Build/Products/Release/QJotter.app"
```

While the Mac app is running, **Control + Option + Command + N** opens its quick-capture window. Clicking outside the window hides it while the app continues running. Automatic startup can be changed in Settings.

For development with hot reload:

```sh
flutter run -d macos
```

## iPhone: install and launch a release

Connect and unlock the iPhone, then run:

```sh
cd "/Users/david/Library/Mobile Documents/com~apple~CloudDocs/android_projects/QJotter"
bash tool/run_ios_release.sh
```

The script defaults to David’s iPhone, device ID `00008110-001E48A02187601E`. It builds Release, installs over the existing app, and launches it without a debugger. Afterwards, tap **QJotter** on the iPhone Home Screen to open it normally.

For another connected device, find its ID with `flutter devices`, then pass that ID:

```sh
bash tool/run_ios_release.sh YOUR_DEVICE_ID
```

The script also works when invoked using `zsh`. It keeps Xcode derived data outside iCloud, at `~/Library/Developer/QJotterBuild`, to avoid the dependency-graph failures previously encountered with the synced project folder. It prints the Xcode log location for troubleshooting.

If installation succeeds but launch is blocked because the phone is locked, unlock the phone and tap QJotter. A debug build cannot be launched independently from the Home Screen on this iPhone; install the release build above. This is a development-signed installation, not an App Store or TestFlight distribution.

## iOS Simulator: development

Start a simulator in Xcode or Android Studio. List available targets, then use the simulator’s actual ID:

```sh
flutter devices
flutter run -d YOUR_SIMULATOR_ID
```

## Writing notes

The first letter of a note, a new paragraph, or a sentence after a full stop and a space is capitalised as you type. Sentence endings with `!` and `?` are supported too. Pasted text and existing notes keep their original capitalisation. Dots within URLs and decimal numbers do not start a new sentence.

## Open a web address in a note

Web addresses appear blue and underlined as you type, while remaining editable plain text. On macOS, hovering over a link shows a pointing hand and a tooltip. Double-click the address to open it in your default browser. On iPhone or Android, double-tap it, then choose **Yes** in the confirmation dialog. Choose **No** to stay in QJotter. Single taps and ordinary text selection continue to work normally.

Addresses beginning with `http://`, `https://`, or `www.` are supported, as are bare domains such as `example.com/path` (opened using HTTPS). Wrapped and scrolled addresses are supported. Email addresses and non-web schemes are left as ordinary text. Opening a link does not change the note.

## Connect to the notes server

On the same local network, open QJotter **Settings**:

1. Enter `https://davids-mac-mini.local:8767` and select **Save server address**.
2. If needed, choose **Import server certificate…** and select `QJotter-Mac-mini-Server.pem`.
3. Sign in with your existing account, or create an account for a new user.

On David’s iPhone, the public certificate is available through **Files → Browse → On My iPhone → QJotter → QJotter-Mac-mini-Server.pem**. A second copy is in **iCloud Drive → QJotter server**.

The server Mac mini must be powered on, awake, connected to the network, and signed into David’s macOS account. Its service starts at login. QJotter uses port 8767 because BeneEde uses port 8766. The MacBook server is retired. Build 18 switches existing MacBook sign-ins and their pending edits to the Mac mini automatically.

Notes have a local SQLite copy for offline use. After signing in, nonempty notes sync to the server; check for the **small green LED at the top left** before expecting another device to have the latest changes. A **larger orange LED** displays the number of records waiting to sync, including deletions and retrying uploads. A **grey LED** means sync has not been confirmed. Hover over the LED, or press and hold it on a phone, to see details. Empty drafts remain local, and clearing a saved note removes its server copy. A newer edit on another device is protected against a stale deletion.

For server status, backups, and startup instructions, see [Mac mini server administration](mac-mini-server.md).

## Windows

Build on a Windows machine with Flutter and the Visual Studio desktop C++ build tools configured. Open the copied project in Android Studio, or change to its folder in PowerShell and run:

```powershell
flutter pub get
flutter run -d windows
```

For a release build:

```powershell
flutter build windows --release
```

Distribute the complete release output folder, including its DLLs and `data` folder. Windows commands are provided for the project’s Windows target; this Mac workflow has not verified a Windows build.

## Run the tests

From the project folder:

```sh
flutter test
flutter analyze
python3 -m unittest discover -s server -p 'test_*.py'
```

The Flutter suite includes regression tests for text entered during sync, lost-response retries, conflict-copy handling, and empty-note deletion. Tests use temporary databases; they do not edit the live server’s notes.

If Flutter reports **No pubspec.yaml file found** or **Test directory "test" not found**, change to the project folder at the top of this guide and retry.
