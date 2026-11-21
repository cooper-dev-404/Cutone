#!/bin/bash
set -eu
src=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$src/build"}
media=${2:-"$src/MediaTools"}
mkdir -p "$out"
app="$out/剪一刀.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/MediaTools"
mkdir -p "$out/module-cache"
cache=$(cd "$out/module-cache" && pwd -P)
swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -O -suppress-warnings \
    -module-cache-path "$cache" "$src"/Sources/*.swift -o "$app/Contents/MacOS/JianYiDao"
cp "$src/Info.plist" "$app/Contents/Info.plist"
cp "$src/Assets/AppIcon.icns" "$resources/"
for binary in ffmpeg ffprobe; do
    cp "$media/$binary" "$resources/MediaTools/$binary"
    codesign --force --sign - "$resources/MediaTools/$binary"
done
cp "$src/Assets/"*.txt "$resources/"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
