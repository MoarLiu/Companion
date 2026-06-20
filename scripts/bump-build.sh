#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${1:-$ROOT/scripts/version.env}"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing version file: $VERSION_FILE" >&2
  exit 1
fi

current="$(
  sed -nE 's/^: "\$\{APP_BUILD:=([0-9]+)\}"$/\1/p' "$VERSION_FILE" | head -n 1
)"

if [[ ! "$current" =~ ^[0-9]+$ ]]; then
  echo "Could not parse APP_BUILD from $VERSION_FILE" >&2
  exit 1
fi

next=$((current + 1))
tmp="$(mktemp "${VERSION_FILE}.XXXXXX")"
mode="$(stat -f '%Lp' "$VERSION_FILE")"

awk -v next_build="$next" '
  /^: "\$\{APP_BUILD:=[0-9]+\}"$/ {
    print ": \"${APP_BUILD:=" next_build "}\""
    changed = 1
    next
  }
  { print }
  END {
    if (!changed) {
      exit 3
    }
  }
' "$VERSION_FILE" >"$tmp" || {
  rm -f "$tmp"
  echo "Failed to update APP_BUILD in $VERSION_FILE" >&2
  exit 1
}

chmod "$mode" "$tmp"
mv "$tmp" "$VERSION_FILE"
printf '%s\n' "$next"
