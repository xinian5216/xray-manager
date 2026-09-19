#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

[[ "${EUID:-$(id -u)}" -eq 0 ]] || {
  echo "Run this test as root so the bootstrap dependency path is exercised." >&2
  exit 1
}

MOCK_BIN="$TEST_ROOT/mock-bin"
INSTALL_ROOT="$TEST_ROOT/install"
mkdir -p "$MOCK_BIN" "$INSTALL_ROOT"

cat >"$MOCK_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${XRAY_TEST_HTTP_STATUS:-200}" != "200" ]]; then
  printf '%s' "$XRAY_TEST_HTTP_STATUS"
  exit 22
fi

url=""
out=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|-x|--connect-timeout|--max-time|--retry|-w) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

case "$url" in
  */contents/VERSION\?*) source_file="VERSION" ;;
  */contents/SHA256SUMS\?*) source_file="SHA256SUMS" ;;
  */contents/xray-manager.sh\?*) source_file="xray-manager.sh" ;;
  */contents/lib/xray-manager-core.sh\?*) source_file="lib/xray-manager-core.sh" ;;
  *) echo "Unexpected URL: $url" >&2; exit 2 ;;
esac

cp "$XRAY_TEST_ROOT_DIR/$source_file" "$out"
printf '200'
SH

cat >"$MOCK_BIN/apt-get" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$XRAY_TEST_APT_LOG"
SH

chmod 755 "$MOCK_BIN/curl" "$MOCK_BIN/apt-get"
export XRAY_TEST_ROOT_DIR="$ROOT_DIR"
export XRAY_TEST_APT_LOG="$TEST_ROOT/apt.log"

# Simulate a machine upgraded from the removed Cloudflare/R2 channel: the
# installer must ignore and clean up the retired state files.
mkdir -p "$INSTALL_ROOT/state"
printf 'cloudflare\n' >"$INSTALL_ROOT/state/manager_update_source"
printf 'https://worker.example.invalid\n' >"$INSTALL_ROOT/state/cloudflare_url"

PATH="$MOCK_BIN:$PATH" \
XRAY_MANAGER_GITHUB_TOKEN="test-token" \
XRAY_MANAGER_STATE_DIR="$INSTALL_ROOT/state" \
XRAY_MANAGER_INSTALL_PATH="$INSTALL_ROOT/xraym" \
XRAY_MANAGER_CORE_PATH="$INSTALL_ROOT/lib/xray-manager-core.sh" \
  bash "$ROOT_DIR/install.sh"

cmp "$ROOT_DIR/xray-manager.sh" "$INSTALL_ROOT/xraym"
cmp "$ROOT_DIR/lib/xray-manager-core.sh" "$INSTALL_ROOT/lib/xray-manager-core.sh"
grep -Fxq 'update' "$XRAY_TEST_APT_LOG"
grep -Eq '^install -y .*jq .*openssl .*unzip .*iproute2' "$XRAY_TEST_APT_LOG"
[[ ! -e "$INSTALL_ROOT/state/manager_update_source" ]] ||
  { echo "Retired manager_update_source was not cleaned up." >&2; exit 1; }
[[ ! -e "$INSTALL_ROOT/state/cloudflare_url" ]] ||
  { echo "Retired cloudflare_url was not cleaned up." >&2; exit 1; }

# Public-repository default: a fully anonymous install (no token env at all)
# must succeed against the same unauthenticated GitHub API endpoints.
ANON_ROOT="$TEST_ROOT/anon-install"
env -u XRAY_MANAGER_GITHUB_TOKEN -u GH_TOKEN \
  PATH="$MOCK_BIN:$PATH" \
  XRAY_MANAGER_STATE_DIR="$ANON_ROOT/state" \
  XRAY_MANAGER_INSTALL_PATH="$ANON_ROOT/xraym" \
  XRAY_MANAGER_CORE_PATH="$ANON_ROOT/lib/xray-manager-core.sh" \
    bash "$ROOT_DIR/install.sh" >"$TEST_ROOT/anon.log" 2>&1
cmp "$ROOT_DIR/xray-manager.sh" "$ANON_ROOT/xraym"
cmp "$ROOT_DIR/lib/xray-manager-core.sh" "$ANON_ROOT/lib/xray-manager-core.sh"
grep -Fq '匿名读取公开仓库' "$TEST_ROOT/anon.log"

set +e
failure_output="$(
  PATH="$MOCK_BIN:$PATH" \
  XRAY_TEST_HTTP_STATUS=404 \
  XRAY_MANAGER_GITHUB_TOKEN="test-token" \
  XRAY_MANAGER_INSTALL_PATH="$INSTALL_ROOT/unused-xraym" \
  XRAY_MANAGER_CORE_PATH="$INSTALL_ROOT/unused-core.sh" \
    bash "$ROOT_DIR/install.sh" 2>&1
)"
failure_rc=$?
set -e

[[ "$failure_rc" -eq 22 ]]
grep -Fq 'HTTP 404' <<<"$failure_output"
grep -Fq '私有 fork' <<<"$failure_output"

echo "Bootstrap dependency and GitHub error tests passed."
