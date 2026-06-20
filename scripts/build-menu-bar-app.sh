#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${COMPANION_AUTO_BUMP_BUILD:-1}" != "0" && -z "${APP_BUILD:-}" ]]; then
  APP_BUILD="$(bash "$ROOT/scripts/bump-build.sh")"
  export APP_BUILD
fi

# shellcheck source=version.env
source "$ROOT/scripts/version.env"
# shellcheck source=sources.env
source "$ROOT/scripts/sources.env"
APP="$ROOT/Companion.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
EXECUTABLE="$MACOS/Companion"
MCP_EXECUTABLE="$MACOS/CompanionMCP"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Companion Local Development Code Signing}"
COMPANION_GITHUB_REPOSITORY="${COMPANION_GITHUB_REPOSITORY:-crazyjal/Companion}"

COMPANION_APP_ABS_SOURCES=()
for source in "${COMPANION_APP_SOURCES[@]}"; do
  COMPANION_APP_ABS_SOURCES+=("$ROOT/$source")
done

COMPANION_MCP_ABS_SOURCES=()
for source in "${COMPANION_MCP_SOURCES[@]}"; do
  COMPANION_MCP_ABS_SOURCES+=("$ROOT/$source")
done

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

MACOSX_DEPLOYMENT_TARGET=12.0 /usr/bin/swiftc \
  -O \
  -framework ApplicationServices \
  -framework AppKit \
  -framework AVFoundation \
  -framework Combine \
  -framework CryptoKit \
  -framework Foundation \
  -framework ImageIO \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "${COMPANION_APP_ABS_SOURCES[@]}" \
  -o "$EXECUTABLE"

chmod 755 "$EXECUTABLE"

MACOSX_DEPLOYMENT_TARGET=12.0 /usr/bin/swiftc \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Combine \
  -framework CryptoKit \
  -framework Foundation \
  -framework ImageIO \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "${COMPANION_MCP_ABS_SOURCES[@]}" \
  -o "$MCP_EXECUTABLE"

chmod 755 "$MCP_EXECUTABLE"

if [[ -f "$ROOT/assets/companion-icon.icns" ]]; then
  /usr/bin/ditto --noextattr --noacl "$ROOT/assets/companion-icon.icns" "$RESOURCES/AppIcon.icns"
fi

if [[ -f "$ROOT/assets/companion-menubar-template.png" ]]; then
  /usr/bin/ditto --noextattr --noacl "$ROOT/assets/companion-menubar-template.png" "$RESOURCES/CompanionMenuBarIcon.png"
fi

if [[ -d "$ROOT/assets/Skins" ]]; then
  /usr/bin/ditto --noextattr --noacl "$ROOT/assets/Skins" "$RESOURCES/Skins"
fi

if [[ -d "$ROOT/assets/Sounds" ]]; then
  /usr/bin/ditto --noextattr --noacl "$ROOT/assets/Sounds" "$RESOURCES/Sounds"
fi

if [[ -d "$ROOT/assets/Localization" ]]; then
  while IFS= read -r -d '' lproj; do
    /usr/bin/ditto --noextattr --noacl "$lproj" "$RESOURCES/$(basename "$lproj")"
  done < <(find "$ROOT/assets/Localization" -maxdepth 1 -name "*.lproj" -type d -print0)
fi

find "$RESOURCES" -name ".DS_Store" -delete

cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Companion</string>
  <key>CFBundleExecutable</key>
  <string>Companion</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.crazyjal.companion</string>
  <key>CFBundleName</key>
  <string>Companion</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CompanionGitHubRepository</key>
  <string>$COMPANION_GITHUB_REPOSITORY</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Companion uses Apple Events to read the current browser selection for AI actions when Chrome is frontmost.</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>上传到 Companion</string>
        <key>English</key>
        <string>Upload to Companion</string>
        <key>en</key>
        <string>Upload to Companion</string>
        <key>zh</key>
        <string>上传到 Companion</string>
        <key>zh-Hans</key>
        <string>上传到 Companion</string>
        <key>zh_CN</key>
        <string>上传到 Companion</string>
      </dict>
      <key>NSMessage</key>
      <string>uploadFilesWithCompanion</string>
      <key>NSPortName</key>
      <string>Companion</string>
      <key>NSRequiredContext</key>
      <dict>
        <key>NSApplicationIdentifier</key>
        <string>com.apple.finder</string>
      </dict>
      <key>NSSendFileTypes</key>
      <array>
        <string>public.item</string>
      </array>
      <key>NSSendTypes</key>
      <array>
        <string>NSFilenamesPboardType</string>
        <string>NSURLPboardType</string>
        <string>public.file-url</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$CONTENTS/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  if [[ "$CODE_SIGN_IDENTITY" != "-" ]] &&
     ! /usr/bin/security find-identity -v -p codesigning | grep -F "\"$CODE_SIGN_IDENTITY\"" >/dev/null; then
    echo "Missing code signing identity: $CODE_SIGN_IDENTITY" >&2
    echo "Run ./scripts/setup-local-code-signing.sh, or set CODE_SIGN_IDENTITY=- for ad-hoc signing." >&2
    exit 1
  fi

  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --deep --timestamp=none --sign "$CODE_SIGN_IDENTITY" "$APP" >/dev/null
  else
    /usr/bin/codesign --force --deep --timestamp --options runtime --sign "$CODE_SIGN_IDENTITY" "$APP" >/dev/null
  fi
fi

echo "Built: $APP"
