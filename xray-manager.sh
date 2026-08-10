#!/usr/bin/env bash
# Xray Manager - interactive installer & manager
# Target: common Linux VPS distributions (systemd / Alpine OpenRC)
# Upstream: XTLS/Xray-core + XTLS/Xray-install
#
# Run:
#   chmod +x xray-manager.sh
#   sudo ./xray-manager.sh
#
# After "Install/Repair", this script can install itself as:
#   xraym

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.2.0"
PROJECT_REPOSITORY="xinian5216/xray-manager"
PROJECT_REF="${XRAY_MANAGER_REF:-main}"
PROJECT_API_BASE="https://api.github.com/repos/${PROJECT_REPOSITORY}/contents"
MANAGER_INSTALL_PATH="/usr/local/sbin/xraym"
XRAY_BIN="/usr/local/bin/xray"
XRAY_ROOT="/usr/local/etc/xray"
CONF_DIR="${XRAY_ROOT}/conf.d"
CERT_DIR="${XRAY_ROOT}/certs"
ASSET_DIR="/usr/local/share/xray"
LOG_DIR="/var/log/xray"
STATE_DIR="/etc/xray-manager"
BACKUP_DIR="${STATE_DIR}/backups"
BASE_FILE="${CONF_DIR}/00_base.json"
DOWNLOAD_PROXY_FILE="${STATE_DIR}/download_proxy"
DNS64_STATE_FILE="${STATE_DIR}/dns64.state"
DOWNLOAD_PROXY="${XRAY_DOWNLOAD_PROXY:-}"

OFFICIAL_INSTALLER="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
OFFICIAL_ALPINE_INSTALLER="https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh"
ACME_INSTALLER="https://get.acme.sh"

C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_CYAN='\033[36m'
C_BOLD='\033[1m'

info() { printf "${C_BLUE}[i]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[‚úì]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*"; }
err()  { printf "${C_RED}[x]${C_RESET} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

pause() {
  printf "\nÊåâ Enter ËøîÂõû..."
  read -r _ || true
}

confirm() {
  local prompt="${1:-Á°ÆËÆ§ÁªßÁª≠Ôºü}" ans
  read -r -p "$prompt [y/N]: " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

ask_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value || true
  printf '%s' "${value:-$default}"
}

ask_required() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt: " value || true
    [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
    warn "‰∏çËÉΩ‰∏∫Á©∫„ÄÇ"
  done
}

ask_port() {
  local prompt="${1:-Á´ØÂè£}" default="${2:-443}" value
  while true; do
    value="$(ask_default "$prompt" "$default")"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
      printf '%s' "$value"
      return 0
    fi
    warn "Á´ØÂè£ÂøÖÈ°ªÊòØ 1-65535„ÄÇ"
  done
}

sanitize_tag() {
  local t="$1"
  t="${t// /-}"
  t="$(printf '%s' "$t" | tr -cd '[:alnum:]_.-')"
  [[ -n "$t" ]] || t="inbound"
  printf '%s' "$t"
}

ask_tag() {
  local default="$1" t
  while true; do
    t="$(ask_default "ÂÖ•Á´ôÂêçÁß∞/Tag" "$default")"
    t="$(sanitize_tag "$t")"
    if ! grep -Rqs --include='*.json' "\"tag\"[[:space:]]*:[[:space:]]*\"$t\"" "$CONF_DIR" 2>/dev/null; then
      printf '%s' "$t"
      return 0
    fi
    warn "Tag '$t' Â∑≤Â≠òÂú®ÔºåËØ∑Êç¢‰∏Ä‰∏™„ÄÇ"
  done
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "ËØ∑‰ΩøÁî® root ËøêË°åÔºösudo bash $0"
  [[ -n "${BASH_VERSION:-}" ]] || die "Êú¨ËÑöÊú¨ÈúÄË¶Å Bash„ÄÇ"
}

OS_ID="unknown"
OS_LIKE=""
PKG_MGR=""
INIT_SYS=""
XRAY_RUN_GROUP=""

detect_platform() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  else
    PKG_MGR="unknown"
  fi

  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    INIT_SYS="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
  else
    INIT_SYS="unknown"
  fi

  if id nobody >/dev/null 2>&1; then
    XRAY_RUN_GROUP="$(id -gn nobody 2>/dev/null || true)"
  fi
  XRAY_RUN_GROUP="${XRAY_RUN_GROUP:-root}"
}


load_network_state() {
  if [[ -z "${DOWNLOAD_PROXY:-}" && -r "$DOWNLOAD_PROXY_FILE" ]]; then
    DOWNLOAD_PROXY="$(head -n 1 "$DOWNLOAD_PROXY_FILE" 2>/dev/null || true)"
  fi
}

