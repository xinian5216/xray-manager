#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XRAY_TEST_BIN="${XRAY_TEST_BIN:-}"

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
  ASSET_DIR="$TEST_ROOT/assets"
  LOG_DIR="$XRAY_ROOT/log"
  STATE_DIR="$XRAY_ROOT/state"
  BACKUP_DIR="$STATE_DIR/backups"
  BASE_FILE="$CONF_DIR/00_base.json"
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
  local name="$1" expected="$2" input="$3"
  reset_case "vmess-$name"
  add_vmess <<< "$input" >/dev/null
  [[ "$TRANSPORT" == "$expected" ]]
  jq -e --arg expected "$expected" \
    '.inbounds[0].streamSettings.method==$expected' \
    "$CONF_DIR/10_inbound_vmess.json" >/dev/null
  assert_config
}

test_basic_inbounds() {
  reset_case shadowsocks
  add_shadowsocks <<< $'\n\n\n\n\n\n' >/dev/null
  assert_config

  reset_case socks
  add_socks <<< $'\n\n\n\n\n\ny' >/dev/null
  assert_config

  reset_case http
  add_http <<< $'\n\n\n\n\n' >/dev/null
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

test_retry_inputs
test_reality_target_risk_detection
test_high_risk_target_can_disable_limits
test_vless_reality
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

echo "All Xray configuration smoke tests passed."
