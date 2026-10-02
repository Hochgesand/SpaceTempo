#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app='dist/SpaceTempo.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/SpaceTempoApp" "$app/Contents/MacOS/SpaceTempo"
cp .build/local/space-tempo-cli "$app/Contents/MacOS/space-tempo-cli"
cp .build/local/space-tempo-input-guard "$app/Contents/MacOS/space-tempo-input-guard"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SpaceTempo</string>
<key>CFBundleDisplayName</key><string>SpaceTempo</string>
<key>CFBundleIdentifier</key><string>de.hochgesand.spacetempo</string>
<key>CFBundleExecutable</key><string>SpaceTempo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/space-tempo-cli"
codesign --force --sign - "$app/Contents/MacOS/space-tempo-input-guard"
codesign --force --sign - "$app"
echo "Built $app"