run_net_command() {
  if [[ -n "${DOWNLOAD_PROXY:-}" ]]; then
    env \
      http_proxy="$DOWNLOAD_PROXY" \
      https_proxy="$DOWNLOAD_PROXY" \
      HTTP_PROXY="$DOWNLOAD_PROXY" \
      HTTPS_PROXY="$DOWNLOAD_PROXY" \
      ALL_PROXY="$DOWNLOAD_PROXY" \
      all_proxy="$DOWNLOAD_PROXY" \
      "$@"
  else
    "$@"
  fi
}

curl_net() {
  if [[ -n "${DOWNLOAD_PROXY:-}" ]]; then
    curl -x "$DOWNLOAD_PROXY" "$@"
  else
    curl "$@"
  fi
}

ensure_bootstrap_curl() {
  command -v curl >/dev/null 2>&1 && return 0

  warn "Êú™Ê£ÄÊµãÂà∞ curlÔºåÂ∞ùËØïÂÖà‰ªéÁ≥ªÁªüËΩØ‰ª∂Ê∫êÂÆâË£ÖÊúÄÂ∞è‰∏ãËΩΩÁªÑ‰ª∂„ÄÇ"
  case "$PKG_MGR" in
    apt)
      run_net_command apt-get update &&
      run_net_command env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
      ;;
    dnf) run_net_command dnf -y install curl ca-certificates ;;
    yum) run_net_command yum -y install curl ca-certificates ;;
    zypper) run_net_command zypper --non-interactive install --no-recommends curl ca-certificates ;;
    pacman) run_net_command pacman -Syy --noconfirm --needed curl ca-certificates ;;
    apk) run_net_command apk add --no-cache curl ca-certificates ;;
    *) return 1 ;;
  esac

  command -v curl >/dev/null 2>&1
}

has_global_ipv4() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -4 addr show scope global 2>/dev/null | grep -qE 'inet[[:space:]]'
}

has_global_ipv6() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -6 addr show scope global 2>/dev/null | grep -qE 'inet6[[:space:]]'
}

default_public_listen() {
  # A pure IPv6 VPS must not default to 0.0.0.0, otherwise Xray would only
  # expose an IPv4 wildcard socket that the server does not even have.
  if has_global_ipv6 && ! has_global_ipv4; then
    printf '::'
  else
    printf '0.0.0.0'
  fi
}

test_ipv4_internet() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -4 -fsS --connect-timeout 4 --max-time 8 \
    https://www.cloudflare.com/cdn-cgi/trace -o /dev/null 2>/dev/null
}

test_ipv6_internet() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -6 -fsS --connect-timeout 4 --max-time 8 \
    https://www.cloudflare.com/cdn-cgi/trace -o /dev/null 2>/dev/null
}

test_ipv4_via_default_stack() {
  command -v curl >/dev/null 2>&1 || return 1
  # ipv4.google.com is intentionally IPv4-only; on IPv6-only networks it works
  # only when DNS64 + NAT64 (or an explicit proxy) supplies translation.
  curl_net -fsS --connect-timeout 4 --max-time 10 \
    https://ipv4.google.com/ -o /dev/null 2>/dev/null
}

test_official_installer_access() {
  command -v curl >/dev/null 2>&1 || return 1
  curl_net -fsSIL --connect-timeout 5 --max-time 12 \
    "$OFFICIAL_INSTALLER" -o /dev/null 2>/dev/null
}

curl_supports_doh() {
  command -v curl >/dev/null 2>&1 || return 1
  curl --help all 2>/dev/null | grep -q -- '--doh-url'
}

