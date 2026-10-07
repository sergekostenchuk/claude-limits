#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
scratch="${CLAUDE_LIMITS_BUILD_DIR:-/tmp/claude-limits-swift-build}"
swift build --disable-sandbox --scratch-path "$scratch" -c release
bin_dir=$(swift build --disable-sandbox --scratch-path "$scratch" -c release --show-bin-path)
bundle="$PWD/dist/Claude Limits.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/ClaudeLimits" "$bundle/Contents/MacOS/ClaudeLimits"
cp Login.command "$bundle/Contents/Resources/Login.command"
cp Resources/ClaudeIcon.png "$bundle/Contents/Resources/ClaudeIcon.png"
chmod 755 "$bundle/Contents/Resources/Login.command"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClaudeLimits</string>
<key>CFBundleIdentifier</key><string>com.kostenchuksergey.ClaudeLimits</string>
<key>CFBundleName</key><string>Claude Limits</string>
<key>CFBundleDisplayName</key><string>Claude Limits</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>ru</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier com.kostenchuksergey.ClaudeLimits "$bundle"
printf 'Built: %s\n' "$bundle"
