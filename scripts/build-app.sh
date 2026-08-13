#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
build_dir="$project_dir/.build/release"
app_bundle="$project_dir/dist/VibeToken.app"
app_contents="$app_bundle/Contents"
sparkle_framework="$build_dir/Sparkle.framework"

cd "$project_dir"
swift build -c release

rm -rf "$app_bundle"
mkdir -p "$app_contents/MacOS" "$app_contents/Resources" "$app_contents/Frameworks"
cp "$build_dir/VibeToken" "$app_contents/MacOS/VibeToken"
cp "$project_dir/Sources/VibeToken/Info.plist" "$app_contents/Info.plist"
cp "$project_dir/Sources/VibeToken/Resources/VibeToken.icns" "$app_contents/Resources/VibeToken.icns"

sparkle_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app_contents/Info.plist")"
sparkle_public_key_length="$(printf '%s' "$sparkle_public_key" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
if [ "$sparkle_public_key_length" != "32" ]; then
    echo "Info.plist SUPublicEDKey must be a Base64-encoded 32-byte Ed25519 public key." >&2
    exit 1
fi
sparkle_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app_contents/Info.plist")"
case "$sparkle_feed_url" in
    https://*) ;;
    *)
        echo "Info.plist SUFeedURL must use HTTPS." >&2
        exit 1
        ;;
esac

if [ ! -d "$sparkle_framework" ]; then
    echo "Sparkle.framework was not produced by SwiftPM." >&2
    exit 1
fi
ditto "$sparkle_framework" "$app_contents/Frameworks/Sparkle.framework"

resource_bundle="$build_dir/VibeToken_VibeToken.bundle"
if [ -d "$resource_bundle" ]; then
    cp -R "$resource_bundle" "$app_contents/Resources/"
fi

codesign --force --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

echo "$app_bundle"
