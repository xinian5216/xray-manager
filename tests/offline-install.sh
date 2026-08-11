#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"

XRAY_BIN="$TEST_ROOT/bin/xray"
XRAY_ROOT="$TEST_ROOT/etc/xray"
CONF_DIR="$XRAY_ROOT/conf.d"
CERT_DIR="$XRAY_ROOT/certs"
ASSET_DIR="$TEST_ROOT/share/xray"
LOG_DIR="$TEST_ROOT/log"
STATE_DIR="$TEST_ROOT/state"
BACKUP_DIR="$STATE_DIR/backups"
BASE_FILE="$CONF_DIR/00_base.json"
DOWNLOAD_PROXY_FILE="$STATE_DIR/download_proxy"
DNS64_STATE_FILE="$STATE_DIR/dns64.state"
INIT_SYS="test"
XRAY_RUN_GROUP="$(id -gn)"

detect_platform() { INIT_SYS="test"; XRAY_RUN_GROUP="$(id -gn)"; }
configure_offline_service() { return 0; }
service_stop() { return 0; }
service_restart() { return 0; }
curl() { echo "network access attempted" >&2; return 99; }
wget() { echo "network access attempted" >&2; return 99; }

mkdir -p "$TEST_ROOT/package" "$TEST_ROOT/bundle"
cat >"$TEST_ROOT/package/xray" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version|-version) echo "Xray offline-test" ;;
  run) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod 755 "$TEST_ROOT/package/xray"
for i in {1..1500}; do
  printf '# offline test padding %04d abcdefghijklmnopqrstuvwxyz\n' "$i" >>"$TEST_ROOT/package/xray"
done

python3 - "$TEST_ROOT/package/xray" "$TEST_ROOT/bundle/Xray-linux-64.zip" <<'PY'
import sys
import zipfile
source, target = sys.argv[1:]
with zipfile.ZipFile(target, "w") as package:
    package.write(source, "xray")
PY

dd if=/dev/zero of="$TEST_ROOT/bundle/geoip.dat" bs=1024 count=2 status=none
dd if=/dev/zero of="$TEST_ROOT/bundle/geosite.dat" bs=1024 count=2 status=none

offline_import_xray \
  "$TEST_ROOT/bundle/Xray-linux-64.zip" \
  "$TEST_ROOT/bundle/geoip.dat" \
  "$TEST_ROOT/bundle/geosite.dat"

[[ -x "$XRAY_BIN" ]]
cmp "$TEST_ROOT/package/xray" "$XRAY_BIN"
cmp "$TEST_ROOT/bundle/geoip.dat" "$ASSET_DIR/geoip.dat"
cmp "$TEST_ROOT/bundle/geosite.dat" "$ASSET_DIR/geosite.dat"
echo "Offline import test passed."
