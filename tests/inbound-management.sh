#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

XRAY_BIN="/bin/true"
XRAY_ROOT="$TEST_ROOT/xray"
CONF_DIR="$XRAY_ROOT/conf.d"
CERT_DIR="$XRAY_ROOT/certs"
ASSET_DIR="$TEST_ROOT/assets"
LOG_DIR="$XRAY_ROOT/log"
STATE_DIR="$XRAY_ROOT/state"
BACKUP_DIR="$STATE_DIR/backups"
BASE_FILE="$CONF_DIR/00_base.json"
ROUTING_FILE="$CONF_DIR/30_routing.json"
DOWNLOAD_PROXY_FILE="$STATE_DIR/download_proxy"
DNS64_STATE_FILE="$STATE_DIR/dns64.state"
INIT_SYS=""
XRAY_RUN_USER="$(id -un)"
XRAY_RUN_GROUP="$(id -gn)"

test_config_dir() { return 0; }
test_config() { return 0; }
service_restart() { return 0; }
backup_now() { printf '%s' "$TEST_ROOT/mock-backup.tar.gz"; }
port_in_use() { return 0; }

ensure_layout

MASTER_PSK="$(generate_shadowsocks_secret 2022-blake3-aes-256-gcm)"
USER_PSK="$(generate_shadowsocks_secret 2022-blake3-aes-256-gcm)"
MANAGED_FILE="$CONF_DIR/10_inbound_ss-aes.json"

jq -n --arg password "$MASTER_PSK" '
  {
    inbounds:[{
      tag:"ss-aes",
      protocol:"shadowsocks",
      listen:"0.0.0.0",
      port:8388,
      settings:{
        method:"2022-blake3-aes-256-gcm",
        password:$password,
        email:"default@example.com",
        network:"tcp,udp"
      }
    }]
  }
' >"$MANAGED_FILE"

jq --arg password "$MASTER_PSK" '
  .inbounds=[{
    tag:"external-node",
    protocol:"shadowsocks",
    listen:"127.0.0.1",
    port:9443,
    settings:{
      method:"2022-blake3-aes-256-gcm",
      password:$password,
      network:"tcp"
    }
  }]
' "$BASE_FILE" >"$BASE_FILE.tmp"
mv "$BASE_FILE.tmp" "$BASE_FILE"

inventory="$(inbound_inventory_rows)"
grep -Fq 'external-node' <<<"$inventory"
grep -Fq 'external' <<<"$inventory"
grep -Fq 'ss-aes' <<<"$inventory"
grep -Fq 'single/1' <<<"$inventory"
[[ "$(resolve_inbound_selection 1)" == "external-node" ]]
[[ "$(resolve_inbound_selection 2)" == "ss-aes" ]]
[[ "$(choose_inbound_tag "select" 1 any)" == "external-node" ]]
[[ "$(choose_inbound_tag "select" 2)" == "ss-aes" ]]
if choose_inbound_tag "select" external-node >/dev/null 2>&1; then
  echo "external inbounds must remain read-only" >&2
  exit 1
fi

summary="$(show_inbound_summary_file "$MANAGED_FILE" ss-aes)"
grep -Fq '单用户' <<<"$summary"
grep -Fq 'direct' <<<"$summary"
if grep -Fq "$MASTER_PSK" <<<"$summary"; then
  echo "inbound summary disclosed the full server PSK" >&2
  exit 1
fi

redacted="$(
  confirm() { return 1; }
  show_inbound_raw_config ss-aes
)"
jq -e '.inbounds | length == 1' <<<"$redacted" >/dev/null
jq -e '.inbounds[0].settings.password == "<redacted>"' <<<"$redacted" >/dev/null
if grep -Fq "$MASTER_PSK" <<<"$redacted"; then
  echo "redacted inbound JSON disclosed the server PSK" >&2
  exit 1
fi

build_share_link "$MANAGED_FILE" 0 example.com single
expected="$(printf '%s' "2022-blake3-aes-256-gcm:${MASTER_PSK}" | base64_urlsafe)"
[[ "$SHARE_LINK" == "ss://${expected}@example.com:8388#single" ]]

