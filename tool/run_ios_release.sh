#!/bin/bash
# Build outside iCloud's synced directories, then install a standalone release.
set -euo pipefail

qjotter_root="$(cd "$(dirname "$0")/.." && pwd)"
qjotter_device="${1:-00008110-001E48A02187601E}"
qjotter_build="$HOME/Library/Developer/QJotterBuild"
qjotter_log="$(mktemp -t qjotter-ios-release)"
cd "$qjotter_root"
if [ ! -f pubspec.yaml ]; then
  echo "Cannot find the Flutter project at: $qjotter_root" >&2
  exit 1
fi

flutter build ios --release --config-only
if ! xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme Runner -configuration Release \
  -destination "id=$qjotter_device" \
  -derivedDataPath "$qjotter_build" \
  -allowProvisioningUpdates build > "$qjotter_log" 2>&1; then
  tail -80 "$qjotter_log"
  echo "Full build log: $qjotter_log" >&2
  exit 1
fi

xcrun devicectl device install app --device "$qjotter_device" \
  "$qjotter_build/Build/Products/Release-iphoneos/Runner.app"
xcrun devicectl device process launch --device "$qjotter_device" \
  --terminate-existing com.example.notefile
echo "QJotter release installed and launched. Build log: $qjotter_log"
