#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

release_assets() {
  local prefix="$1"
  printf '%s' "
    {\"name\":\"geoip.dat\",\"browser_download_url\":\"https://example.test/${prefix}/geoip.dat\"},
    {\"name\":\"geoip.dat.sha256sum\",\"browser_download_url\":\"https://example.test/${prefix}/geoip.dat.sha256sum\"},
    {\"name\":\"geosite.dat\",\"browser_download_url\":\"https://example.test/${prefix}/geosite.dat\"},
    {\"name\":\"geosite.dat.sha256sum\",\"browser_download_url\":\"https://example.test/${prefix}/geosite.dat.sha256sum\"}
  "
}

cat >"$TEST_ROOT/releases.json" <<JSON
[
  {
    "tag_name":"202608190000",
    "draft":false,
    "prerelease":false,
    "published_at":"2026-08-19T00:00:00Z",
    "assets":[$(release_assets too-new)]
  },
  {
    "tag_name":"202608130000",
    "draft":false,
    "prerelease":false,
    "published_at":"2026-08-13T00:00:00Z",
    "assets":[$(release_assets selected)]
  },
  {
    "tag_name":"202608120000-beta",
    "draft":false,
    "prerelease":true,
    "published_at":"2026-08-12T00:00:00Z",
    "assets":[$(release_assets prerelease)]
  },
  {
    "tag_name":"202608110000",
    "draft":true,
    "prerelease":false,
    "published_at":"2026-08-11T00:00:00Z",
    "assets":[$(release_assets draft)]
  }
]
JSON

NOW_EPOCH="$(date -u -d '2026-08-20T00:00:00Z' +%s)"
SELECTED="$(bash "$ROOT_DIR/scripts/select-geodata-release.sh" \
  "$TEST_ROOT/releases.json" 7 "$NOW_EPOCH")"

# Exactly seven days old is eligible; newer, draft and pre-release entries are not.
[[ "$(jq -r '.tag_name' <<<"$SELECTED")" == "202608130000" ]]
[[ "$(jq -r '
  .assets[] | select(.name == "geoip.dat") | .browser_download_url
' <<<"$SELECTED")" == "https://example.test/selected/geoip.dat" ]]

cat >"$TEST_ROOT/missing-assets.json" <<JSON
[
  {
    "tag_name":"202608130000",
    "draft":false,
    "prerelease":false,
    "published_at":"2026-08-13T00:00:00Z",
    "assets":[
      {"name":"geoip.dat","browser_download_url":"https://example.test/incomplete/geoip.dat"}
    ]
  },
  {
    "tag_name":"202608120000",
    "draft":false,
    "prerelease":false,
    "published_at":"2026-08-12T00:00:00Z",
    "assets":[$(release_assets complete)]
  }
]
JSON

SELECTED="$(bash "$ROOT_DIR/scripts/select-geodata-release.sh" \
  "$TEST_ROOT/missing-assets.json" 7 "$NOW_EPOCH")"
[[ "$(jq -r '.tag_name' <<<"$SELECTED")" == "202608120000" ]]

printf 'not-json\n' >"$TEST_ROOT/invalid.json"
if bash "$ROOT_DIR/scripts/select-geodata-release.sh" \
  "$TEST_ROOT/invalid.json" 7 "$NOW_EPOCH" >/dev/null 2>&1; then
  echo "Invalid release JSON unexpectedly succeeded" >&2
  exit 1
fi

printf '[]\n' >"$TEST_ROOT/no-mature-release.json"
if bash "$ROOT_DIR/scripts/select-geodata-release.sh" \
  "$TEST_ROOT/no-mature-release.json" 7 "$NOW_EPOCH" >/dev/null 2>&1; then
  echo "Missing mature release unexpectedly succeeded" >&2
  exit 1
fi

echo "GeoData release delay policy test passed."
