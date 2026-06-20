#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sources.env
source "$ROOT/scripts/sources.env"
APP_NAME="Companion"
APP="$ROOT/$APP_NAME.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
PACKAGE_DMG=1
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
MCP_SMOKE_EXECUTABLE="$ROOT/build/smoke/CompanionMCP-smoke"

for arg in "$@"; do
  case "$arg" in
    --skip-dmg)
      PACKAGE_DMG=0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$PACKAGE_DMG" == "1" && "${COMPANION_AUTO_BUMP_BUILD:-${COMPANION_AUTO_BUMP_BUILD:-1}}" != "0" ]]; then
  APP_BUILD="$(bash "$ROOT/scripts/bump-build.sh")"
  export APP_BUILD
  export COMPANION_AUTO_BUMP_BUILD=0
fi

# shellcheck source=version.env
source "$ROOT/scripts/version.env"

fail() {
  echo "smoke-release: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

require_dir() {
  [[ -d "$1" ]] || fail "missing directory: $1"
}

check_sensitive_paths() {
  local root="$1"
  local match
  match="$(find "$root" \( \
    -name ".companion" -o \
    -name ".env" -o \
    -name ".env.*" -o \
    -name "auth.json" -o \
    -name "profiles.json" -o \
    -name "config.toml" -o \
    -name "reminders.json" -o \
    -name "pomodoro.json" -o \
    -name "journal-documents.json" -o \
    -name "*.key" -o \
    -name "*.pem" -o \
    -name "*.p12" -o \
    -name "*.mobileprovision" \
  \) -print -quit)"

  [[ -z "$match" ]] || fail "sensitive path found under $root: $match"
}

check_sensitive_xattrs() {
  local root="$1"
  local match
  match="$(xattr -lr "$root" 2>/dev/null | grep -E "com\\.apple\\.(lastuseddate|macl|metadata:kMDItemWhereFroms|quarantine)" | head -n 1 || true)"
  [[ -z "$match" ]] || fail "sensitive xattr found under $root: $match"
}

build_mcp_smoke_helper() {
  local sources=()
  local source
  for source in "${COMPANION_MCP_SOURCES[@]}"; do
    sources+=("$ROOT/$source")
  done

  mkdir -p "$(dirname "$MCP_SMOKE_EXECUTABLE")"
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
    "${sources[@]}" \
    -o "$MCP_SMOKE_EXECUTABLE"
}

mcp_probe_executable() {
  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    build_mcp_smoke_helper
    printf '%s\n' "$MCP_SMOKE_EXECUTABLE"
    return
  fi

  printf '%s\n' "$CONTENTS/MacOS/CompanionMCP"
}

check_app_bundle() {
  require_file "$CONTENTS/Info.plist"
  require_file "$CONTENTS/MacOS/$APP_NAME"
  require_file "$CONTENTS/MacOS/CompanionMCP"
  require_file "$RESOURCES/AppIcon.icns"
  require_file "$RESOURCES/CompanionMenuBarIcon.png"
  require_file "$RESOURCES/Skins/小花儿/pet.json"
  require_file "$RESOURCES/Skins/小花儿/spritesheet.png"
  require_file "$RESOURCES/Sounds/XiaoHuaEr/voice-manifest.json"
  require_dir "$RESOURCES/Sounds/Pomodoro"

  local plist_version plist_build
  plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")"
  plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONTENTS/Info.plist")"
  [[ "$plist_version" == "$APP_VERSION" ]] || fail "version mismatch: expected $APP_VERSION, got $plist_version"
  [[ "$plist_build" == "$APP_BUILD" ]] || fail "build mismatch: expected $APP_BUILD, got $plist_build"

  /usr/bin/python3 - "$CONTENTS/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as f:
    info = plistlib.load(f)

services = info.get("NSServices") or []
target = None
for service in services:
    if service.get("NSMessage") == "uploadFilesWithCompanion":
        target = service
        break

if not target:
    raise SystemExit("missing Finder upload NSServices entry")

menu = target.get("NSMenuItem") or {}
if menu.get("default") != "上传到 Companion":
    raise SystemExit("Finder upload service default title must be 上传到 Companion")
if menu.get("en") != "Upload to Companion":
    raise SystemExit("Finder upload service English title must be Upload to Companion")

required_context = target.get("NSRequiredContext") or {}
if required_context.get("NSApplicationIdentifier") != "com.apple.finder":
    raise SystemExit("Finder upload service must be scoped to Finder")

send_types = set(target.get("NSSendTypes") or [])
required_send_types = {"NSFilenamesPboardType", "NSURLPboardType", "public.file-url"}
missing_send_types = required_send_types - send_types
if missing_send_types:
    raise SystemExit("Finder upload service missing send types: " + ", ".join(sorted(missing_send_types)))

file_types = set(target.get("NSSendFileTypes") or [])
if "public.item" not in file_types:
    raise SystemExit("Finder upload service must accept public.item files")
PY

  /usr/bin/codesign --verify --deep --strict "$APP"
  check_sensitive_paths "$APP"
  check_sensitive_xattrs "$APP"

  /usr/bin/python3 - "$RESOURCES/Sounds/XiaoHuaEr" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = root / "voice-manifest.json"
data = json.loads(manifest.read_text())
if not isinstance(data, dict) or not data:
    raise SystemExit("voice manifest must be a non-empty object")

missing = []
for event, files in data.items():
    if not isinstance(event, str) or not isinstance(files, list) or not files:
        raise SystemExit(f"invalid voice manifest entry: {event!r}")
    for filename in files:
        if not isinstance(filename, str):
            raise SystemExit(f"invalid voice filename for {event!r}: {filename!r}")
        if not (root / filename).is_file():
            missing.append(filename)

if missing:
    raise SystemExit("voice manifest references missing files: " + ", ".join(sorted(set(missing))))
PY
}

check_mcp_protocol() {
  local mcp_probe
  mcp_probe="$(mcp_probe_executable)"
  "$mcp_probe" --self-test >/dev/null
  local mcp_initialize
  mcp_initialize="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | "$mcp_probe")"
  [[ "$mcp_initialize" == *'"serverInfo"'* ]] || fail "CompanionMCP stdio initialize failed"
  [[ "$mcp_initialize" != Content-Length:* ]] || fail "CompanionMCP stdio must use newline-delimited JSON-RPC"
}

check_dmg() {
  local dmg="$ROOT/dist/$APP_NAME-$APP_VERSION-macos-$APP_ARCH.dmg"
  local checksum="$dmg.sha256"
  require_file "$dmg"
  require_file "$checksum"
  (
    cd "$(dirname "$dmg")"
    /usr/bin/shasum -a 256 -c "$(basename "$checksum")" >/dev/null
  )
  check_sensitive_xattrs "$dmg"
  /usr/bin/hdiutil imageinfo "$dmg" >/dev/null
}

"$ROOT/scripts/run-tests.sh"

APP_VERSION="$APP_VERSION" \
APP_BUILD="$APP_BUILD" \
CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
bash "$ROOT/scripts/build-menu-bar-app.sh"

check_app_bundle

if [[ "$PACKAGE_DMG" == "1" ]]; then
  APP_VERSION="$APP_VERSION" APP_BUILD="$APP_BUILD" APP_ARCH="$APP_ARCH" COMPANION_AUTO_BUMP_BUILD=0 bash "$ROOT/scripts/package-dmg.sh"
  check_dmg
fi

check_mcp_protocol

echo "smoke-release: OK"
