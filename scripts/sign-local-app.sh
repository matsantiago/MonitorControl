#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s /path/to/MonitorControl.app\n' "$0" >&2
  exit 1
fi

app="$1"
helper="$app/Contents/Library/LoginItems/MonitorControlHelper.app"
identity_file="$HOME/Library/Application Support/MonitorControl/Signing/identity.txt"
if [[ ! -r "$identity_file" ]]; then
  printf 'Run scripts/setup-macos-signing.py to configure local signing.\n' >&2
  exit 1
fi
identity=$(<"$identity_file")
if [[ ! "$identity" =~ ^[0-9A-F]{40}$ ]] ||
   ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$identity" >/dev/null; then
  printf 'The configured signing identity is unavailable in Keychain.\n' >&2
  exit 1
fi

identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
if [[ "$identifier" != app.monitorcontrol.MonitorControl || ! -d "$helper" ]]; then
  printf 'Expected a built MonitorControl app with its login helper.\n' >&2
  exit 1
fi

entitlements=$(mktemp)
trap 'rm -f "$entitlements"' EXIT
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
PLIST

# Keep Sparkle's original signatures. Sign the app's own helper first.
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none "$helper"
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none \
  --entitlements "$entitlements" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
