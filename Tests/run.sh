#!/bin/bash
set -euo pipefail
tests=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$tests/.." && pwd -P)
scratch=$(mktemp -d -t jianyidao-regression)
trap 'rm -rf -- "$scratch"' EXIT
bundle="$scratch/TestEditor.app/Contents"
mkdir -p "$scratch/results" "$bundle/MacOS" "$bundle/Resources"
ln -s "$root/MediaTools" "$bundle/Resources/MediaTools"
cat > "$bundle/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.qingjian.regression</string>
    <key>CFBundleExecutable</key><string>test-editor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF
swiftc -j 1 -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -suppress-warnings \
    -module-cache-path "$scratch/module-cache" \
    "$root/Sources/Compatibility.swift" "$root/Sources/MediaEngine.swift" \
    "$root/Sources/Editor.swift" "$tests/EditorRegression.swift" -o "$bundle/MacOS/test-editor"
"$bundle/MacOS/test-editor" "$tests/Fixtures" "$scratch/results"
