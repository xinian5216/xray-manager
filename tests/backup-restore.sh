#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

XRAY_BIN="/bin/true"
XRAY_RUN_USER="$(id -un)"
XRAY_RUN_GROUP="$(id -gn)"
INIT_SYS=""
RESTART_MODE="success"
RESTART_COUNTER=""

set_test_paths() {
  local name="$1"
  XRAY_ROOT="$TEST_ROOT/$name/xray"
  CONF_DIR="$XRAY_ROOT/conf.d"
  CERT_DIR="$XRAY_ROOT/certs"
  ASSET_DIR="$TEST_ROOT/$name/assets"
  LOG_DIR="$TEST_ROOT/$name/log"
  STATE_DIR="$TEST_ROOT/$name/state"
  BACKUP_DIR="$STATE_DIR/backups"
  BASE_FILE="$CONF_DIR/00_base.json"
  ROUTING_FILE="$CONF_DIR/30_routing.json"
  DOWNLOAD_PROXY_FILE="$STATE_DIR/download_proxy"
  DNS64_STATE_FILE="$STATE_DIR/dns64.state"
  RESTART_COUNTER="$TEST_ROOT/$name/restarts"
  mkdir -p "$(dirname "$RESTART_COUNTER")"
  printf '0\n' >"$RESTART_COUNTER"
  ensure_layout
}

service_restart() {
  local count
  count="$(cat "$RESTART_COUNTER")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$RESTART_COUNTER"
  case "$RESTART_MODE" in
    success) return 0 ;;
    fail-once) (( count > 1 )) ;;
    always-fail) return 1 ;;
    *) return 1 ;;
  esac
}

test_config_dir() {
  local dir="$1"
  ! grep -Rqs '"invalid"[[:space:]]*:[[:space:]]*true' "$dir"
}

test_config() {
  test_config_dir "$CONF_DIR"
}

confirm() {
  return 0
}

write_state() {
  local marker="$1"
  printf '{"marker":"%s"}\n' "$marker" >"$CONF_DIR/10_state.json"
  mkdir -p "$CERT_DIR/site" "$STATE_DIR/wireguard/peer"
  printf 'cert-%s\n' "$marker" >"$CERT_DIR/site/fullchain.pem"
  printf 'key-%s\n' "$marker" >"$CERT_DIR/site/key.pem"
  printf 'wireguard-%s\n' "$marker" >"$STATE_DIR/wireguard/peer/profile.json"
  chmod 750 "$CERT_DIR/site"
  chmod 640 "$CERT_DIR/site/fullchain.pem" "$CERT_DIR/site/key.pem"
  chmod 700 "$STATE_DIR/wireguard" "$STATE_DIR/wireguard/peer"
  chmod 600 "$STATE_DIR/wireguard/peer/profile.json"
}

assert_state() {
  local marker="$1"
  grep -Fq "\"marker\":\"$marker\"" "$CONF_DIR/10_state.json"
  grep -Fxq "cert-$marker" "$CERT_DIR/site/fullchain.pem"
  grep -Fxq "key-$marker" "$CERT_DIR/site/key.pem"
  grep -Fxq "wireguard-$marker" "$STATE_DIR/wireguard/peer/profile.json"
}

set_test_paths success
write_state backup
SUCCESS_BACKUP="$(backup_now)"
validate_backup_archive "$SUCCESS_BACKUP"
tar -xOf "$SUCCESS_BACKUP" ./backup-manifest.json |
  jq -e --arg version "$SCRIPT_VERSION" \
    '.format == 1 and .managerVersion == $version and
    .includes.configuration == true and .includes.certificates == true and
    .includes.wireguard == true' >/dev/null
write_state current
RESTART_MODE="success"
restore_backup <<<"1" >/dev/null
assert_state backup
[[ "$(cat "$RESTART_COUNTER")" == "1" ]]
[[ "$(stat -c '%a' "$CERT_DIR/site/key.pem")" == "640" ]]
[[ "$(stat -c '%a' "$STATE_DIR/wireguard/peer/profile.json")" == "600" ]]

set_test_paths rollback
write_state target
ROLLBACK_BACKUP="$(backup_now)"
write_state original
RESTART_MODE="fail-once"
set +e
restore_backup <<<"1" >/dev/null 2>&1
restore_rc=$?
set -e
[[ "$restore_rc" == "1" ]]
assert_state original
[[ "$(cat "$RESTART_COUNTER")" == "2" ]]
validate_backup_archive "$ROLLBACK_BACKUP"

set_test_paths invalid-config
INVALID_STAGE="$TEST_ROOT/invalid-config/archive"
mkdir -p "$INVALID_STAGE/conf.d"
printf '{"invalid":true}\n' >"$INVALID_STAGE/conf.d/10_invalid.json"
INVALID_BACKUP="$BACKUP_DIR/xray-config-invalid.tar.gz"
tar -C "$INVALID_STAGE" -czf "$INVALID_BACKUP" conf.d
write_state original
set +e
restore_backup <<<"1" >/dev/null 2>&1
invalid_rc=$?
set -e
[[ "$invalid_rc" == "1" ]]
assert_state original
[[ "$(cat "$RESTART_COUNTER")" == "0" ]]

set_test_paths unsafe-link
UNSAFE_STAGE="$TEST_ROOT/unsafe-link/archive"
mkdir -p "$UNSAFE_STAGE/conf.d"
printf '{}\n' >"$UNSAFE_STAGE/conf.d/00_base.json"
ln -s /etc/passwd "$UNSAFE_STAGE/conf.d/escape"
UNSAFE_BACKUP="$BACKUP_DIR/xray-config-unsafe-link.tar.gz"
tar -C "$UNSAFE_STAGE" -czf "$UNSAFE_BACKUP" conf.d
if validate_backup_archive "$UNSAFE_BACKUP" >/dev/null 2>&1; then
  echo "Backup validation unexpectedly accepted a symbolic link" >&2
  exit 1
fi

set_test_paths legacy
LEGACY_STAGE="$TEST_ROOT/legacy/archive"
mkdir -p "$LEGACY_STAGE/conf.d"
printf '{"marker":"legacy"}\n' >"$LEGACY_STAGE/conf.d/10_state.json"
LEGACY_BACKUP="$BACKUP_DIR/xray-config-legacy.tar.gz"
tar -C "$LEGACY_STAGE" -czf "$LEGACY_BACKUP" conf.d
write_state current
RESTART_MODE="success"
restore_backup <<<"1" >/dev/null
grep -Fq '"marker":"legacy"' "$CONF_DIR/10_state.json"
[[ ! -d "$STATE_DIR/wireguard" ]]
[[ -r "$CERT_DIR/site/key.pem" ]]

echo "Backup restore transaction regression tests passed."
