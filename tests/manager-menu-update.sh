#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"

XRAY_MANAGER_LAUNCHER_PATH="$TEST_ROOT/xraym"
XRAY_TEST_UPDATE_LOG="$TEST_ROOT/update.log"
export XRAY_TEST_UPDATE_LOG

cat >"$XRAY_MANAGER_LAUNCHER_PATH" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$XRAY_TEST_UPDATE_LOG"
SH
chmod 755 "$XRAY_MANAGER_LAUNCHER_PATH"

# Decline only the optional post-update reload so the test process continues.
confirm() { return 1; }
update_manager_script

grep -Fxq -- '--self-update' "$XRAY_TEST_UPDATE_LOG"
grep -Fq 'echo "4) 编辑入站"' "$ROOT_DIR/lib/xray-manager-core.sh"
grep -Fq 'echo "5) 用户管理"' "$ROOT_DIR/lib/xray-manager-core.sh"
grep -Fq 'echo "6) 分享链接与二维码"' "$ROOT_DIR/lib/xray-manager-core.sh"
echo "Manager menu update test passed."
