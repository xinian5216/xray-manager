#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURES="$TEST_ROOT/fixtures"
PACKAGE_ROOT="$TEST_ROOT/package"
MANAGER="$PACKAGE_ROOT/xray-manager"
MOCK_BIN="$TEST_ROOT/mock-bin"
INSTALL_ROOT="$TEST_ROOT/installed"

mkdir -p "$FIXTURES" "$MANAGER/lib" "$MOCK_BIN" "$INSTALL_ROOT"

install -m 755 "$ROOT_DIR/xray-manager.sh" "$MANAGER/xray-manager.sh"
install -m 755 "$ROOT_DIR/lib/xray-manager-core.sh" "$MANAGER/lib/xray-manager-core.sh"
printf '9.9.9\n' >"$MANAGER/VERSION"
(
  cd "$MANAGER"
  sha256sum xray-manager.sh lib/xray-manager-core.sh >SHA256SUMS
)

tar -C "$PACKAGE_ROOT" -czf "$FIXTURES/latest-amd64.tar.gz" xray-manager
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
cp "$XRAY_TEST_FIXTURES/${url##*/}" "$out"
SH
chmod 755 "$MOCK_BIN/curl"

PATH="$MOCK_BIN:$PATH" \
XRAY_TEST_FIXTURES="$FIXTURES" \
XRAY_MANAGER_INSTALL_TOKEN="test-install-token" \
XRAY_MANAGER_CLOUDFLARE_URL="https://worker.example.invalid" \
XRAY_MANAGER_LOCK_DIR="$TEST_ROOT/manager.lock" \
XRAY_MANAGER_INSTALL_PATH="$INSTALL_ROOT/xraym" \
XRAY_MANAGER_CORE_PATH="$INSTALL_ROOT/xray-manager-core.sh" \
bash "$ROOT_DIR/xray-manager.sh" --self-update-cloudflare

cmp "$MANAGER/xray-manager.sh" "$INSTALL_ROOT/xraym"
cmp "$MANAGER/lib/xray-manager-core.sh" "$INSTALL_ROOT/xray-manager-core.sh"
[[ -L "$INSTALL_ROOT/xraym" ]]
[[ -L "$INSTALL_ROOT/current" ]]
[[ -L "$INSTALL_ROOT/xray-manager-core.sh" ]]
[[ -f "$INSTALL_ROOT/current/xray-manager.sh" ]]
[[ -f "$INSTALL_ROOT/current/xray-manager-core.sh" ]]
if grep -Rqs 'test-install-token' "$INSTALL_ROOT"; then
  echo "Cloudflare install token was persisted on disk" >&2
  exit 1
fi
echo "Cloudflare manager update test passed."
