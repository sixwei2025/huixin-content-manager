#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_OUTPUT="${HUIXIN_APP_OUT:-$ROOT/dist/汇芯内容创业管家.app}"
OUT="$APP_OUTPUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT/main.swift" -o "$OUT/Contents/MacOS/HuixinContentManager" -framework AppKit -framework SwiftUI
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIdentifier</key><string>cn.huixin.contentmanager</string>
<key>CFBundleName</key><string>汇芯 内容创业管家</string>
<key>CFBundleDisplayName</key><string>汇芯 内容创业管家</string>
<key>CFBundleExecutable</key><string>HuixinContentManager</string>
<key>CFBundleShortVersionString</key><string>0.1.12</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$OUT"
echo "$OUT"

