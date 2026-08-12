#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XRAY_TEST_BIN="${XRAY_TEST_BIN:-}"
XRAY_TEST_ASSET_DIR="${XRAY_TEST_ASSET_DIR:-$(dirname "$XRAY_TEST_BIN")}"

[[ -x "$XRAY_TEST_BIN" ]] || {
  echo "XRAY_TEST_BIN must point to an executable Xray binary." >&2
  exit 1
}

# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

service_restart() { return 0; }
backup_now() { printf '%s' "$TEST_ROOT/dummy-backup.tar.gz"; }

reset_case() {
  local name="$1"
  XRAY_BIN="$XRAY_TEST_BIN"
  XRAY_ROOT="$TEST_ROOT/$name"
  CONF_DIR="$XRAY_ROOT/conf.d"
  CERT_DIR="$XRAY_ROOT/certs"
  ASSET_DIR="$XRAY_TEST_ASSET_DIR"
  LOG_DIR="$XRAY_ROOT/log"
  STATE_DIR="$XRAY_ROOT/state"
  BACKUP_DIR="$STATE_DIR/backups"
  BASE_FILE="$CONF_DIR/00_base.json"
  ROUTING_FILE="$CONF_DIR/30_routing.json"
  DOWNLOAD_PROXY_FILE="$STATE_DIR/download_proxy"
  DNS64_STATE_FILE="$STATE_DIR/dns64.state"
  XRAY_RUN_GROUP="$(id -gn)"
  ensure_layout

  jq --arg access "$LOG_DIR/access.log" --arg error "$LOG_DIR/error.log" \
    '.log.access=$access | .log.error=$error' "$BASE_FILE" >"$BASE_FILE.tmp"
  mv "$BASE_FILE.tmp" "$BASE_FILE"
}

assert_config() {
  "$XRAY_BIN" run -confdir "$CONF_DIR" -test >/dev/null
}

test_retry_inputs() {
  local value
  value="$(ask_required "value" <<< $'\nvalid')"
  [[ "$value" == "valid" ]]
  value="$(ask_port "port" "443" <<< $'invalid\n8443')"
  [[ "$value" == "8443" ]]
}

test_vless_reality() {
  reset_case vless-reality
  XRAY_MANAGER_SKIP_TARGET_PROBE=1 \
    add_vless <<< $'\n\n\n\n\n\nexample.com\n\n\n\ny' >"$XRAY_ROOT/result.txt"
  [[ "$TRANSPORT" == "raw" ]]
  [[ -n "$REALITY_PUBLIC" && -n "$REALITY_SHORTID" && "$REALITY_SNI" == "example.com" ]]
  [[ "$REALITY_LIMIT_FALLBACK" == "1" ]]
  grep -q 'PublicKey' "$XRAY_ROOT/result.txt"
  jq -e '.inbounds[0].settings.users[0].flow=="xtls-rprx-vision"' \
    "$CONF_DIR/10_inbound_vless-reality.json" >/dev/null
  jq -e '
    .inbounds[0].streamSettings.realitySettings.limitFallbackUpload.bytesPerSec > 0 and
    .inbounds[0].streamSettings.realitySettings.limitFallbackDownload.bytesPerSec > 0
  ' "$CONF_DIR/10_inbound_vless-reality.json" >/dev/null
  assert_config
}

