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
XRAY_RUN_USER="$(id -un)"
XRAY_RUN_GROUP="$(id -gn)"
INIT_SYS=""

PRIVATE_1='AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE='
PUBLIC_1='pOCSkrZRwni5dyxWn1+puxPZBrRqtoyd+dwrRAn4ogk='
PRIVATE_2='AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI='
PUBLIC_2='zo060cy2M+x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk='
PRIVATE_3='AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM='
PUBLIC_3='Xf7dO2vUf2+ijuFdlp1bsOpTd01Ii9r53xxuASSz7yI='
PRIVATE_4='BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ='
PUBLIC_4='rAGyIJ6GNU+4UyN7XeD0+rE8f8v0M6YcAZNpYX/s8Qs='
KEY_COUNTER="$TEST_ROOT/key-counter"
printf '0\n' >"$KEY_COUNTER"

test_config_dir() { return 0; }
test_config() { return 0; }
service_restart() { return 0; }
port_in_use() { return 1; }
install_wireguard_tools() { return 0; }
maybe_ufw_for_transport() { return 0; }

wg() {
  local number private
  case "${1:-}" in
    genkey)
      number="$(cat "$KEY_COUNTER")"
      number=$((number + 1))
      printf '%s\n' "$number" >"$KEY_COUNTER"
      case "$number" in
        1) printf '%s' "$PRIVATE_1" ;;
        2) printf '%s' "$PRIVATE_2" ;;
        3) printf '%s' "$PRIVATE_3" ;;
        4) printf '%s' "$PRIVATE_4" ;;
        *) return 1 ;;
      esac
      ;;
    pubkey)
      private="$(cat)"
      case "$private" in
        "$PRIVATE_1") printf '%s' "$PUBLIC_1" ;;
        "$PRIVATE_2") printf '%s' "$PUBLIC_2" ;;
        "$PRIVATE_3") printf '%s' "$PUBLIC_3" ;;
        "$PRIVATE_4") printf '%s' "$PUBLIC_4" ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

ensure_layout

validate_wireguard_key "$PRIVATE_1"
! validate_wireguard_key invalid
validate_wireguard_cidr '10.66.66.2/32'
validate_wireguard_cidr 'fd42:42:42::2/128'
validate_wireguard_cidr '::/0'
! validate_wireguard_cidr '10.66.66.999/32'
! validate_wireguard_cidr 'fd42:::2/128'
! validate_wireguard_cidr '10.66.66.2/33'
validate_wireguard_endpoint 'vpn.example.com:51820'
validate_wireguard_endpoint '[2001:db8::10]:51820'
! validate_wireguard_endpoint '2001:db8::10:51820'
! validate_wireguard_endpoint 'vpn.example.com:99999'
wireguard_cidrs_overlap '10.66.66.0/24' '10.66.66.2/32'
! wireguard_cidrs_overlap '10.66.66.2/32' '10.66.66.3/32'
wireguard_cidrs_overlap 'fd42:42:42::/64' 'fd42:42:42::2/128'
! wireguard_cidrs_overlap 'fd42:42:42::2/128' 'fd42:42:42::3/128'

creation="$(add_wireguard <<< $'wg-home\n51820\n0.0.0.0\n1\nphone\n10.66.66.2/32,fd42:42:42::2/128\n1280\nvpn.example.com\n\n\n\n')"
WG_FILE="$CONF_DIR/10_inbound_wg-home.json"
jq -e --arg public "$PUBLIC_2" '
  .inbounds[0].settings.peers[0].publicKey == $public and
  .inbounds[0].settings.peers[0].allowedIPs ==
    ["10.66.66.2/32", "fd42:42:42::2/128"]
' "$WG_FILE" >/dev/null
grep -Fq "$PUBLIC_1" <<<"$creation"
if grep -Fq "$PRIVATE_1" <<<"$creation" || grep -Fq "$PRIVATE_2" <<<"$creation"; then
  echo "WireGuard creation unexpectedly disclosed a private key" >&2
  exit 1
fi
PROFILE_1="$(wireguard_profile_path wg-home "$PUBLIC_2")"
[[ "$(stat -c '%a' "$PROFILE_1")" == "600" ]]
[[ "$(stat -c '%a' "$(dirname "$PROFILE_1")")" == "700" ]]

client_config="$(render_wireguard_client_config wg-home 1)"
grep -Fq "PrivateKey = $PRIVATE_2" <<<"$client_config"
grep -Fq "PublicKey = $PUBLIC_1" <<<"$client_config"
grep -Fq 'Endpoint = vpn.example.com:51820' <<<"$client_config"
grep -Fq 'AllowedIPs = 0.0.0.0/0,::/0' <<<"$client_config"
grep -Fq 'PersistentKeepalive = 25' <<<"$client_config"
grep -Fq 'peers/1' <<<"$(inbound_inventory_rows)"
grep -Fq '客户端数量' <<<"$(show_inbound_summary_file "$WG_FILE" wg-home)"

(
  confirm() { return 0; }
  add_inbound_user wg-home <<< $'1\nlaptop\n\nvpn.example.com\n\n\n\n' >/dev/null
)
jq -e --arg public "$PUBLIC_3" '
  (.inbounds[0].settings.peers | length) == 2 and
  .inbounds[0].settings.peers[1].publicKey == $public and
  .inbounds[0].settings.peers[1].allowedIPs == ["10.66.66.3/32"]
