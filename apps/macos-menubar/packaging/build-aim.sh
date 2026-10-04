#!/bin/bash
set -euo pipefail
SOURCE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME="${1:?Usage: build-aim.sh VERIFIED_RUNTIME_DIRECTORY}"
APP="$SOURCE/dist/Murmur AIM.app"
python3 "$SOURCE/packaging/verify-runtime.py" "$RUNTIME"
python3 "$SOURCE/packaging/verify-aim.py"
swift build --package-path "$SOURCE" -c release
BIN="$(swift build --package-path "$SOURCE" -c release --show-bin-path)"
"$BIN/MurmurProbeChecks" "$SOURCE/../../contracts/setup/v1/fixtures"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for name in MurmurTrayCore MurmurMenuBar; do
  /usr/bin/ditto "$BIN/MurmurMenuBarSpike_$name.bundle" "$APP/Contents/Resources/MurmurMenuBarSpike_$name.bundle"
done
cp "$BIN/MurmurMenuBar" "$APP/Contents/MacOS/MurmurMenuBar"
cp "$BIN/MurmurRuntimeLauncher" "$APP/Contents/MacOS/murmur"
cp "$SOURCE/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Murmur AIM' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.aimindset.murmur' "$APP/Contents/Info.plist"
python3 "$SOURCE/packaging/stamp-version.py" "$APP/Contents/Info.plist" "$RUNTIME/runtime-manifest.json"
/usr/libexec/PlistBuddy -c "Add :AIMSourceCommit string $(git -C "$SOURCE" rev-parse HEAD)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string MurmurAIM' "$APP/Contents/Info.plist"
/usr/bin/ditto "$RUNTIME" "$APP/Contents/Resources/runtime"
"$BIN/MurmurMenuBar" --aim-icon "$SOURCE/dist/aim-icon.png"
ICONSET="$SOURCE/dist/MurmurAIM.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE/dist/aim-icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE/dist/aim-icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/MurmurAIM.icns"
for binary in MurmurMenuBar murmur; do codesign --force --sign - "$APP/Contents/MacOS/$binary"; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 "$SOURCE/packaging/verify-runtime.py" "$APP/Contents/Resources/runtime"
python3 "$SOURCE/packaging/native-bridge-check.py" "$APP"
printf '%s\n' "$APP"