test_inbound_edit_users_and_links() {
  local file fixed_uuid
  reset_case inbound-edit-users-links
  XRAY_MANAGER_SKIP_TARGET_PROBE=1 \
    add_vless <<< $'managed-vless\n2443\n\n11111111-1111-4111-8111-111111111111\n\n\nexample.com\n\n\n\ny' >/dev/null
  file="$CONF_DIR/10_inbound_managed-vless.json"
  fixed_uuid="22222222-2222-4222-8222-222222222222"

  (
    confirm() { return 0; }
    add_inbound_user <<< $'managed-vless\nphone@example.com\n22222222-2222-4222-8222-222222222222\n\n' >/dev/null
  )
  jq -e --arg id "$fixed_uuid" '
    (.inbounds[0].settings.users | length) == 2 and
    .inbounds[0].settings.users[1].id == $id and
    .inbounds[0].settings.users[1].email == "phone@example.com"
  ' "$file" >/dev/null

  build_share_link "$file" 2 "2001:db8::10" "手机节点"
  [[ "$SHARE_LINK" == "vless://${fixed_uuid}@[2001:db8::10]:2443?"* ]]
  [[ "$SHARE_LINK" == *"encryption=none"* ]]
  [[ "$SHARE_LINK" == *"type=tcp"* ]]
  [[ "$SHARE_LINK" == *"security=reality"* ]]
  [[ "$SHARE_LINK" == *"pbk="*"&sid="* ]]
  [[ "$SHARE_LINK" == *"#%E6%89%8B%E6%9C%BA%E8%8A%82%E7%82%B9" ]]

  (
    confirm() { return 0; }
    edit_inbound_user <<< $'managed-vless\n2\n2\nrenamed@example.com\n' >/dev/null
  )
  jq -e '.inbounds[0].settings.users[1].email == "renamed@example.com"' "$file" >/dev/null

  (
    confirm() { return 0; }
    delete_inbound_user <<< $'managed-vless\n2\n' >/dev/null
  )
  jq -e '(.inbounds[0].settings.users | length) == 1' "$file" >/dev/null
  assert_config
}

test_reality_target_risk_detection() {
  known_shared_cdn_name "cdn.example.cloudfront.net"
  known_shared_cdn_name "WWW.CLOUDFLARE.COM"
  ! known_shared_cdn_name "origin.example.net"
}

test_high_risk_target_can_disable_limits() {
  REALITY_TARGET_HIGH_RISK=1
  REALITY_LIMIT_FALLBACK=1
  configure_reality_fallback_limits <<< $'3\ny' >/dev/null 2>&1
  [[ "$REALITY_LIMIT_FALLBACK" == "0" ]]
  REALITY_TARGET_HIGH_RISK=0
}

test_vmess_transport() {
  local name="$1" expected="$2" input="$3" expected_link_net payload
  reset_case "vmess-$name"
  add_vmess <<< "$input" >/dev/null
  [[ "$TRANSPORT" == "$expected" ]]
  jq -e --arg expected "$expected" \
    '.inbounds[0].streamSettings.method==$expected' \
    "$CONF_DIR/10_inbound_vmess.json" >/dev/null
  case "$expected" in
    raw) expected_link_net="tcp" ;;
    websocket) expected_link_net="ws" ;;
    mkcp) expected_link_net="kcp" ;;
    *) expected_link_net="$expected" ;;
  esac
  build_share_link "$CONF_DIR/10_inbound_vmess.json" 1 "example.com" "vmess-$name"
  payload="${SHARE_LINK#vmess://}"
  printf '%s' "$payload" | base64 -d | jq -e --arg net "$expected_link_net" '
    .net == $net and .add == "example.com" and .port == "8443"
  ' >/dev/null
  assert_config
}

