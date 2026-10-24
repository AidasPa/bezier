#!/bin/zsh
# Builds build/Bezier.app from the SwiftPM package. Usage: scripts/build.sh [debug|release]
set -euo pipefail
cd "${0:A:h}/.."
config="${1:-debug}"
swift build -c "$config" --product Bezier
bin="$(swift build -c "$config" --show-bin-path)"
app="build/Bezier.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Bezier" "$app/Contents/MacOS/Bezier"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null
echo "built $app ($config)"
