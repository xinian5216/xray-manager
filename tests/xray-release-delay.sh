#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat >"$TEST_ROOT/releases.json" <<'JSON'
[
  {"tag_name":"v26.8.19","draft":false,"prerelease":false,"published_at":"2026-08-19T00:00:00Z"},
  {"tag_name":"v26.8.18-beta","draft":false,"prerelease":true,"published_at":"2026-07-01T00:00:00Z"},
  {"tag_name":"v26.8.6","draft":false,"prerelease":false,"published_at":"2026-08-06T00:00:00Z"},
  {"tag_name":"v26.7.30","draft":false,"prerelease":false,"published_at":"2026-07-30T00:00:00Z"},
  {"tag_name":"v99.1.1","draft":true,"prerelease":false,"published_at":"2026-07-01T00:00:00Z"}
]
JSON

NOW_EPOCH="$(date -u -d '2026-08-20T00:00:00Z' +%s)"
SELECTED="$(bash "$ROOT_DIR/scripts/select-xray-release.sh" \
  "$TEST_ROOT/releases.json" v26.3.27 14 "$NOW_EPOCH")"

# Exactly 14 days old is eligible; newer, pre-release and draft entries are not.
[[ "$SELECTED" == "v26.8.6" ]]

printf 'not-json\n' >"$TEST_ROOT/invalid.json"
FALLBACK="$(bash "$ROOT_DIR/scripts/select-xray-release.sh" \
  "$TEST_ROOT/invalid.json" v26.3.27 14 "$NOW_EPOCH")"
[[ "$FALLBACK" == "v26.3.27" ]]

echo "Xray release delay policy test passed."
