#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT_DIR/scripts/verify-xray-asset.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

payload="$TEST_ROOT/Xray-linux-64.zip"
printf 'xray-asset-integrity-payload\n' >"$payload"
actual="$(sha256sum "$payload" | awk '{print $1}')"

write_json() {
  local digest="${1:-}" extra="${2:-}"
  python3 - "$TEST_ROOT/releases.json" "$digest" "$extra" <<'PY'
import json, sys
path, digest, extra = sys.argv[1:]
asset = {
    "name": "Xray-linux-64.zip",
    "browser_download_url": "https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip",
}
if digest:
    asset["digest"] = digest
assets = [asset]
if extra == "duplicate":
    assets.append(dict(asset))
doc = [{
    "tag_name": "v26.3.27",
    "draft": False,
    "prerelease": False,
    "assets": assets,
}]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
PY
}

expect_fail() {
  local message="$1"
  shift
  if bash "$VERIFY" "$@" >/dev/null 2>"$TEST_ROOT/err"; then
    echo "$message unexpectedly succeeded" >&2
    exit 1
  fi
}

write_json "sha256:$actual"
[[ "$(bash "$VERIFY" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --print-sha256)" == "$actual" ]]
[[ "$(bash "$VERIFY" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload")" == "$actual" ]]

cat >"$TEST_ROOT/good.dgst" <<EOF
MD5= deadbeef
SHA2-256= $actual
SHA2-512= 00
EOF
write_json ""
[[ "$(bash "$VERIFY" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload" --dgst "$TEST_ROOT/good.dgst")" == "$actual" ]]

write_json "sha256:$actual"
printf 'wrong-bytes\n' >"$TEST_ROOT/bad.zip"
expect_fail "mismatched file" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$TEST_ROOT/bad.zip"

write_json ""
[[ "$(bash "$VERIFY" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --print-url)" == "https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip" ]]
expect_fail "missing digest" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload"
expect_fail "missing digest for print-sha256" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --print-sha256

write_json "sha256:not-a-digest"
expect_fail "malformed digest" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload"

write_json "sha256:$actual" duplicate
expect_fail "duplicate asset" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload"

cat >"$TEST_ROOT/conflict.dgst" <<EOF
SHA2-256= $actual
SHA2-256= 0000000000000000000000000000000000000000000000000000000000000000
EOF
write_json ""
expect_fail "conflicting dgst" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload" --dgst "$TEST_ROOT/conflict.dgst"

cat >"$TEST_ROOT/releases.json" <<JSON
[
  {
    "tag_name": "v26.3.27",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "Xray-linux-64.zip",
        "browser_download_url": "https://evil.example/Xray-linux-64.zip",
        "digest": "sha256:$actual"
      }
    ]
  }
]
JSON
expect_fail "unexpected domain" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload"

cat >"$TEST_ROOT/releases.json" <<JSON
[
  {
    "tag_name": "v26.3.27",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "Xray-linux-64.zip",
        "browser_download_url": "https://github.com/XTLS/Xray-core/releases/download/v99.0.0/Xray-linux-64.zip",
        "digest": "sha256:$actual"
      }
    ]
  }
]
JSON
expect_fail "wrong tag in URL" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload"

expect_fail "wrong architecture" --json "$TEST_ROOT/releases.json" --tag v26.3.27 --name Xray-linux-arm64-v8a.zip --file "$payload"

printf '[]\n' >"$TEST_ROOT/empty.json"
expect_fail "API unavailable / empty list" --json "$TEST_ROOT/empty.json" --tag v26.3.27 --name Xray-linux-64.zip --file "$payload"

echo "Xray asset integrity tests passed."
