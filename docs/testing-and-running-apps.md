# Testing and Running macOS and iOS App Installations

This guide provides the necessary commands and steps to test, build, and run the **QJotter** app on macOS and iOS.

---

## 1. Running Unit and UI Tests

Before building or deploying, ensure all tests pass:

```bash
flutter test
```

---

## 2. Building and Running the macOS App

### Build Release macOS App
```bash
flutter build macos --release
```
The built application bundle will be located at:
`build/macos/Build/Products/Release/QJotter.app`

### Run macOS App in Development Mode
```bash
cd "/Users/david/Library/Mobile Documents/com~apple~CloudDocs/android_projects/QJotter"
flutter devices && flutter test && flutter build macos --release
```

---

## 3. Building and Running the iOS App

### Run on iOS Simulator
```bash
flutter run -d ios
```

### Build iOS Simulator / Device Build (Xcode)
If building via Xcode (especially when working with project directories synced via iCloud Drive):
1. Clean extended attributes if codesigning issues arise:
   ```bash
   xattr -rc ios/ macos/ build/ 2>/dev/null || true
   ```
2. Open Xcode workspace:
   ```bash
   open ios/Runner.xcworkspace
   ```
3. Select your target simulator/device and press **Play** (Cmd + R) in Xcode.

4. Or
   ```bash
   cd "/Users/david/Library/Mobile Documents/com~apple~CloudDocs/android_projects/QJotter"
   zsh tool/run_ios_release.sh
```

## iPhone release: dependency graph error recovery

Verified on 9 November 2026 with the connected iPhone. A release build succeeded
using fresh Xcode derived data outside the iCloud source folder. The original
`Exited with status code 255` / dependency graph failure did not establish a
single root cause; stale Xcode build state was bypassed without deleting app data.

Run:

```sh
cd "/Users/david/Library/Mobile Documents/com~apple~CloudDocs/android_projects/QJotter"
bash tool/run_ios_release.sh
```

This configures Flutter for Release, builds using
`~/Library/Developer/QJotterBuild`, installs over the existing app, and launches
without a debugger. The default device is `00008110-001E48A02187601E`; pass a
different UDID as the script's first argument if needed. Connect and unlock the
phone. The bundle identifier is preserved, retaining its existing data.

This installs a development-signed Release build for this device; it does not
upload to TestFlight or the App Store. The script stops if any step fails and
prints the Xcode log path if compilation fails.
