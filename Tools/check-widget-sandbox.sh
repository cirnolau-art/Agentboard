#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
PROBE="$PROJECT_DIR/build/SandboxProbe.app"
mkdir -p "$PROBE/Contents/MacOS"
swiftc -parse-as-library "$PROJECT_DIR/Shared/Models.swift" "$PROJECT_DIR/Shared/FeatureModels.swift" "$PROJECT_DIR/Shared/Theme.swift" "$PROJECT_DIR/Shared/SharedStorage.swift" "$PROJECT_DIR/Tools/SandboxProbe.swift" -o "$PROBE/Contents/MacOS/SandboxProbe"
cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.agentboard.sandboxprobe</string>
<key>CFBundleExecutable</key><string>SandboxProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - --requirements '=designated => identifier "local.agentboard.sandboxprobe"' --entitlements "$PROJECT_DIR/Config/Widget.entitlements" "$PROBE"
"$PROBE/Contents/MacOS/SandboxProbe"
