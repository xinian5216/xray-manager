#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"

use_test_root() {
  local name="$1"
  XRAY_BIN="$TEST_ROOT/$name/bin/xray"
  XRAY_ROOT="$TEST_ROOT/$name/xray-root"
  CONF_DIR="$XRAY_ROOT/conf.d"
  CERT_DIR="$XRAY_ROOT/certs"
  ASSET_DIR="$TEST_ROOT/$name/assets"
  LOG_DIR="$TEST_ROOT/$name/log"
  STATE_DIR="$TEST_ROOT/$name/state"
  BACKUP_DIR="$STATE_DIR/backups"
  BASE_FILE="$CONF_DIR/00_base.json"
  CONFIG_MIGRATION_STATE_FILE="$STATE_DIR/config_migration.state"
  SYSTEMD_MANAGER_DROPIN="$TEST_ROOT/$name/systemd/20-xray-manager-offline.conf"
  INIT_SYS="test"
  XRAY_RUN_GROUP="$(id -gn)"

  mkdir -p "$(dirname "$XRAY_BIN")" "$CONF_DIR" "$ASSET_DIR"
  cp "$TEST_ROOT/fake-xray" "$XRAY_BIN"
  chmod 755 "$XRAY_BIN"
}

cat >"$TEST_ROOT/fake-xray" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version|-version) echo "Xray migration-test" ;;
  run)
    confdir=""
    while (( $# > 0 )); do
      if [[ "$1" == "-confdir" ]]; then
        confdir="${2:-}"
        break
      fi
      shift
    done
    [[ -n "$confdir" && -d "$confdir" ]]
    ! grep -Rqs 'INVALID_TEST_CONFIG' "$confdir"
    ;;
  *) exit 0 ;;
esac
SH

# A legacy single-file configuration must require two confirmations, remain in
# place, and replace only the Manager copy after validation and backup.
use_test_root file-success
LEGACY_FILE="$XRAY_ROOT/config.json"
printf '{"inbounds":[{"tag":"legacy-file"}]}\n' >"$LEGACY_FILE"
printf '{"inbounds":[{"tag":"manager-before"}]}\n' >"$BASE_FILE"
CONFIRM_COUNT=0
confirm() {
  CONFIRM_COUNT=$((CONFIRM_COUNT + 1))
  return 0
}
migrate_existing_xray_config file "$LEGACY_FILE"

[[ "$CONFIRM_COUNT" -eq 2 ]]
grep -q 'legacy-file' "$BASE_FILE"
grep -q 'legacy-file' "$LEGACY_FILE"
[[ -s "$CONFIG_MIGRATION_STATE_FILE" ]]
BACKUP_PATH="$(sed -n 's/^backup=//p' "$CONFIG_MIGRATION_STATE_FILE")"
PREVIOUS_PATH="$(sed -n 's/^previous_manager_conf=//p' "$CONFIG_MIGRATION_STATE_FILE")"
cmp "$LEGACY_FILE" "$BACKUP_PATH/legacy-config.json"
grep -q 'manager-before' "$BACKUP_PATH/manager-conf-before/00_base.json"
grep -q 'manager-before' "$PREVIOUS_PATH/00_base.json"
[[ -x "$BACKUP_PATH/xray" ]]

# Refusing the second confirmation must abort before creating backups or
# changing either the legacy file or the Manager directory.
use_test_root second-confirm-cancel
LEGACY_FILE="$XRAY_ROOT/config.json"
printf '{"inbounds":[{"tag":"legacy-cancel"}]}\n' >"$LEGACY_FILE"
printf '{"inbounds":[{"tag":"manager-unchanged"}]}\n' >"$BASE_FILE"
CONFIRM_COUNT=0
confirm() {
  CONFIRM_COUNT=$((CONFIRM_COUNT + 1))
  [[ "$CONFIRM_COUNT" -eq 1 ]]
}
if migrate_existing_xray_config file "$LEGACY_FILE"; then
  echo "Migration unexpectedly continued after the second confirmation was refused." >&2
  exit 1
fi
[[ "$CONFIRM_COUNT" -eq 2 ]]
grep -q 'manager-unchanged' "$BASE_FILE"
grep -q 'legacy-cancel' "$LEGACY_FILE"
[[ ! -e "$CONFIG_MIGRATION_STATE_FILE" ]]
[[ ! -e "$BACKUP_DIR" ]]

# A failed Xray configuration test may create diagnostics, but must never
# replace the Manager directory or mark migration as complete.
use_test_root validation-failure
LEGACY_FILE="$XRAY_ROOT/config.json"
printf '{"marker":"INVALID_TEST_CONFIG"}\n' >"$LEGACY_FILE"
printf '{"inbounds":[{"tag":"manager-still-active"}]}\n' >"$BASE_FILE"
confirm() { return 0; }
if migrate_existing_xray_config file "$LEGACY_FILE"; then
  echo "Invalid migrated configuration unexpectedly passed validation." >&2
  exit 1
fi
grep -q 'manager-still-active' "$BASE_FILE"
grep -q 'INVALID_TEST_CONFIG' "$LEGACY_FILE"
[[ ! -e "$CONFIG_MIGRATION_STATE_FILE" ]]

# Preserve all filenames from an existing confdir.  The added empty base only
# prevents ensure_layout from generating a conflicting default configuration.
use_test_root confdir-success
LEGACY_DIR="$TEST_ROOT/confdir-success/legacy-conf.d"
mkdir -p "$LEGACY_DIR"
printf '{"inbounds":[{"tag":"legacy-a"}]}\n' >"$LEGACY_DIR/10_inbounds.json"
printf '{"outbounds":[{"tag":"legacy-b"}]}\n' >"$LEGACY_DIR/90_outbounds.json"
printf '{"inbounds":[{"tag":"manager-old"}]}\n' >"$BASE_FILE"
confirm() { return 0; }
migrate_existing_xray_config dir "$LEGACY_DIR"
[[ -f "$CONF_DIR/10_inbounds.json" ]]
[[ -f "$CONF_DIR/90_outbounds.json" ]]
grep -qx '{}' "$BASE_FILE"
[[ -f "$LEGACY_DIR/10_inbounds.json" ]]

# Recover the standard config.json hidden by the manager's old systemd drop-in.
use_test_root dropin-recovery
mkdir -p "$(dirname "$SYSTEMD_MANAGER_DROPIN")"
printf '[Service]\nExecStart=%s run -confdir %s\n' "$XRAY_BIN" "$CONF_DIR" \
  >"$SYSTEMD_MANAGER_DROPIN"
printf '{"inbounds":[{"tag":"hidden-legacy"}]}\n' >"$XRAY_ROOT/config.json"
DISCOVERED="$(discover_existing_xray_config)"
[[ "$DISCOVERED" == $'file\t'"$XRAY_ROOT/config.json" ]]

[[ "$(extract_xray_config_source \
  'argv[]=/usr/local/bin/xray run -config "/usr/local/etc/xray/config.json" ;')" == \
  $'file\t/usr/local/etc/xray/config.json' ]]

echo "Existing Xray configuration migration tests passed."
