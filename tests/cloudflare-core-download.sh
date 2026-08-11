#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"

FIXTURES="$TEST_ROOT/fixtures"
PACKAGE_ROOT="$TEST_ROOT/package"
MOCK_BIN="$TEST_ROOT/mock-bin"
RESULT="$TEST_ROOT/result"
mkdir -p "$FIXTURES" "$PACKAGE_ROOT/payload" "$MOCK_BIN" "$RESULT"

dd if=/dev/zero of="$PACKAGE_ROOT/payload/Xray-linux-64.zip" bs=1024 count=2 status=none
dd if=/dev/zero of="$PACKAGE_ROOT/payload/geoip.dat" bs=1024 count=2 status=none
dd if=/dev/zero of="$PACKAGE_ROOT/payload/geosite.dat" bs=1024 count=2 status=none
tar -C "$PACKAGE_ROOT" -czf "$FIXTURES/latest-amd64.tar.gz" payload
sha256sum "$FIXTURES/latest-amd64.tar.gz" |
  awk '{print $1}' >"$FIXTURES/latest-amd64.sha256"

cat >"$MOCK_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url=""
out=""
while (($#)); do
  case "$1" in
    --config) shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$url" && -n "$out" ]]
printf '%s\n' "$url" >>"$XRAY_TEST_CURL_LOG"
cp "$XRAY_TEST_FIXTURES/${url##*/}" "$out"
SH
chmod 755 "$MOCK_BIN/curl"

offline_import_xray() {
  cp "$1" "$RESULT/xray.zip"
  cp "$2" "$RESULT/geoip.dat"
  cp "$3" "$RESULT/geosite.dat"
}

UPDATE_SOURCE="cloudflare"
CLOUDFLARE_BASE="https://worker.example.invalid"
XRAY_MANAGER_INSTALL_TOKEN="test-install-token"
export XRAY_TEST_FIXTURES="$FIXTURES"
export XRAY_TEST_CURL_LOG="$TEST_ROOT/curl.log"
PATH="$MOCK_BIN:$PATH"

# The Core already defines this function; the test replaces it later only for
# a separate dispatch assertion.
# shellcheck disable=SC2218
cloudflare_install_or_update_xray
cmp "$PACKAGE_ROOT/payload/Xray-linux-64.zip" "$RESULT/xray.zip"
cmp "$PACKAGE_ROOT/payload/geoip.dat" "$RESULT/geoip.dat"
cmp "$PACKAGE_ROOT/payload/geosite.dat" "$RESULT/geosite.dat"
[[ "$(wc -l <"$XRAY_TEST_CURL_LOG")" -eq 2 ]]
! grep -Eq 'github\.com|githubusercontent\.com|xtls' "$XRAY_TEST_CURL_LOG"
grep -Fxq "https://worker.example.invalid/releases/latest-amd64.tar.gz" "$XRAY_TEST_CURL_LOG"
grep -Fxq "https://worker.example.invalid/releases/latest-amd64.sha256" "$XRAY_TEST_CURL_LOG"

ensure_layout() { return 0; }
load_network_state() { return 0; }
prepare_download_network() { echo "official network path used" >&2; return 99; }
pkg_install_base() { echo "package manager path used" >&2; return 98; }
need_xray() { return 0; }
cloudflare_install_calls=0
cloudflare_geodata_calls=0
cloudflare_install_or_update_xray() { ((cloudflare_install_calls += 1)); }
cloudflare_update_geodata() { ((cloudflare_geodata_calls += 1)); }

install_or_repair_xray
update_xray
update_geodata
[[ "$cloudflare_install_calls" -eq 2 ]]
[[ "$cloudflare_geodata_calls" -eq 1 ]]

echo "Cloudflare Core download test passed."