' "$WG_FILE" >/dev/null
grep -Fq 'laptop' <<<"$(list_inbound_users_file "$WG_FILE" 0)"
grep -Fq 'peers/2' <<<"$(inbound_inventory_rows)"

if (
  confirm() { return 0; }
  add_inbound_user wg-home <<< $'2\nconflict\n10.66.66.2/32\n' >/dev/null 2>&1
); then
  echo "WireGuard unexpectedly accepted an overlapping client address" >&2
  exit 1
fi

(
  confirm() { return 0; }
  add_inbound_user wg-home <<<"$(printf '2\ntablet\n10.66.66.4/32\n%s\n' "$PUBLIC_4")" >/dev/null
)
jq -e '(.inbounds[0].settings.peers | length) == 3' "$WG_FILE" >/dev/null
if render_wireguard_client_config wg-home 3 >/dev/null 2>&1; then
  echo "a public-key-only WireGuard peer unexpectedly exported a private key" >&2
  exit 1
fi

edit_inbound_user wg-home <<< $'2\n1\nwork-laptop\n' >/dev/null
grep -Fq 'work-laptop' <<<"$(list_inbound_users_file "$WG_FILE" 0)"
(
  confirm() { return 0; }
  edit_inbound_user wg-home <<< $'2\n2\n10.66.66.20/32\n' >/dev/null
)
jq -e '.inbounds[0].settings.peers[1].allowedIPs == ["10.66.66.20/32"]' \
  "$WG_FILE" >/dev/null
grep -Fq 'Address = 10.66.66.20/32' <<<"$(render_wireguard_client_config wg-home 2)"

shared="$(
  confirm() { [[ "$1" == 确认在终端显示完整客户端配置* ]]; }
  show_inbound_share_link wg-home <<<"1"
)"
grep -Fq "PrivateKey = $PRIVATE_2" <<<"$shared"

diagnosis="$(diagnose_inbound wg-home 2>&1)"
grep -Fq '0 项错误' <<<"$diagnosis"

CONF_FILE="$TEST_ROOT/provider.conf"
cat >"$CONF_FILE" <<EOF
[Interface]
PrivateKey = $PRIVATE_2
Address = 172.16.0.2/32, fd00::2/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $PUBLIC_1
PresharedKey = $PRIVATE_4
Endpoint = [2001:db8::10]:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

import_wireguard_outbound <<<"$(printf 'provider\n%s\n\n\n\n' "$CONF_FILE")" >/dev/null
OUTBOUND_FILE="$CONF_DIR/20_outbound_provider_tail.json"
jq -e --arg secret "$PRIVATE_2" --arg public "$PUBLIC_1" --arg psk "$PRIVATE_4" '
  .outbounds[0].settings.secretKey == $secret and
  .outbounds[0].settings.address == ["172.16.0.2/32", "fd00::2/128"] and
  .outbounds[0].settings.peers[0].publicKey == $public and
  .outbounds[0].settings.peers[0].preSharedKey == $psk and
  .outbounds[0].settings.peers[0].endpoint == "[2001:db8::10]:51820" and
  .outbounds[0].settings.peers[0].keepAlive == 25 and
  .outbounds[0].settings.noKernelTun == true
' "$OUTBOUND_FILE" >/dev/null

if build_wireguard_outbound_json bad invalid '172.16.0.2/32' \
    'vpn.example.com:51820' "$PUBLIC_1" '0.0.0.0/0' '' '' 1280 25 ForceIP true \
    >/dev/null 2>&1; then
  echo "WireGuard outbound unexpectedly accepted an invalid private key" >&2
  exit 1
fi
if build_wireguard_outbound_json bad "$PRIVATE_2" '172.16.0.2/32' \
    'vpn.example.com:51820' "$PUBLIC_1" '0.0.0.0/0' '' '' 1280 25 ForceIPv6 true \
    >/dev/null 2>&1; then
  echo "WireGuard outbound unexpectedly accepted IPv6-only strategy without an IPv6 address" >&2
  exit 1
fi

backup="$(backup_now)"
backup_listing="$(tar -tzf "$backup")"
grep -Fq 'wireguard/wg-home/' <<<"$backup_listing"
rm -f "$PROFILE_1"
backup_index="$(find "$BACKUP_DIR" -maxdepth 1 -name 'xray-config-*.tar.gz' |
  wc -l | tr -d '[:space:]')"
(
  confirm() { return 0; }
  restore_backup <<<"$backup_index" >/dev/null
)
[[ -r "$PROFILE_1" ]]
[[ "$(stat -c '%a' "$PROFILE_1")" == "600" ]]
grep -Fq "PrivateKey = $PRIVATE_2" <<<"$(render_wireguard_client_config wg-home 1)"

(
  confirm() { return 0; }
  delete_inbound_user wg-home <<<"3" >/dev/null
)
[[ ! -f "$(wireguard_profile_path wg-home "$PUBLIC_4")" ]]
(
  confirm() { return 0; }
  delete_inbound_user wg-home <<<"2" >/dev/null
)
if delete_inbound_user wg-home >/dev/null 2>&1; then
  echo "WireGuard unexpectedly deleted its final authenticated client" >&2
  exit 1
fi

(
  confirm() { return 0; }
  delete_inbound wg-home >/dev/null
)
[[ ! -d "$(wireguard_profile_directory wg-home)" ]]

echo "WireGuard management regression tests passed."
