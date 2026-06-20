#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sources.env
source "$ROOT/scripts/sources.env"
BUILD_DIR="$ROOT/build/tests"
EXECUTABLE="$BUILD_DIR/companion-core-tests"

COMPANION_TEST_ABS_SOURCES=()
for source in "${COMPANION_TEST_SUPPORT_SOURCES[@]}"; do
  COMPANION_TEST_ABS_SOURCES+=("$ROOT/$source")
done

validate_source_lists() {
  local expected_app_sources=()
  local source
  while IFS= read -r -d '' source; do
    expected_app_sources+=("${source#$ROOT/}")
  done < <(find "$ROOT/macos-menu-bar" -maxdepth 1 -name "*.swift" ! -name "CompanionMCP.swift" -print0 | sort -z)

  local declared_app_sources
  local expected_app_joined
  declared_app_sources="$(printf '%s\n' "${COMPANION_APP_SOURCES[@]}" | sort)"
  expected_app_joined="$(printf '%s\n' "${expected_app_sources[@]}" | sort)"
  if [[ "$declared_app_sources" != "$expected_app_joined" ]]; then
    echo "COMPANION_APP_SOURCES is out of sync with macos-menu-bar/*.swift" >&2
    diff -u <(printf '%s\n' "$expected_app_joined") <(printf '%s\n' "$declared_app_sources") >&2 || true
    exit 1
  fi

  local declared_test_sources
  declared_test_sources="$(printf '%s\n' "${COMPANION_TEST_SUPPORT_SOURCES[@]}" | sort)"
  if [[ "$declared_test_sources" != "$declared_app_sources" ]]; then
    echo "COMPANION_TEST_SUPPORT_SOURCES must mirror COMPANION_APP_SOURCES so Companion.swift stays test-compiled." >&2
    diff -u <(printf '%s\n' "$declared_app_sources") <(printf '%s\n' "$declared_test_sources") >&2 || true
    exit 1
  fi

  for source in "${COMPANION_APP_SOURCES[@]}" "${COMPANION_MCP_SOURCES[@]}" "${COMPANION_TEST_SUPPORT_SOURCES[@]}"; do
    if [[ ! -f "$ROOT/$source" ]]; then
      echo "Source list references a missing file: $source" >&2
      exit 1
    fi
  done
}

mkdir -p "$BUILD_DIR"
validate_source_lists

MACOSX_DEPLOYMENT_TARGET=12.0 /usr/bin/swiftc \
  -D COMPANION_TESTING \
  -parse-as-library \
  -framework AppKit \
  -framework AVFoundation \
  -framework Combine \
  -framework CryptoKit \
  -framework Foundation \
  -framework ImageIO \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "${COMPANION_TEST_ABS_SOURCES[@]}" \
  "$ROOT/Tests/CompanionCoreTests.swift" \
  -o "$EXECUTABLE"

"$EXECUTABLE"