test_basic_inbounds() {
  reset_case shadowsocks
  add_shadowsocks <<< $'\n\n\n\n\n\n' >/dev/null
  build_share_link "$CONF_DIR/10_inbound_ss2022.json" 0 "2001:db8::20" "ss"
  [[ "$SHARE_LINK" == ss://*"@[2001:db8::20]:8388#ss" ]]
  assert_config

  reset_case socks
  add_socks <<< $'\n\n\n\n\n\ny' >/dev/null
  build_share_link "$CONF_DIR/10_inbound_socks-local.json" 1 "127.0.0.1" "socks"
  [[ "$SHARE_LINK" == socks5://*"@127.0.0.1:1080#socks" ]]
  assert_config

  reset_case http
  add_http <<< $'\n\n\n\n\n' >/dev/null
  build_share_link "$CONF_DIR/10_inbound_http-local.json" 1 "127.0.0.1" "http"
  [[ "$SHARE_LINK" == http://*"@127.0.0.1:8080#http" ]]
  assert_config

  reset_case tunnel
  add_tunnel <<< $'\n\n\n\nexample.com\n\n' >/dev/null
  assert_config
}

test_hysteria() {
  reset_case hysteria
  mkdir -p "$TEST_ROOT/cert"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj /CN=example.com \
    -keyout "$TEST_ROOT/cert/key.pem" \
    -out "$TEST_ROOT/cert/fullchain.pem" >/dev/null 2>&1
  tls_certificate_wizard() {
    TLS_DOMAIN="example.com"
    MANAGED_CERT="$TEST_ROOT/cert/fullchain.pem"
    MANAGED_KEY="$TEST_ROOT/cert/key.pem"
  }
  add_hysteria2 <<< $'\n\n\n\n\n\n\n' >/dev/null
  build_share_link "$CONF_DIR/10_inbound_hysteria2.json" 1 "example.com" "hysteria"
  [[ "$SHARE_LINK" == hysteria2://*"@example.com:443?sni=example.com#hysteria" ]]
  assert_config
}

test_trojan_tls() {
  reset_case trojan-tls
  tls_certificate_wizard() {
    TLS_DOMAIN="example.com"
    MANAGED_CERT="$TEST_ROOT/cert/fullchain.pem"
    MANAGED_KEY="$TEST_ROOT/cert/key.pem"
  }
  add_trojan <<< $'\n\n\n\n\n\n\n' >/dev/null
  [[ "$TRANSPORT" == "raw" ]]
  jq -e '.inbounds[0].streamSettings.security=="tls"' \
    "$CONF_DIR/10_inbound_trojan-tls.json" >/dev/null
  build_share_link "$CONF_DIR/10_inbound_trojan-tls.json" 1 "example.com" "trojan"
  [[ "$SHARE_LINK" == trojan://*"@example.com:443?"*"security=tls"*"#trojan" ]]
  assert_config
}

test_wireguard() {
  reset_case wireguard
  install_wireguard_tools() { return 0; }
  wg() {
    case "${1:-}" in
      genkey) printf 'sK2oMSqqEg22cmF4d33HTUdTo1xTu9VZ+RNw6YNPXFY=' ;;
      pubkey)
        cat >/dev/null
        printf 'VKtOMD/fGswMa9Lq7XW1QmfUWZtcZ+IlOUGMUzYYuF4='
        ;;
    esac
  }
  add_wireguard <<< $'\n\n\nVKtOMD/fGswMa9Lq7XW1QmfUWZtcZ+IlOUGMUzYYuF4=\n\n\n' >/dev/null
  assert_config
}

test_outbounds_routing_and_forwarding() {
  reset_case outbound-routing

  add_freedom_outbound <<< $'\n2\n\n' >/dev/null
  jq -e '
    .outbounds[0].tag == "direct-v4" and
    .outbounds[0].protocol == "freedom" and
    .outbounds[0].settings.domainStrategy == "UseIPv4"
  ' "$CONF_DIR/20_outbound_direct-v4_tail.json" >/dev/null

  add_plain_proxy_outbound "socks" <<< $'warp-socks\n127.0.0.1\n40000\nn\n' >/dev/null
  jq -e '
    .outbounds[0].protocol == "socks" and
    .outbounds[0].settings.address == "127.0.0.1" and
    .outbounds[0].settings.port == 40000
  ' "$CONF_DIR/20_outbound_warp-socks_tail.json" >/dev/null

  add_plain_proxy_outbound "http" <<< $'http-out\n127.0.0.1\n3128\nn\n' >/dev/null
  jq -e '
    .outbounds[0].protocol == "http" and
    .outbounds[0].settings.port == 3128
  ' "$CONF_DIR/20_outbound_http-out_tail.json" >/dev/null

  add_shadowsocks_outbound <<< $'ss-out\n127.0.0.1\n8388\n2022-blake3-aes-128-gcm\nMTIzNDU2Nzg5MDEyMzQ1Ng==\n' >/dev/null
  jq -e '
    .outbounds[0].protocol == "shadowsocks" and
    .outbounds[0].settings.method == "2022-blake3-aes-128-gcm"
  ' "$CONF_DIR/20_outbound_ss-out_tail.json" >/dev/null

  add_wireguard_outbound <<< $'warp-native\nsK2oMSqqEg22cmF4d33HTUdTo1xTu9VZ+RNw6YNPXFY=\n172.16.0.2/32\n\nVKtOMD/fGswMa9Lq7XW1QmfUWZtcZ+IlOUGMUzYYuF4=\n\n\n\n\n\n\n' >/dev/null
  jq -e '
    .outbounds[0].protocol == "wireguard" and
    .outbounds[0].settings.noKernelTun == true and
    .outbounds[0].settings.peers[0].endpoint == "engage.cloudflareclient.com:2408"
  ' "$CONF_DIR/20_outbound_warp-native_tail.json" >/dev/null

  add_domain_route <<< $'\ngeosite:google\ndirect-v4\n' >/dev/null
  add_service_route_preset <<< $'3\ndirect-v4\n' >/dev/null
  set_default_outbound_route <<< $'direct-v4\n' >/dev/null
  add_ip_family_route "6" <<< $'\ndirect-v4\n' >/dev/null

  jq -e '
    .routing.domainStrategy == "IPIfNonMatch" and
    .routing.rules[0].ruleTag == "domain-route" and
    .routing.rules[1].ruleTag == "service-openai-domain" and
    .routing.rules[2].ruleTag == "ipv6-route" and
    .routing.rules[-1].ruleTag == "manager-default"
  ' "$ROUTING_FILE" >/dev/null

  add_tunnel <<< $'game-forward\n1\n25565\n3\nexample.com\n25565\ndirect-v4\n' >/dev/null
  jq -e '
    .inbounds[0].protocol == "tunnel" and
    .inbounds[0].listen == "0.0.0.0" and
    .inbounds[0].settings.allowedNetwork == "tcp,udp" and
    .inbounds[0].settings.rewriteAddress == "example.com"
  ' "$CONF_DIR/10_inbound_game-forward.json" >/dev/null
  jq -e '
    .routing.rules[] |
    select(
      .ruleTag == "forward-game-forward" and
      .inboundTag[0] == "game-forward" and
      .outboundTag == "direct-v4"
    )
  ' "$ROUTING_FILE" >/dev/null
  assert_config

  delete_inbound "game-forward" <<< $'y\n' >/dev/null
  [[ ! -f "$CONF_DIR/10_inbound_game-forward.json" ]]
  ! jq -e '.routing.rules[]? | select(.ruleTag == "forward-game-forward")' \
    "$ROUTING_FILE" >/dev/null
  assert_config
}

test_routing_conflict_guard() {
  reset_case routing-conflict
  jq -n '{routing:{domainStrategy:"AsIs",rules:[]}}' >"$CONF_DIR/40_legacy-routing.json"
  if routing_ready >/dev/null 2>&1; then
    echo "routing_ready unexpectedly accepted a legacy routing object" >&2
    return 1
  fi
  [[ ! -f "$ROUTING_FILE" ]]
}

test_retry_inputs
test_reality_target_risk_detection
test_high_risk_target_can_disable_limits
test_vless_reality
test_inbound_edit_users_and_links
test_vmess_transport raw raw $'\n\n\n\n1\n2\ny'
test_vmess_transport xhttp xhttp $'\n\n\n\n2\n\n2\ny'
test_vmess_transport grpc grpc $'\n\n\n\n3\n\n2\ny'
test_vmess_transport websocket websocket $'\n\n\n\n4\n\n\n2\ny'
test_vmess_transport httpupgrade httpupgrade $'\n\n\n\n5\n\n\n2\ny'
test_vmess_transport mkcp mkcp $'\n\n\n\n6\n\n'
test_basic_inbounds
test_hysteria
test_trojan_tls
test_wireguard
test_outbounds_routing_and_forwarding
test_routing_conflict_guard

echo "All Xray configuration smoke tests passed."
