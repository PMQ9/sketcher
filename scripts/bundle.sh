#!/bin/sh
# Builds the SwiftPM executable and assembles dist/Sketcher.app.
# Usage: scripts/bundle.sh [debug|release]
set -eu

cd "$(dirname "$0")/.."
CONFIG=${1:-debug}
APP="dist/Sketcher.app"

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Sketcher" "$APP/Contents/MacOS/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Lint matters more here than in a plain app: the plist carries
# CFBundleDocumentTypes and UTExportedTypeDeclarations, and a malformed
# entry silently breaks document-type registration rather than erroring.
plutil -lint "$APP/Contents/Info.plist"

# swift build already ad-hoc-signs the executable; this seals Contents/Resources
# and binds Info.plist, which is what LaunchServices needs. Do not remove.
codesign --force --sign - "$APP"
codesign --verify "$APP"
echo "Bundled: $APP"
