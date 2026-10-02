#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app='dist/SpaceTempo.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/SpaceTempoApp" "$app/Contents/MacOS/SpaceTempo"
cp .build/local/space-tempo-cli "$app/Contents/MacOS/space-tempo-cli"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SpaceTempo</string>
<key>CFBundleDisplayName</key><string>SpaceTempo</string>
<key>CFBundleIdentifier</key><string>de.hochgesand.spacetempo</string>
<key>CFBundleExecutable</key><string>SpaceTempo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/space-tempo-cli"
codesign --force --sign - "$app"
echo "Built $app"
