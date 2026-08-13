#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
build_dir="$project_dir/.build/release"
app_bundle="$project_dir/dist/VibeToken.app"

cd "$project_dir"
swift build -c release

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$build_dir/VibeToken" "$app_bundle/Contents/MacOS/VibeToken"
cp "$project_dir/Sources/VibeToken/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$project_dir/Sources/VibeToken/Resources/VibeToken.icns" "$app_bundle/Contents/Resources/VibeToken.icns"

resource_bundle="$build_dir/VibeToken_VibeToken.bundle"
if [ -d "$resource_bundle" ]; then
    cp -R "$resource_bundle" "$app_bundle/Contents/Resources/"
fi

codesign --force --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

echo "$app_bundle"