test_cloudflare_dns64_nat64() {
  # This changes no system DNS. Cloudflare's DNS64 resolver synthesizes AAAA
  # records; success proves the VPS also has a working NAT64 path.
  curl_supports_doh || return 1

  local dns64
  for dns64 in "2606:4700:4700::64" "2606:4700:4700::6400"; do
    if curl -6 -fsS --connect-timeout 5 --max-time 12 \      --doh-url "https://cloudflare-dns.com/dns-query" \
      --resolve "cloudflare-dns.com:443:[$dns64]" \      https://ipv4.google.com/ -o /dev/null 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

default_ipv6_interface() {
  ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

enable_cloudflare_dns64() {
  mkdir -p "$STATE_DIR"

  if [[ -s "$DNS64_STATE_FILE" ]]; then
    warn "Ê£ÄÊµãÂà∞ËÑöÊú¨‰ª•ÂâçÂ∑≤ÁªèÂøÜÊîπËøáƒNS64„ÄÇ"
    return 0
  fi

  if ! test_cloudflare_dns64_nat64; then
    err "Cloudflare DNS64 ÊµãËØïÂ§±Ë¥•ÔºöÊ≤°ÊúâÁ°ÆËÆ§Âà∞ÂèØÁî® NAT64„ÄÇ"
    warn "DNS64 Âè™ËÉΩË¥üË¥¶ÊéàÊàêÂÆåÂêàÊàêÊï∞ÔºõÂ¶ÇÊûú VPS Êèê‰æõÂïÜÊöÀÊúâÊúâËµ∑ NAT64 ÁΩëÂÖ≥ÔºåÊîπ DNS ‰πüÊó†Ê≥ïËÆøÈóÆ IPv4.0
    return 1
  fi

  local iface target backup ts
  ts="$(date +%Y%m%d-%H%M-S©Là((ÄÅ•òÅçΩµµÖπêÄµÿÅ…ïÕΩ±Ÿïç—∞Ä¯ΩëïÿΩπ’±∞Ä»¯òƒÄòòÅp(ÄÄÄÄÅmlÄàë%9%Q}MeLàÄÙÙÄâÕÂÕ—ïµêàÅutÄòòÅp(ÄÄÄÄÅÕÂÕ—ïµç—∞Å•ÃµÖç—•ŸîÄ¥µ≈’•ï–ÅÕÂÕ—ïµêµ…ïÕΩ±ŸïêÄ»¯ΩëïÿΩπ’±∞ÏÅ—°ï∏(ÄÄÄÅ•ôÖçîÙàê°ëïôÖ’±—}•¡ÿŸ}•π—ï…ôÖçî§à(ÄÄÄÅmlÄµ∏Äàë•ôÖçîàÅutÅÒÅÏ(ÄÄÄÄÄÅï…»Äãö^ÉöŒW¢æñ"Øö?¶^dÅ%AÿÿÉûˆGñ6ä8" ¢&WGW&‚¢–†¢&W6ˆ«fV7F¬FÁ2"Fñf6R"#cc£Cs£Cs££cB#cc£Cs£Cs££cC ¢&W6ˆ«fV7F¬Fˆ÷ñ‚"Fñf6R"w‚‚p¢&W6ˆ«fV7F¬f«W6Ç÷66ÜW2#‚ˆFWbˆÁV∆¬«¬G'VP¢&ñÁFbw&W6ˆ«fVG¬W5∆‚r"Fñf6R"‚"DDÂ3cEı5DDUÙdîƒR ¢V«6P¢F&vWC“"Bá&VF∆ñÊ≤÷bˆWF2˜&W6ˆ«bÊ6ˆÊb#‚ˆFWbˆÁV∆¬«¬&ñÁFbrˆWF2˜&W6ˆ«bÊ6ˆÊbrí ¢µ≤÷b"GF&vWB"«¬÷R"GF&vWB"’“«¬F&vWC“"ˆWF2˜&W6ˆ«bÊ6ˆÊb †¢&6∑W“"Gµ5DDUÙDï'“˜&W6ˆ«bÊ6ˆÊbÊ&Vf˜&R÷FÁ3cB‚G∑G7“ ¢7‘¬"GF&vWB""F&6∑W"#‚ˆFWbˆÁV∆¬«¬7"GF&vWB""F&6∑W"#‚ˆFWbˆÁV∆¬«¬∞¢W'".izk9^ZH~Kª“GF&vWN8""
      return 1
    }

    cat >"$target" <<'EOF'
# Managed by xray-manager: Cloudflare DNS64
nameserver 2606:4700:4700::64
nameserver 2606:4700:4700::6400
options timeout:2 attempts:3
EOF
    printf 'file|%s%%s\n' "$target" "$backup" >"$DNS64_STATE_FILE"
  fi

  chmod 600 "$DNS64_STATE_FILE" 2>/dev/null || true

  if test_ipv4_via_default_stack; then
    ok "Cloudflare DNS64 Â∑≤ÂêØÁî®ÔºåNAT64 ËÆøÈóÆ IPv4 ÊµãËØïÈÄöËøá„ÄÇ"
    return 0
  fi

  err "DNS64 Â∑≤ÂÜôÂÖ•Ôºå‰ΩÜ IPv4-over-IPv6 ÊµãËØï‰ªçÂ§±Ë¥•ÔºåËá™Âä®ÊÅ¢Â§çÂéü DNS„ÄÇ"
  restore_dns64 >/dev/null 2>&1 || true
  return 1
}

restore_dns64() {
  [[ -s "$DNS64_STATE_FILE" ]] || {
    warn "Ê®yß"zèñ‘∫‚∑≠∫πÙñáñjy¶»