(
  confirm() { return 0; }
  add_inbound_user ss-aes <<<"$(printf 'phone@example.com\n%s\n' "$USER_PSK")" >/dev/null
)
jq -e --arg password "$USER_PSK" '
  (.inbounds[0].settings.users | length) == 1 and
  .inbounds[0].settings.users[0].password == $password and
  .inbounds[0].settings.users[0].email == "phone@example.com"
' "$MANAGED_FILE" >/dev/null

users="$(list_inbound_users_file "$MANAGED_FILE" 0)"
grep -Fq '服务器主 PSK' <<<"$users"
grep -Fq 'phone@example.com' <<<"$users"
if grep -Eq '^0[[:space:]]' <<<"$users"; then
  echo "multi-user Shadowsocks incorrectly exposed a default user" >&2
  exit 1
fi
if build_share_link "$MANAGED_FILE" 0 example.com invalid >/dev/null 2>&1; then
  echo "multi-user Shadowsocks unexpectedly shared the server PSK" >&2
  exit 1
fi

build_share_link "$MANAGED_FILE" 1 example.com multi
expected="$(printf '%s' "2022-blake3-aes-256-gcm:${MASTER_PSK}:${USER_PSK}" | base64_urlsafe)"
[[ "$SHARE_LINK" == "ss://${expected}@example.com:8388#multi" ]]
grep -Fq 'multi/1' <<<"$(inbound_inventory_rows)"

diagnosis="$(diagnose_inbound ss-aes)"
grep -Fq '0 项错误' <<<"$diagnosis"
validate_shadowsocks_2022_secret 2022-blake3-aes-256-gcm "$MASTER_PSK"
if validate_shadowsocks_2022_secret 2022-blake3-aes-256-gcm invalid; then
  echo "invalid SS2022 server PSK unexpectedly passed validation" >&2
  exit 1
fi

(
  confirm() { return 0; }
  delete_inbound_user ss-aes <<<"1" >/dev/null
)
jq -e '.inbounds[0].settings | has("users") | not' "$MANAGED_FILE" >/dev/null
build_share_link "$MANAGED_FILE" 0 example.com restored
expected="$(printf '%s' "2022-blake3-aes-256-gcm:${MASTER_PSK}" | base64_urlsafe)"
[[ "$SHARE_LINK" == "ss://${expected}@example.com:8388#restored" ]]
grep -Fq 'single/1' <<<"$(inbound_inventory_rows)"

CHACHA_FILE="$CONF_DIR/10_inbound_ss-chacha.json"
jq --arg password "$MASTER_PSK" '
  .inbounds[0].tag="ss-chacha" |
  .inbounds[0].port=8389 |
  .inbounds[0].settings.method="2022-blake3-chacha20-poly1305" |
  .inbounds[0].settings.password=$password
' "$MANAGED_FILE" >"$CHACHA_FILE"
if add_inbound_user ss-chacha >/dev/null 2>&1; then
  echo "ChaCha20-2022 unexpectedly accepted multi-user mode" >&2
  exit 1
fi
jq -e '.inbounds[0].settings | has("users") | not' "$CHACHA_FILE" >/dev/null

UFW_CALLS="$TEST_ROOT/ufw-calls"
ufw() {
  printf '%s ' "$@" >>"$UFW_CALLS"
  printf '\n' >>"$UFW_CALLS"
  if [[ "${1:-}" == "status" ]]; then
    printf 'Status: active\n\n'
    printf '8388/tcp ALLOW Anywhere # XrayManager:ss-aes:tcp\n'
    printf '8388/udp ALLOW Anywhere # XrayManager:ss-aes:udp\n'
    printf '9443/tcp ALLOW Anywhere # manually-created\n'
  fi
}

maybe_ufw_for_transport 8388 native shadowsocks ss-aes
grep -Fq 'allow 8388/tcp comment XrayManager:ss-aes:tcp' "$UFW_CALLS"
grep -Fq 'allow 8388/udp comment XrayManager:ss-aes:udp' "$UFW_CALLS"
remove_managed_ufw_rules ss-aes 8388
grep -Fq -- '--force delete allow 8388/tcp' "$UFW_CALLS"
grep -Fq -- '--force delete allow 8388/udp' "$UFW_CALLS"
remove_managed_ufw_rules external-node 9443
if grep -Fq -- '--force delete allow 9443/tcp' "$UFW_CALLS"; then
  echo "manager attempted to delete an unrelated UFW rule" >&2
  exit 1
fi

echo "Inbound management regression tests passed."
