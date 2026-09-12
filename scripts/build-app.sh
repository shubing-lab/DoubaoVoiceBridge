#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

build_root="$(mktemp -d "${TMPDIR:-/tmp}/doubao-voice-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT

# SwiftPM's current unified output directory can overwrite the first
# architecture. Keep the two release products in separate scratch paths so
# lipo always receives both slices.
swift build -c release --arch x86_64 -j 2 --scratch-path "$build_root/x86_64"
swift build -c release --arch arm64 -j 2 --scratch-path "$build_root/arm64"

stage_app="$build_root/远控听写.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$project_root/Resources/Info.plist" "$stage_app/Contents/Info.plist"

lipo -create \
    "$build_root/x86_64/out/Products/Release/DoubaoVoiceBridge" \
    "$build_root/arm64/out/Products/Release/DoubaoVoiceBridge" \
    -output "$stage_app/Contents/MacOS/DoubaoVoiceBridge"
chmod 755 "$stage_app/Contents/MacOS/DoubaoVoiceBridge"

codesign --force --sign - \
    --identifier com.lyp.DoubaoVoiceBridge \
    --requirements '=designated => identifier "com.lyp.DoubaoVoiceBridge"' \
    "$stage_app"

mkdir -p "$project_root/dist"
output_app="$project_root/dist/远控听写.app"
if [[ -e "$output_app" ]]; then
    rm -rf "$output_app"
fi
ditto "$stage_app" "$output_app"

codesign --verify --deep --strict --verbose=2 "$output_app"
file "$output_app/Contents/MacOS/DoubaoVoiceBridge"
"$output_app/Contents/MacOS/DoubaoVoiceBridge" --self-test
"$output_app/Contents/MacOS/DoubaoVoiceBridge" --diagnostics
