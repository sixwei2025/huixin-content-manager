#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_OUTPUT="${HUIXIN_APP_OUT:-$ROOT/dist/汇芯内容管家.app}"
OUT="$APP_OUTPUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 "$ROOT/main.swift" -o "$OUT/Contents/MacOS/HuixinContentManager" -framework AppKit -framework SwiftUI
if [ -f "$ROOT/assets/AppIcon.icns" ]; then
  cp "$ROOT/assets/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi
if [ -f "$ROOT/server/creator_bridge.py" ]; then
  cp "$ROOT/server/creator_bridge.py" "$OUT/Contents/Resources/creator_bridge.py"
  chmod +x "$OUT/Contents/Resources/creator_bridge.py"
fi
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIdentifier</key><string>cn.huixin.contentmanager</string>
<key>CFBundleName</key><string>汇芯内容管家</string>
<key>CFBundleDisplayName</key><string>汇芯内容管家</string>
<key>CFBundleExecutable</key><string>HuixinContentManager</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
</dict></plist>
PLIST
SIGNING_IDENTITY="${HUIXIN_SIGNING_IDENTITY:-Apple Development: 961443754@qq.com (H3WZLUYD47)}"
if security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$OUT"
else
  echo "未找到稳定签名身份：$SIGNING_IDENTITY" >&2
  echo "可用 HUIXIN_SIGNING_IDENTITY 指定 Developer ID Application 身份。" >&2
  exit 2
fi
echo "$OUT"
