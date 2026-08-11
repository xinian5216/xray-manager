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
umask 027

SCRIPT_VERSION="1.4.2"
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
MANAGER_UPDATE_SOURCE_FILE="${XRAY_MANAGER_UPDATE_SOURCE_FILE:-${STATE_DIR}/manager_update_source}"
CLOUDFLARE_URL_FILE="${XRAY_MANAGER_CLOUDFLARE_URL_FILE:-${STATE_DIR}/cloudflare_url}"
CLOUDFLARE_BASE_DEFAULT="https://xray-manager-download.xinian5216.workers.dev"
CLOUDFLARE_BASE="${XRAY_MANAGER_CLOUDFLARE_URL:-}"
UPDATE_SOURCE="${XRAY_MANAGER_UPDATE_SOURCE:-}"
CONFIG_MIGRATION_STATE_FILE="${XRAY_MANAGER_CONFIG_MIGRATION_STATE_FILE:-${STATE_DIR}/config_migration.state}"
SYSTEMD_MANAGER_DROPIN="${XRAY_MANAGER_SYSTEMD_DROPIN:-/etc/systemd/system/xray.service.d/20-xray-manager-offline.conf}"

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

info() { printf "${C_BLUE}[i]${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "${C_GREEN}[✓]${C_RESET} %s\n" "$*" >&2; }
warn() { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*" >&2; }
err()  { printf "${C_RED}[x]${C_RESET} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

pause() {
  printf "\n按 Enter 返回..."
  read -r _ || true
}

confirm() {
  local prompt="${1:-确认继续？}" ans
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
    warn "不能为空。"
  done
}

ask_port() {
  local prompt="${1:-端口}" default="${2:-443}" value
  while true; do
    value="$(ask_default "$prompt" "$default")"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
      printf '%s' "$value"
      return 0
    fi
    warn "端口必须是 1-65535。"
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
    t="$(ask_default "入站名称/Tag" "$default")"
    t="$(sanitize_tag "$t")"
    if ! grep -Rqs --include='*.json' "\"tag\"[[:space:]]*:[[:space:]]*\"$t\"" "$CONF_DIR" 2>/dev/null; then
      printf '%s' "$t"
      return 0
    fi
    warn "Tag '$t' 已存在，请换一个。"
  done
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
  [[ -n "${BASH_VERSION:-}" ]] || die "本脚本需要 Bash。"
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

  if [[ -z "${UPDATE_SOURCE:-}" && -r "$MANAGER_UPDATE_SOURCE_FILE" ]]; then
    UPDATE_SOURCE="$(tr -d '[:space:]' <"$MANAGER_UPDATE_SOURCE_FILE" 2>/dev/null || true)"
  fi
  if [[ -z "${CLOUDFLARE_BASE:-}" && -r "$CLOUDFLARE_URL_FILE" ]]; then
    CLOUDFLARE_BASE="$(tr -d '[:space:]' <"$CLOUDFLARE_URL_FILE" 2>/dev/null || true)"
  fi
  CLOUDFLARE_BASE="${CLOUDFLARE_BASE:-$CLOUDFLARE_BASE_DEFAULT}"
}

uses_cloudflare_distribution() {
  load_network_state
  [[ "${UPDATE_SOURCE:-}" == "cloudflare" ]]
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

  warn "未检测到 curl，尝试先从系统软件源安装最小下载组件。"
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
    if curl -6 -fsS --connect-timeout 5 --max-time 12 \
      --doh-url "https://cloudflare-dns.com/dns-query" \
      --resolve "cloudflare-dns.com:443:[$dns64]" \
      https://ipv4.google.com/ -o /dev/null 2>/dev/null; then
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
    warn "检测到脚本以前已经修改过 DNS64。"
    return 0
  fi

  if ! test_cloudflare_dns64_nat64; then
    err "Cloudflare DNS64 测试失败：没有确认到可用 NAT64。"
    warn "DNS64 只能负责合成 AAAA；如果 VPS 提供商没有 NAT64 网关，改 DNS 也无法访问 IPv4。"
    return 1
  fi

  local iface target backup ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if command -v resolvectl >/dev/null 2>&1 && \
     [[ "$INIT_SYS" == "systemd" ]] && \
     systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    iface="$(default_ipv6_interface)"
    [[ -n "$iface" ]] || {
      err "无法识别默认 IPv6 网卡。"
      return 1
    }

    resolvectl dns "$iface" 2606:4700:4700::64 2606:4700:4700::6400
    resolvectl domain "$iface" '~.'
    resolvectl flush-caches 2>/dev/null || true
    printf 'resolved|%s\n' "$iface" >"$DNS64_STATE_FILE"
  else
    target="$(readlink -f /etc/resolv.conf 2>/dev/null || printf '/etc/resolv.conf')"
    [[ -f "$target" || -e "$target" ]] || target="/etc/resolv.conf"

    backup="${STATE_DIR}/resolv.conf.before-dns64.${ts}"
    cp -L "$target" "$backup" 2>/dev/null || cp "$target" "$backup" 2>/dev/null || {
      err "无法备份 $target。"
      return 1
    }

    cat >"$target" <<'EOF'
# Managed by xray-manager: Cloudflare DNS64
nameserver 2606:4700:4700::64
nameserver 2606:4700:4700::6400
options timeout:2 attempts:3
EOF
    printf 'file|%s|%s\n' "$target" "$backup" >"$DNS64_STATE_FILE"
  fi

  chmod 600 "$DNS64_STATE_FILE" 2>/dev/null || true

  if test_ipv4_via_default_stack; then
    ok "Cloudflare DNS64 已启用，NAT64 访问 IPv4 测试通过。"
    return 0
  fi

  err "DNS64 已写入，但 IPv4-over-IPv6 测试仍失败，自动恢复原 DNS。"
  restore_dns64 >/dev/null 2>&1 || true
  return 1
}

restore_dns64() {
  [[ -s "$DNS64_STATE_FILE" ]] || {
    warn "没有找到由本脚本保存的 DNS64 修改记录。"
    return 0
  }

  local mode a b
  IFS='|' read -r mode a b <"$DNS64_STATE_FILE"

  case "$mode" in
    resolved)
      if command -v resolvectl >/dev/null 2>&1; then
        resolvectl revert "$a" || true
        resolvectl flush-caches 2>/dev/null || true
      fi
      ;;
    file)
      if [[ -n "${b:-}" && -f "$b" ]]; then
        cp "$b" "$a"
      else
        err "DNS 备份文件不存在：${b:-未知}"
        return 1
      fi
      ;;
    *)
      err "未知 DNS64 状态格式。"
      return 1
      ;;
  esac

  rm -f "$DNS64_STATE_FILE"
  ok "已恢复脚本修改前的 DNS 设置。"
}

set_download_proxy() {
  local proxy
  echo >&2
  echo "支持示例："
  echo "  http://[IPv6地址]:端口"
  echo "  http://user:pass@[IPv6地址]:端口"
  echo "  socks5h://[IPv6地址]:端口"
  echo "  socks5h://域名:端口"
  proxy="$(ask_required "输入 IPv6 可达的 HTTP/SOCKS5 代理 URL")"

  DOWNLOAD_PROXY="$proxy"
  if ! curl_net -fsSIL --connect-timeout 6 --max-time 15 \
       "$OFFICIAL_INSTALLER" -o /dev/null 2>/dev/null; then
    err "通过这个代理仍无法访问 XTLS 官方安装脚本。"
    DOWNLOAD_PROXY=""
    return 1
  fi

  ok "代理测试通过。"
  if confirm "保存这个下载代理供以后更新 Xray/GeoData 使用？"; then
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$DOWNLOAD_PROXY" >"$DOWNLOAD_PROXY_FILE"
    chmod 600 "$DOWNLOAD_PROXY_FILE"
    warn "代理 URL 会以 root-only 文件保存；若 URL 内含密码，它也会被保存。"
  fi
}

clear_download_proxy() {
  DOWNLOAD_PROXY=""
  rm -f "$DOWNLOAD_PROXY_FILE"
  ok "已清除下载代理。"
}

network_stack_label() {
  local v4net="失败" v6net="失败"
  test_ipv4_internet && v4net="正常"
  test_ipv6_internet && v6net="正常"

  if [[ "$v6net" == "正常" && "$v4net" != "正常" ]]; then
    printf 'IPv6-only'
  elif [[ "$v6net" == "正常" && "$v4net" == "正常" ]]; then
    printf '双栈'
  elif [[ "$v4net" == "正常" ]]; then
    printf 'IPv4-only'
  else
    printf '网络异常/未确认'
  fi
}

network_report() {
  echo "========== 网络栈诊断 =========="
  echo "网络类型       : $(network_stack_label)"
  echo "全局 IPv4 地址 :"
  ip -4 -br addr show scope global 2>/dev/null || true
  echo "全局 IPv6 地址 :"
  ip -6 -br addr show scope global 2>/dev/null || true
  echo "IPv4 互联网    : $(test_ipv4_internet && echo 正常 || echo 失败)"
  echo "IPv6 互联网    : $(test_ipv6_internet && echo 正常 || echo 失败)"
  echo "IPv4-only 站点 : $(test_ipv4_via_default_stack && echo 可达 || echo 不可达)"
  echo "GitHub/XTLS    : $(test_official_installer_access && echo 可达 || echo 不可达)"
  echo "DNS64 状态     : $([[ -s "$DNS64_STATE_FILE" ]] && echo 已由脚本启用 || echo 未由脚本启用)"
  echo "下载代理       : $([[ -n "${DOWNLOAD_PROXY:-}" ]] && echo 已设置 || echo 未设置)"
  echo "公网入站默认监听: $(default_public_listen)"
  echo
  echo "IPv6 默认路由："
  ip -6 route show default 2>/dev/null || true
}

prepare_download_network() {
  ensure_bootstrap_curl || {
    err "缺少 curl，且系统软件源无法自动安装它。"
    warn "如果这是纯 IPv6 VPS，先确认发行版软件源本身能够通过 IPv6 访问。"
    return 1
  }

  load_network_state

  # If the configured proxy already makes the official source reachable, use it.
  if [[ -n "${DOWNLOAD_PROXY:-}" ]] && test_official_installer_access; then
    info "将使用已配置的下载代理。"
    return 0
  fi

  # Normal dual-stack / IPv4 / directly reachable IPv6 path.
  if test_official_installer_access; then
    return 0
  fi

  if test_ipv6_internet && ! test_ipv4_internet; then
    warn "检测到 IPv6-only VPS，且当前无法直接获取 XTLS/GitHub 资源。"

    # Provider may already expose NAT64 but its current resolver lacks DNS64.
    if test_cloudflare_dns64_nat64; then
      info "检测到 VPS 底层存在可用 NAT64；Cloudflare DNS64 测试通过。"
      if confirm "启用 Cloudflare DNS64，让安装器和软件源访问 IPv4-only 资源？"; then
        enable_cloudflare_dns64 || true
        if test_official_installer_access; then
          return 0
        fi
      fi
    else
      warn "没有检测到可用 NAT64，单纯修改 DNS 无法解决。"
    fi

    echo
    warn "这台机器当前没有一条可确认的 IPv4 出口。"
    echo '可以给脚本一个“IPv6 本身可访问、且能代你访问 IPv4”的 HTTP/SOCKS5 代理。'
    if confirm "现在设置下载代理？"; then
      set_download_proxy && return 0
    fi

    err "无法建立 Xray 安装所需的下载链路。"
    warn "这不是 Xray 的 IPv6 限制，而是 IPv6-only 主机访问 IPv4-only 上游资源时缺少 NAT64/代理。"
    return 1
  fi

  err "当前无法访问 XTLS 官方安装源，请检查 DNS、路由、出口防火墙或设置下载代理。"
  if confirm "现在设置下载代理？"; then
    set_download_proxy && return 0
  fi
  return 1
}

ipv6_only_menu() {
  while true; do
    clear || true
    echo "========== IPv6-only / NAT64 网络助手 =========="
    echo "1) 网络栈完整诊断"
    echo "2) 自动准备 Xray 下载网络"
    echo "3) 测试 NAT64 + Cloudflare DNS64"
    echo "4) 启用 Cloudflare DNS64"
    echo "5) 恢复修改前 DNS"
    echo "6) 设置 Xray/GitHub 下载代理"
    echo "7) 清除下载代理"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) network_report; pause ;;
      2)
        if prepare_download_network; then
          ok "下载网络准备完成。"
        fi
        pause
        ;;
      3)
        if test_cloudflare_dns64_nat64; then
          ok "测试通过：Cloudflare DNS64 + 这台 VPS 的 NAT64 可以共同访问 IPv4-only 目标。"
        else
          err "测试失败：未确认到可用 NAT64，或者本机 curl 不支持 DoH。"
        fi
        pause
        ;;
      4) enable_cloudflare_dns64; pause ;;
      5) restore_dns64; pause ;;
      6) set_download_proxy; pause ;;
      7) clear_download_proxy; pause ;;
      0) return ;;
    esac
  done
}

pkg_install_base() {
  info "安装/检查基础依赖..."
  case "$PKG_MGR" in
    apt)
      run_net_command apt-get update
      run_net_command env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates jq openssl unzip iproute2 procps tar gzip
      ;;
    dnf)
      run_net_command dnf -y install curl ca-certificates jq openssl unzip iproute procps-ng tar gzip
      ;;
    yum)
      run_net_command yum -y install curl ca-certificates jq openssl unzip iproute procps-ng tar gzip
      ;;
    zypper)
      run_net_command zypper --non-interactive install --no-recommends curl ca-certificates jq openssl unzip iproute2 procps tar gzip
      ;;
    pacman)
      run_net_command pacman -Syy --noconfirm --needed curl ca-certificates jq openssl unzip iproute2 procps-ng tar gzip
      ;;
    apk)
      run_net_command apk add --no-cache bash curl ca-certificates jq openssl unzip iproute2 procps coreutils tar gzip
      ;;
    *)
      die "无法识别包管理器，请先手动安装 curl jq openssl unzip iproute2/procps。"
      ;;
  esac
}

pkg_install_optional() {
  local pkg="$1"
  case "$PKG_MGR" in
    apt) run_net_command env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" ;;
    dnf) run_net_command dnf -y install "$pkg" ;;
    yum) run_net_command yum -y install "$pkg" ;;
    zypper) run_net_command zypper --non-interactive install "$pkg" ;;
    pacman) run_net_command pacman -S --noconfirm --needed "$pkg" ;;
    apk) run_net_command apk add --no-cache "$pkg" ;;
    *) return 1 ;;
  esac
}

ensure_layout() {
  mkdir -p "$CONF_DIR" "$CERT_DIR" "$ASSET_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR"
  chown root:root "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  chmod 700 "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true

  if [[ ! -f "$BASE_FILE" ]]; then
    cat >"$BASE_FILE" <<'JSON'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
JSON
  fi

  touch "$LOG_DIR/access.log" "$LOG_DIR/error.log"

  if id nobody >/dev/null 2>&1; then
    chown nobody:"$XRAY_RUN_GROUP" "$LOG_DIR/access.log" "$LOG_DIR/error.log" 2>/dev/null || true
    chmod 600 "$LOG_DIR/access.log" "$LOG_DIR/error.log" 2>/dev/null || true
    chown root:"$XRAY_RUN_GROUP" "$XRAY_ROOT" "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
    chmod 750 "$XRAY_ROOT" "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
    find "$CONF_DIR" -maxdepth 1 -type f -name '*.json' -exec chown root:"$XRAY_RUN_GROUP" {} \; -exec chmod 640 {} \; 2>/dev/null || true
  else
    chmod 700 "$CERT_DIR" 2>/dev/null || true
    chmod 750 "$CONF_DIR" 2>/dev/null || true
  fi
}

install_manager_command() {
  local self
  self="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if [[ -f "$self" ]]; then
    install -d -m 755 "$(dirname "${XRAY_MANAGER_CORE_INSTALL_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}")"
    install -m 755 "$self" "${XRAY_MANAGER_CORE_INSTALL_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}"
    ok "管理核心已安装：${XRAY_MANAGER_CORE_INSTALL_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}"
  fi
}

download_to_tmp() {
  local url="$1" out="$2"
  curl_net -fL --retry 4 --connect-timeout 12 --max-time 180 -o "$out" "$url"
}

get_cloudflare_install_token() {
  local token="${XRAY_MANAGER_INSTALL_TOKEN:-}"
  if [[ -z "$token" && -r /dev/tty ]]; then
    printf "Cloudflare 安装密钥: " >/dev/tty
    IFS= read -r -s token </dev/tty || true
    printf "\n" >/dev/tty
  fi
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

cloudflare_distribution_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *)
      err "Cloudflare 分发暂不支持当前架构：$(uname -m)"
      return 1
      ;;
  esac
}

cloudflare_download_payload() {
  local target="$1" token arch package checksum config expected actual listing

  ensure_bootstrap_curl || {
    err "缺少 curl，无法访问 Cloudflare 分发。"
    return 1
  }
  command -v tar >/dev/null 2>&1 || {
    err "缺少 tar，无法解压 Cloudflare 离线包。"
    return 1
  }

  load_network_state
  arch="$(cloudflare_distribution_arch)" || return 1
  token="$(get_cloudflare_install_token)" || {
    err "没有 Cloudflare 安装密钥。"
    return 1
  }

  package="latest-${arch}.tar.gz"
  checksum="latest-${arch}.sha256"
  mkdir -p "$target/download" "$target/extracted"
  config="$target/download/curl.conf"

  printf '%s\n' \
    "header = \"Authorization: Bearer ${token}\"" \
    "fail" \
    "silent" \
    "show-error" \
    "location" \
    "connect-timeout = 15" \
    "max-time = 300" \
    "retry = 3" >"$config"
  chmod 600 "$config"
  unset token XRAY_MANAGER_INSTALL_TOKEN 2>/dev/null || true

  info "从 Cloudflare 私有 R2 分发获取 Xray + GeoData..."
  curl --config "$config" \
    "$CLOUDFLARE_BASE/releases/$package" \
    -o "$target/download/$package" || return 1
  curl --config "$config" \
    "$CLOUDFLARE_BASE/releases/$checksum" \
    -o "$target/download/$checksum" || return 1

  expected="$(tr -d '[:space:]' <"$target/download/$checksum")"
  actual="$(offline_sha256_file "$target/download/$package")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ && "$expected" == "$actual" ]] || {
    err "Cloudflare 离线包 SHA256 校验失败。"
    return 1
  }

  listing="$(tar -tzf "$target/download/$package")" || {
    err "Cloudflare 离线包无法读取。"
    return 1
  }
  if grep -Eq '(^/|(^|/)\.\.(/|$))' <<<"$listing"; then
    err "Cloudflare 离线包包含不安全路径，拒绝解压。"
    return 1
  fi
  tar -xzf "$target/download/$package" -C "$target/extracted"

  case "$arch" in
    amd64) CLOUDFLARE_XRAY_ZIP="$target/extracted/payload/Xray-linux-64.zip" ;;
    arm64) CLOUDFLARE_XRAY_ZIP="$target/extracted/payload/Xray-linux-arm64-v8a.zip" ;;
  esac
  CLOUDFLARE_GEOIP="$target/extracted/payload/geoip.dat"
  CLOUDFLARE_GEOSITE="$target/extracted/payload/geosite.dat"

  offline_validate_file "$CLOUDFLARE_XRAY_ZIP" "Cloudflare Xray 压缩包" 1024 || return 1
  offline_validate_file "$CLOUDFLARE_GEOIP" "Cloudflare GeoIP" 1024 || return 1
  offline_validate_file "$CLOUDFLARE_GEOSITE" "Cloudflare GeoSite" 1024 || return 1
}

cloudflare_install_or_update_xray() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  if cloudflare_download_payload "$tmp"; then
    offline_import_xray \
      "$CLOUDFLARE_XRAY_ZIP" \
      "$CLOUDFLARE_GEOIP" \
      "$CLOUDFLARE_GEOSITE" || rc=$?
  else
    rc=$?
  fi
  rm -rf "$tmp"
  return "$rc"
}

run_systemd_installer() {
  local script="$1" action="$2"
  local args=("$action")
  if [[ -n "${DOWNLOAD_PROXY:-}" ]]; then
    args+=("-p" "$DOWNLOAD_PROXY")
    env \
      JSONS_PATH="$CONF_DIR" \
      http_proxy="$DOWNLOAD_PROXY" https_proxy="$DOWNLOAD_PROXY" \
      HTTP_PROXY="$DOWNLOAD_PROXY" HTTPS_PROXY="$DOWNLOAD_PROXY" \
      ALL_PROXY="$DOWNLOAD_PROXY" all_proxy="$DOWNLOAD_PROXY" \
      bash "$script" "${args[@]}"
  else
    env JSONS_PATH="$CONF_DIR" bash "$script" "${args[@]}"
  fi
}

run_alpine_installer() {
  local script="$1"
  run_net_command ash "$script"
}

configure_openrc_confdir() {
  mkdir -p /etc/conf.d
  cat >/etc/conf.d/xray <<EOF
# Managed by xray-manager
confdir="$CONF_DIR/"
env="XRAY_LOCATION_ASSET=$ASSET_DIR/"
EOF
  rc-update add xray default >/dev/null 2>&1 || rc-update add xray >/dev/null 2>&1 || true
}

offline_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    printf 'unavailable'
  fi
}

offline_extract_xray() {
  local archive="$1" out="$2"
  rm -f "$out"

  if command -v unzip >/dev/null 2>&1; then
    unzip -p "$archive" xray >"$out" 2>/dev/null ||
      unzip -p "$archive" ./xray >"$out" 2>/dev/null || true
  elif command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xOf "$archive" xray >"$out" 2>/dev/null ||
      bsdtar -xOf "$archive" ./xray >"$out" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" "$out" <<'PY'
import sys
import zipfile

archive, output = sys.argv[1:]
with zipfile.ZipFile(archive) as package:
    names = package.namelist()
    member = "xray" if "xray" in names else "./xray" if "./xray" in names else None
    if member is None:
        raise SystemExit("Xray archive does not contain a root xray executable")
    with package.open(member) as source, open(output, "wb") as target:
        target.write(source.read())
PY
  else
    err "离线解压需要 unzip、bsdtar 或 python3，当前系统均未安装。"
    return 1
  fi

  [[ -s "$out" ]] || {
    err "Xray 压缩包中没有找到根目录下的 xray 可执行文件。"
    return 1
  }
  chmod 755 "$out"
}

offline_validate_file() {
  local file="$1" label="$2" minimum="${3:-1024}" size
  [[ -f "$file" && -r "$file" ]] || {
    err "$label 不存在或不可读：$file"
    return 1
  }
  size="$(wc -c <"$file" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  (( size >= minimum )) || {
    err "$label 文件异常小（${size} bytes）：$file"
    return 1
  }
}

extract_xray_config_source() {
  local command_line="$1" token expect=""
  local -a tokens=()
  local IFS=' '

  command_line="${command_line//;/ }"
  command_line="${command_line//\{/ }"
  command_line="${command_line//\}/ }"
  read -r -a tokens <<<"$command_line"

  for token in "${tokens[@]}"; do
    token="${token//\"/}"
    token="${token//\'/}"
    if [[ -n "$expect" ]]; then
      printf '%s\t%s' "$expect" "$token"
      return 0
    fi
    case "$token" in
      -config|-c) expect="file" ;;
      -confdir) expect="dir" ;;
      -config=*|-c=*) printf 'file\t%s' "${token#*=}"; return 0 ;;
      -confdir=*) printf 'dir\t%s' "${token#*=}"; return 0 ;;
    esac
  done
  return 1
}

discover_existing_xray_config() {
  local discovered="" kind="" path="" command_line=""

  if [[ -n "${XRAY_MANAGER_LEGACY_CONFIG:-}" ]]; then
    path="${XRAY_MANAGER_LEGACY_CONFIG%/}"
    if [[ -f "$path" &&
          "$path" != "${CONF_DIR%/}/"* ]]; then
      printf 'file\t%s' "$path"
      return 0
    elif [[ -d "$path" &&
            "$path" != "${CONF_DIR%/}" &&
            "$path" != "${CONF_DIR%/}/"* ]]; then
      printf 'dir\t%s' "$path"
      return 0
    fi
    err "指定的旧配置不存在：$path"
    return 1
  fi

  if [[ "$INIT_SYS" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
    command_line="$(systemctl show xray -p ExecStart --value 2>/dev/null || true)"
    discovered="$(extract_xray_config_source "$command_line" 2>/dev/null || true)"
    if [[ -n "$discovered" ]]; then
      IFS=$'\t' read -r kind path <<<"$discovered"
      path="${path%/}"
      if [[ "$path" != "${CONF_DIR%/}" &&
            "$path" != "${CONF_DIR%/}/"* ]]; then
        if [[ "$kind" == "file" && -f "$path" ]] ||
           [[ "$kind" == "dir" && -d "$path" ]]; then
          printf '%s\t%s' "$kind" "$path"
          return 0
        fi
      fi
    fi
  elif [[ "$INIT_SYS" == "openrc" ]]; then
    for path in /etc/conf.d/xray /etc/init.d/xray; do
      [[ -r "$path" ]] || continue
      command_line="$(tr '\n' ' ' <"$path")"
      discovered="$(extract_xray_config_source "$command_line" 2>/dev/null || true)"
      [[ -n "$discovered" ]] || continue
      IFS=$'\t' read -r kind path <<<"$discovered"
      path="${path%/}"
      if [[ "$path" != "${CONF_DIR%/}" &&
            "$path" != "${CONF_DIR%/}/"* ]] &&
         { [[ "$kind" == "file" && -f "$path" ]] ||
           [[ "$kind" == "dir" && -d "$path" ]]; }; then
        printf '%s\t%s' "$kind" "$path"
        return 0
      fi
    done
  fi

  # v1.4.0 may already have installed this drop-in and hidden the old
  # config.json. Recover that legacy config instead of treating conf.d as the
  # original source.
  if [[ -f "$SYSTEMD_MANAGER_DROPIN" && ! -s "$CONFIG_MIGRATION_STATE_FILE" ]]; then
    for path in "$XRAY_ROOT/config.json" /etc/xray/config.json; do
      if [[ -f "$path" ]]; then
        printf 'file\t%s' "$path"
        return 0
      fi
    done
  fi

  # Fallback for standard XTLS installations when service metadata is absent.
  for path in "$XRAY_ROOT/config.json" /etc/xray/config.json; do
    if [[ -f "$path" && "$path" != "$BASE_FILE" ]]; then
      printf 'file\t%s' "$path"
      return 0
    fi
  done
  return 1
}

backup_xray_service_state() {
  local backup="$1"
  if [[ "$INIT_SYS" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl cat xray >"$backup/xray.service.txt" 2>/dev/null || true
    systemctl show xray -p ExecStart -p FragmentPath -p DropInPaths \
      >"$backup/xray.service-state.txt" 2>/dev/null || true
    systemctl is-enabled xray >"$backup/xray.service-enabled.txt" 2>/dev/null || true
    systemctl is-active xray >"$backup/xray.service-active.txt" 2>/dev/null || true

    if [[ -f /etc/systemd/system/xray.service ]]; then
      cp -a /etc/systemd/system/xray.service "$backup/xray.service" || true
    fi
    if [[ -d /etc/systemd/system/xray.service.d ]]; then
      cp -a /etc/systemd/system/xray.service.d "$backup/xray.service.d" || true
    fi
    if [[ -f /usr/lib/systemd/system/xray.service ]]; then
      cp -a /usr/lib/systemd/system/xray.service "$backup/xray.service.usr-lib" || true
    fi
    if [[ -f /lib/systemd/system/xray.service ]]; then
      cp -a /lib/systemd/system/xray.service "$backup/xray.service.lib" || true
    fi
  elif [[ "$INIT_SYS" == "openrc" ]]; then
    if [[ -f /etc/init.d/xray ]]; then
      cp -a /etc/init.d/xray "$backup/xray.init" || true
    fi
    if [[ -f /etc/conf.d/xray ]]; then
      cp -a /etc/conf.d/xray "$backup/xray.conf" || true
    fi
  fi
}

migrate_existing_xray_config() {
  local kind="$1" source="$2"
  local stamp backup stage previous first_json

  source="${source%/}"
  echo
  warn "检测到脚本接管前的 Xray 配置：$source"
  echo "迁移目标：$CONF_DIR"
  echo "原配置只会复制，不会删除；当前目标目录和服务状态会先完整备份。"
  echo
  confirm "第一次确认：将现有 Xray 配置迁移给 Xray Manager 管理？" || {
    warn "已取消安装/修复，未修改配置和服务。"
    return 1
  }
  confirm "第二次确认：允许备份后替换 $CONF_DIR 的现有内容？" || {
    warn "已取消安装/修复，未修改配置和服务。"
    return 1
  }

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_DIR/pre-migration-$stamp"
  stage="$XRAY_ROOT/.conf.d.migration-$stamp"
  previous="$XRAY_ROOT/conf.d.before-migration-$stamp"
  mkdir -p "$BACKUP_DIR" "$XRAY_ROOT" "$backup" "$stage"
  chmod 700 "$BACKUP_DIR" "$backup"

  if [[ -d "$CONF_DIR" ]]; then
    cp -a "$CONF_DIR" "$backup/manager-conf-before" || {
      err "无法备份当前 Manager 配置，已中止。"
      rm -rf "$stage"
      return 1
    }
  fi
  backup_xray_service_state "$backup"
  if [[ -f "$XRAY_BIN" ]]; then
    cp -a "$XRAY_BIN" "$backup/xray" || true
  fi

  if [[ "$kind" == "file" ]]; then
    if ! cp -a "$source" "$backup/legacy-config.json" ||
       ! install -m 640 "$source" "$stage/00_base.json"; then
      err "复制旧配置失败，已中止。"
      rm -rf "$stage"
      return 1
    fi
  else
    if ! cp -a "$source" "$backup/legacy-confdir" ||
       ! cp -a "$source"/. "$stage"/; then
      err "复制旧配置目录失败，已中止。"
      rm -rf "$stage"
      return 1
    fi
    if [[ ! -f "$stage/00_base.json" ]]; then
      first_json="$(find "$stage" -maxdepth 1 \( -type f -o -type l \) -name '*.json' -print |
        LC_ALL=C sort | head -n 1)"
      [[ -n "$first_json" ]] || {
        err "旧配置目录中没有 JSON 文件，已中止。"
        rm -rf "$stage"
        return 1
      }
      # Keep every legacy filename and its merge order intact.  This empty
      # base prevents ensure_layout from injecting a second default outbound.
      printf '{}\n' >"$stage/00_base.json"
    fi
  fi

  if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" \
       run -confdir "$stage" -test >/dev/null 2>&1; then
    err "迁移后的配置测试失败，未覆盖 Manager 配置。"
    warn "原配置仍在：$source"
    warn "诊断备份位于：$backup"
    rm -rf "$stage"
    return 1
  fi

  if [[ -e "$CONF_DIR" ]]; then
    mv "$CONF_DIR" "$previous" || {
      err "无法暂存当前 Manager 配置，已中止。"
      rm -rf "$stage"
      return 1
    }
  fi
  if ! mv "$stage" "$CONF_DIR"; then
    err "写入迁移配置失败，正在恢复。"
    if [[ -e "$previous" ]]; then
      mv "$previous" "$CONF_DIR" || true
    fi
    return 1
  fi

  mkdir -p "$STATE_DIR"
  {
    printf 'source=%s\n' "$source"
    printf 'backup=%s\n' "$backup"
    printf 'previous_manager_conf=%s\n' "$previous"
    printf 'migrated_at=%s\n' "$stamp"
  } >"$CONFIG_MIGRATION_STATE_FILE"
  chmod 600 "$CONFIG_MIGRATION_STATE_FILE"

  ensure_layout
  ok "已有 Xray 配置已迁移并通过测试。"
  echo "配置来源：$source"
  echo "完整备份：$backup"
  [[ -e "$previous" ]] && echo "原 Manager 目录：$previous"
}

prepare_existing_xray_config() {
  local discovered kind source
  xray_exists || return 0
  [[ -s "$CONFIG_MIGRATION_STATE_FILE" ]] && return 0

  discovered="$(discover_existing_xray_config || true)"
  [[ -n "$discovered" ]] || return 0
  IFS=$'\t' read -r kind source <<<"$discovered"
  [[ -n "$kind" && -n "$source" ]] || return 0
  migrate_existing_xray_config "$kind" "$source"
}

configure_systemd_offline_service() {
  local unit="/etc/systemd/system/xray.service"
  local dropin="/etc/systemd/system/xray.service.d/20-xray-manager-offline.conf"
  local service_user="root"
  if id nobody >/dev/null 2>&1; then
    service_user="nobody"
  fi

  if [[ ! -f "$unit" && ! -f /usr/lib/systemd/system/xray.service && ! -f /lib/systemd/system/xray.service ]]; then
    cat >"$unit" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=$service_user
Group=$XRAY_RUN_GROUP
Environment=XRAY_LOCATION_ASSET=$ASSET_DIR
ExecStart=$XRAY_BIN run -confdir $CONF_DIR
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  else
    mkdir -p "$(dirname "$dropin")"
    cat >"$dropin" <<EOF
[Service]
Environment=XRAY_LOCATION_ASSET=$ASSET_DIR
ExecStart=
ExecStart=$XRAY_BIN run -confdir $CONF_DIR
EOF
  fi

  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
}

configure_openrc_offline_service() {
  local service_user="root"
  if id nobody >/dev/null 2>&1; then
    service_user="nobody"
  fi
  if [[ ! -f /etc/init.d/xray ]]; then
    cat >/etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="$XRAY_BIN"
command_args="run -confdir $CONF_DIR"
command_user="$service_user:$XRAY_RUN_GROUP"
command_background="yes"
pidfile="/run/xray.pid"
start_stop_daemon_args="--make-pidfile"
export XRAY_LOCATION_ASSET="$ASSET_DIR"

depend() {
  need net
  after firewall
}
EOF
    chmod 755 /etc/init.d/xray
  fi
  configure_openrc_confdir
}

configure_offline_service() {
  case "$INIT_SYS" in
    systemd) configure_systemd_offline_service ;;
    openrc) configure_openrc_offline_service ;;
    *)
      err "离线安装当前支持 systemd 和 OpenRC。"
      return 1
      ;;
  esac
}

offline_import_xray() {
  local archive="$1" geoip="$2" geosite="$3"
  local tmp backup stamp

  offline_validate_file "$archive" "Xray 压缩包" 1024 || return 1
  offline_validate_file "$geoip" "GeoIP" 1024 || return 1
  offline_validate_file "$geosite" "GeoSite" 1024 || return 1

  detect_platform
  prepare_existing_xray_config || return 1
  ensure_layout
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/assets"
  offline_extract_xray "$archive" "$tmp/xray" || { rm -rf "$tmp"; return 1; }
  install -m 644 "$geoip" "$tmp/assets/geoip.dat"
  install -m 644 "$geosite" "$tmp/assets/geosite.dat"

  if ! "$tmp/xray" version >/dev/null 2>&1 && ! "$tmp/xray" -version >/dev/null 2>&1; then
    err "压缩包中的 xray 无法在本机运行，通常是 CPU 架构不匹配或文件损坏。"
    rm -rf "$tmp"
    return 1
  fi

  if ! XRAY_LOCATION_ASSET="$tmp/assets" "$tmp/xray" run -confdir "$CONF_DIR" -test >/dev/null 2>&1; then
    err "离线 Xray + GeoData 无法通过当前配置测试，未写入系统。"
    rm -rf "$tmp"
    return 1
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_DIR/offline-payload-$stamp"
  mkdir -p "$backup"
  if [[ -f "$XRAY_BIN" ]]; then
    cp -a "$XRAY_BIN" "$backup/xray"
  fi
  if [[ -f "$ASSET_DIR/geoip.dat" ]]; then
    cp -a "$ASSET_DIR/geoip.dat" "$backup/geoip.dat"
  fi
  if [[ -f "$ASSET_DIR/geosite.dat" ]]; then
    cp -a "$ASSET_DIR/geosite.dat" "$backup/geosite.dat"
  fi

  service_stop >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$XRAY_BIN")"
  install -m 755 "$tmp/xray" "${XRAY_BIN}.new"
  install -m 644 "$tmp/assets/geoip.dat" "$ASSET_DIR/geoip.dat.new"
  install -m 644 "$tmp/assets/geosite.dat" "$ASSET_DIR/geosite.dat.new"
  mv -f "${XRAY_BIN}.new" "$XRAY_BIN"
  mv -f "$ASSET_DIR/geoip.dat.new" "$ASSET_DIR/geoip.dat"
  mv -f "$ASSET_DIR/geosite.dat.new" "$ASSET_DIR/geosite.dat"

  if ! configure_offline_service || ! test_config || ! service_restart; then
    err "离线文件已导入，但服务启动失败。旧文件备份位于：$backup"
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"
  ok "离线安装完成，全程未访问网络。"
  echo "Xray SHA256   : $(offline_sha256_file "$XRAY_BIN")"
  echo "GeoIP SHA256  : $(offline_sha256_file "$ASSET_DIR/geoip.dat")"
  echo "GeoSite SHA256: $(offline_sha256_file "$ASSET_DIR/geosite.dat")"
  echo "旧文件备份    : $backup"
  "$XRAY_BIN" version 2>/dev/null | head -n 1 || "$XRAY_BIN" -version 2>/dev/null | head -n 1 || true
}

offline_import_geodata() {
  local geoip="$1" geosite="$2"
  local tmp backup stamp had_geoip=0 had_geosite=0

  offline_validate_file "$geoip" "GeoIP" 1024 || return 1
  offline_validate_file "$geosite" "GeoSite" 1024 || return 1
  xray_exists || { err "尚未安装 Xray，无法单独更新 GeoData。"; return 1; }

  ensure_layout
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/assets"
  install -m 644 "$geoip" "$tmp/assets/geoip.dat"
  install -m 644 "$geosite" "$tmp/assets/geosite.dat"

  if ! XRAY_LOCATION_ASSET="$tmp/assets" "$XRAY_BIN" run -confdir "$CONF_DIR" -test >/dev/null 2>&1; then
    err "新 GeoData 无法通过当前配置测试，未写入系统。"
    rm -rf "$tmp"
    return 1
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_DIR/geodata-$stamp"
  mkdir -p "$backup"
  if [[ -f "$ASSET_DIR/geoip.dat" ]]; then
    cp -a "$ASSET_DIR/geoip.dat" "$backup/geoip.dat"
    had_geoip=1
  fi
  if [[ -f "$ASSET_DIR/geosite.dat" ]]; then
    cp -a "$ASSET_DIR/geosite.dat" "$backup/geosite.dat"
    had_geosite=1
  fi

  install -m 644 "$tmp/assets/geoip.dat" "$ASSET_DIR/geoip.dat.new"
  install -m 644 "$tmp/assets/geosite.dat" "$ASSET_DIR/geosite.dat.new"
  mv -f "$ASSET_DIR/geoip.dat.new" "$ASSET_DIR/geoip.dat"
  mv -f "$ASSET_DIR/geosite.dat.new" "$ASSET_DIR/geosite.dat"

  if test_config && service_restart; then
    rm -rf "$tmp"
    ok "GeoIP / GeoSite 更新完成。"
    echo "GeoIP SHA256  : $(offline_sha256_file "$ASSET_DIR/geoip.dat")"
    echo "GeoSite SHA256: $(offline_sha256_file "$ASSET_DIR/geosite.dat")"
    echo "旧文件备份    : $backup"
    return 0
  fi

  err "GeoData 更新后配置或服务异常，正在回滚。"
  if (( had_geoip )); then
    cp -a "$backup/geoip.dat" "$ASSET_DIR/geoip.dat"
  else
    rm -f "$ASSET_DIR/geoip.dat"
  fi
  if (( had_geosite )); then
    cp -a "$backup/geosite.dat" "$ASSET_DIR/geosite.dat"
  else
    rm -f "$ASSET_DIR/geosite.dat"
  fi
  service_restart || true
  rm -rf "$tmp"
  return 1
}

cloudflare_update_geodata() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  if cloudflare_download_payload "$tmp"; then
    offline_import_geodata \
      "$CLOUDFLARE_GEOIP" \
      "$CLOUDFLARE_GEOSITE" || rc=$?
  else
    rc=$?
  fi
  rm -rf "$tmp"
  return "$rc"
}

offline_import_menu() {
  local archive geoip geosite
  echo "========== 完全离线安装 / 导入 =========="
  echo "此流程不会调用 curl、wget、apt、apk 或其他网络下载。"
  echo "请事先上传与本机架构匹配的 Xray ZIP、geoip.dat 和 geosite.dat。"
  archive="$(ask_required "Xray ZIP 路径")"
  geoip="$(ask_required "geoip.dat 路径")"
  geosite="$(ask_required "geosite.dat 路径")"
  offline_import_xray "$archive" "$geoip" "$geosite"
}

install_or_repair_xray() {
  detect_platform
  prepare_existing_xray_config || return 1
  ensure_layout
  load_network_state
  if uses_cloudflare_distribution; then
    info "安装来源为 Cloudflare，直接使用私有 R2 离线包。"
    cloudflare_install_or_update_xray
    return
  fi
  prepare_download_network || return 1
  pkg_install_base

  local tmp
  tmp="$(mktemp -d)"

  if [[ "$INIT_SYS" == "systemd" ]]; then
    info "使用 XTLS 官方 systemd 安装器安装/修复 Xray..."
    download_to_tmp "$OFFICIAL_INSTALLER" "$tmp/install-release.sh"
    chmod +x "$tmp/install-release.sh"
    run_systemd_installer "$tmp/install-release.sh" install
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
  elif [[ "$INIT_SYS" == "openrc" && "$PKG_MGR" == "apk" ]]; then
    info "使用 XTLS 官方 Alpine/OpenRC 安装器安装/修复 Xray..."
    download_to_tmp "$OFFICIAL_ALPINE_INSTALLER" "$tmp/install-release.sh"
    chmod +x "$tmp/install-release.sh"
    run_alpine_installer "$tmp/install-release.sh"
    configure_openrc_confdir
  else
    die "当前初始化系统不在自动安装范围。支持 systemd；Alpine 支持 OpenRC。"
  fi

  ensure_layout

  if test_config; then
    service_restart
    install_manager_command
    rm -rf "$tmp"
    ok "Xray 安装/修复完成。"
    "$XRAY_BIN" version 2>/dev/null | head -n 1 || "$XRAY_BIN" -version 2>/dev/null | head -n 1 || true
  else
    die "Xray 已安装，但当前配置测试失败。请先检查配置。"
  fi
}

xray_exists() {
  [[ -x "$XRAY_BIN" ]]
}

need_xray() {
  xray_exists || {
    warn "尚未检测到 Xray。"
    if confirm "现在安装 Xray？"; then
      install_or_repair_xray
    else
      return 1
    fi
  }
}

test_config_dir() {
  local dir="$1"
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -confdir "$dir" -test
}

test_config() {
  xray_exists || return 1
  test_config_dir "$CONF_DIR"
}

service_restart() {
  case "$INIT_SYS" in
    systemd)
      systemctl restart xray
      ;;
    openrc)
      rc-service xray restart
      ;;
    *)
      die "无法识别服务管理器。"
      ;;
  esac
}

service_start() {
  case "$INIT_SYS" in
    systemd) systemctl start xray ;;
    openrc) rc-service xray start ;;
    *) return 1 ;;
  esac
}

service_stop() {
  case "$INIT_SYS" in
    systemd) systemctl stop xray ;;
    openrc) rc-service xray stop ;;
    *) return 1 ;;
  esac
}

service_status() {
  case "$INIT_SYS" in
    systemd) systemctl --no-pager -l status xray || true ;;
    openrc) rc-service xray status || true ;;
    *) warn "无法识别服务管理器。" ;;
  esac
}

show_logs() {
  echo
  echo "1) 最近 80 行 systemd/OpenRC 服务日志"
  echo "2) Xray error.log"
  echo "3) Xray access.log"
  local c
  read -r -p "请选择: " c || true
  case "$c" in
    1)
      if [[ "$INIT_SYS" == "systemd" ]]; then
        journalctl -u xray --no-pager -n 80
      else
        tail -n 80 "$LOG_DIR/error.log" 2>/dev/null || true
      fi
      ;;
    2) tail -n 100 "$LOG_DIR/error.log" 2>/dev/null || true ;;
    3) tail -n 100 "$LOG_DIR/access.log" 2>/dev/null || true ;;
  esac
}

backup_now() {
  ensure_layout
  local ts file
  ts="$(date +%Y%m%d-%H%M%S)"
  file="$BACKUP_DIR/xray-config-$ts.tar.gz"
  tar -C "$XRAY_ROOT" -czf "$file" "$(basename "$CONF_DIR")" "$(basename "$CERT_DIR")" 2>/dev/null || \
    tar -C "$XRAY_ROOT" -czf "$file" "$(basename "$CONF_DIR")"
  chmod 600 "$file"
  printf '%s' "$file"
}

safe_write_inbound() {
  local tag="$1" json="$2" filename tmp backup
  filename="10_inbound_$(sanitize_tag "$tag").json"

  jq -e . >/dev/null <<<"$json" || {
    err "生成的 JSON 无效。"
    return 1
  }

  tmp="$(mktemp -d)"
  cp -a "$CONF_DIR/." "$tmp/" 2>/dev/null || true
  printf '%s\n' "$json" >"$tmp/$filename"

  info "测试完整配置..."
  if ! test_config_dir "$tmp"; then
    rm -rf "$tmp"
    err "Xray 配置测试失败，未写入正式配置。"
    return 1
  fi

  backup="$(backup_now)"
  cp "$tmp/$filename" "$CONF_DIR/$filename"
  rm -rf "$tmp"

  chown root:"$XRAY_RUN_GROUP" "$CONF_DIR/$filename" 2>/dev/null || true
  chmod 640 "$CONF_DIR/$filename" 2>/dev/null || true

  if service_restart; then
    ok "已添加入站：$tag"
    info "自动备份：$backup"
  else
    err "服务重启失败，正在回滚..."
    rm -f "$CONF_DIR/$filename"
    tar -xzf "$backup" -C "$XRAY_ROOT" "$(basename "$CONF_DIR")" 2>/dev/null || true
    service_restart || true
    return 1
  fi
}

port_in_use() {
  local port="$1"
  ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
}

warn_port() {
  local port="$1"
  if port_in_use "$port"; then
    warn "检测到端口 $port 已被监听。若不是现有 Xray 入站，请换端口。"
    confirm "仍继续使用 $port？" || return 1
  fi
}

random_secret() {
  openssl rand -base64 24 | tr -d '\n'
}

random_hex() {
  local bytes="${1:-8}"
  openssl rand -hex "$bytes"
}

generate_uuid() {
  if xray_exists; then
    "$XRAY_BIN" uuid 2>/dev/null | head -n 1
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 - <<'PY' 2>/dev/null || openssl rand -hex 16
import uuid
print(uuid.uuid4())
PY
  fi
}

MANAGED_CERT=""
MANAGED_KEY=""
TLS_DOMAIN=""

copy_existing_certificate() {
  local tag="$1" cert key target
  cert="$(ask_required "证书 fullchain/cert 文件绝对路径")"
  key="$(ask_required "私钥 key 文件绝对路径")"
  [[ -f "$cert" ]] || { err "证书不存在：$cert"; return 1; }
  [[ -f "$key" ]] || { err "私钥不存在：$key"; return 1; }

  target="$CERT_DIR/$(sanitize_tag "$tag")"
  mkdir -p "$target"
  cp "$cert" "$target/fullchain.pem"
  cp "$key" "$target/key.pem"
  chown -R root:"$XRAY_RUN_GROUP" "$target" 2>/dev/null || true
  chmod 750 "$target" 2>/dev/null || true
  chmod 640 "$target/fullchain.pem" "$target/key.pem" 2>/dev/null || true

  MANAGED_CERT="$target/fullchain.pem"
  MANAGED_KEY="$target/key.pem"
  ok "证书已复制到 Xray 管理目录。"
}

install_socat_for_acme() {
  command -v socat >/dev/null 2>&1 && return 0
  case "$PKG_MGR" in
    apt|dnf|yum|zypper|pacman|apk) pkg_install_optional socat ;;
    *) return 1 ;;
  esac
}

acme_issue_certificate() {
  local tag="$1" domain email acme target reloadcmd
  domain="$(ask_required "证书域名（需已解析到本机）")"
  if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
    err "域名格式不安全。"
    return 1
  fi
  email="$(ask_required "ACME 邮箱")"

  if port_in_use 80; then
    err "80/TCP 当前已被占用。acme.sh standalone HTTP-01 需要 80 端口空闲。"
    warn '如果你正在运行 Nginx/Caddy，请改用“已有证书”方式，或自行使用 webroot/DNS 模式签发。'
    return 1
  fi

  install_socat_for_acme || warn "未能自动安装 socat，acme.sh standalone 可能失败。"

  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    info "安装 acme.sh..."
    curl_net -fsSL "$ACME_INSTALLER" | sh -s email="$email"
  fi
  acme="/root/.acme.sh/acme.sh"
  [[ -x "$acme" ]] || { err "acme.sh 安装失败。"; return 1; }

  ufw_allow_if_active 80 tcp

  info "使用 Let's Encrypt standalone HTTP-01 签发..."
  "$acme" --set-default-ca --server letsencrypt

  local issue_args=(--issue --standalone -d "$domain" --server letsencrypt)
  if [[ "$(default_public_listen)" == "::" ]]; then
    issue_args+=(--listen-v6)
    info "检测到 IPv6-only：ACME standalone 将显式监听 IPv6。"
  fi
  "$acme" "${issue_args[@]}"

  target="$CERT_DIR/$(sanitize_tag "$tag")"
  mkdir -p "$target"
  MANAGED_CERT="$target/fullchain.pem"
  MANAGED_KEY="$target/key.pem"
  TLS_DOMAIN="$domain"

  if [[ "$INIT_SYS" == "systemd" ]]; then
    reloadcmd="chgrp $XRAY_RUN_GROUP '$MANAGED_CERT' '$MANAGED_KEY' 2>/dev/null || true; chmod 640 '$MANAGED_CERT' '$MANAGED_KEY' 2>/dev/null || true; systemctl restart xray"
  else
    reloadcmd="chgrp $XRAY_RUN_GROUP '$MANAGED_CERT' '$MANAGED_KEY' 2>/dev/null || true; chmod 640 '$MANAGED_CERT' '$MANAGED_KEY' 2>/dev/null || true; rc-service xray restart"
  fi

  "$acme" --install-cert -d "$domain" \
    --key-file "$MANAGED_KEY" \
    --fullchain-file "$MANAGED_CERT" \
    --reloadcmd "$reloadcmd"

  chown -R root:"$XRAY_RUN_GROUP" "$target" 2>/dev/null || true
  chmod 750 "$target" 2>/dev/null || true
  chmod 640 "$MANAGED_CERT" "$MANAGED_KEY" 2>/dev/null || true
  ok "证书已签发并部署：$domain"
}

tls_certificate_wizard() {
  local tag="$1" c
  MANAGED_CERT=""
  MANAGED_KEY=""
  TLS_DOMAIN=""

  echo
  echo "TLS 证书来源："
  echo "1) 使用已有证书（复制到受管目录）"
  echo "2) acme.sh + Let's Encrypt 自动签发（80/TCP 必须空闲）"
  read -r -p "请选择 [1]: " c || true
  c="${c:-1}"

  case "$c" in
    1) copy_existing_certificate "$tag" ;;
    2) acme_issue_certificate "$tag" ;;
    *) err "无效选择。"; return 1 ;;
  esac
}

TRANSPORT="raw"
TRANSPORT_SETTINGS='{}'
TRANSPORT_PATH=""
TRANSPORT_HOST=""
GRPC_SERVICE=""
STREAM_SETTINGS='{}'
SECURITY_SETTINGS='{}'

choose_transport() {
  local c path host service mtu
  echo
  echo "传输方式："
  echo "1) RAW/TCP（最简单）"
  echo "2) XHTTP"
  echo "3) gRPC"
  echo "4) WebSocket"
  echo "5) HTTPUpgrade"
  echo "6) mKCP/UDP"
  read -r -p "请选择 [1]: " c || true
  c="${c:-1}"

  TRANSPORT_PATH=""
  TRANSPORT_HOST=""
  GRPC_SERVICE=""

  case "$c" in
    1)
      TRANSPORT="raw"
      TRANSPORT_SETTINGS='{"rawSettings":{"header":{"type":"none"}}}'
      ;;
    2)
      TRANSPORT="xhttp"
      path="$(ask_default "XHTTP Path" "/$(random_hex 6)")"
      [[ "$path" == /* ]] || path="/$path"
      TRANSPORT_PATH="$path"
      TRANSPORT_SETTINGS="$(jq -cn --arg p "$path" '{xhttpSettings:{path:$p}}')"
      ;;
    3)
      TRANSPORT="grpc"
      service="$(ask_default "gRPC serviceName" "$(random_hex 8)")"
      GRPC_SERVICE="$service"
      TRANSPORT_SETTINGS="$(jq -cn --arg s "$service" '{grpcSettings:{serviceName:$s}}')"
      ;;
    4)
      TRANSPORT="websocket"
      path="$(ask_default "WebSocket Path" "/$(random_hex 6)")"
      [[ "$path" == /* ]] || path="/$path"
      host="$(ask_default "WebSocket Host（可为空/域名）" "")"
      TRANSPORT_PATH="$path"
      TRANSPORT_HOST="$host"
      TRANSPORT_SETTINGS="$(jq -cn --arg p "$path" --arg h "$host" '
        if $h=="" then {wsSettings:{path:$p}} else {wsSettings:{path:$p,host:$h}} end')"
      ;;
    5)
      TRANSPORT="httpupgrade"
      path="$(ask_default "HTTPUpgrade Path" "/$(random_hex 6)")"
      [[ "$path" == /* ]] || path="/$path"
      host="$(ask_default "HTTPUpgrade Host（可为空/域名）" "")"
      TRANSPORT_PATH="$path"
      TRANSPORT_HOST="$host"
      TRANSPORT_SETTINGS="$(jq -cn --arg p "$path" --arg h "$host" '
        if $h=="" then {httpupgradeSettings:{path:$p}} else {httpupgradeSettings:{path:$p,host:$h}} end')"
      ;;
    6)
      TRANSPORT="mkcp"
      mtu="$(ask_default "mKCP MTU" "1350")"
      [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1350
      TRANSPORT_SETTINGS="$(jq -cn --argjson mtu "$mtu" '{
        kcpSettings:{
          mtu:$mtu,
          tti:20,
          uplinkCapacity:100,
          downlinkCapacity:100,
          congestion:false,
          readBufferSize:2,
          writeBufferSize:2
        }
      }')"
      ;;
    *)
      warn "无效选择，使用 RAW。"
      TRANSPORT="raw"
      TRANSPORT_SETTINGS='{"rawSettings":{"header":{"type":"none"}}}'
      ;;
  esac
}

REALITY_PUBLIC=""
REALITY_PRIVATE=""
REALITY_SNI=""
REALITY_TARGET=""
REALITY_SHORTID=""
REALITY_TARGET_RISK_REASON=""
REALITY_TARGET_HIGH_RISK=0
REALITY_LIMIT_FALLBACK=0
REALITY_LIMIT_UP_AFTER=0
REALITY_LIMIT_UP_RATE=0
REALITY_LIMIT_UP_BURST=0
REALITY_LIMIT_DOWN_AFTER=0
REALITY_LIMIT_DOWN_RATE=0
REALITY_LIMIT_DOWN_BURST=0

random_range() {
  local min="$1" max="$2" hex value
  (( min <= max )) || return 1
  hex="$(openssl rand -hex 4 2>/dev/null)" || return 1
  value=$((16#$hex))
  printf '%s' "$((min + value % (max - min + 1)))"
}

known_shared_cdn_name() {
  local name="${1,,}"
  name="${name%.}"
  case "$name" in
    cloudflare.com|*.cloudflare.com|*.pages.dev|*.workers.dev|\
    *.cloudfront.net|*.fastly.net|*.fastlylb.net|\
    *.akamai.net|*.akamaiedge.net|*.akamaihd.net|*.akamaized.net|\
    *.edgekey.net|*.edgesuite.net|*.azureedge.net|*.azurefd.net|\
    *.trafficmanager.net|*.cdn77.org|*.b-cdn.net|\
    google.com|*.google.com|apple.com|*.apple.com|\
    microsoft.com|*.microsoft.com)
      return 0
      ;;
  esac
  return 1
}

reality_target_risk_check() {
  local host="$1" port="$2" dns_hint="" headers=""
  REALITY_TARGET_RISK_REASON=""

  if known_shared_cdn_name "$host"; then
    REALITY_TARGET_RISK_REASON="目标域名本身属于常见共享 CDN 或大型公共站点"
    return 0
  fi

  [[ "${XRAY_MANAGER_SKIP_TARGET_PROBE:-0}" == "1" ]] && return 1

  if command -v dig >/dev/null 2>&1; then
    dns_hint="$(dig +short CNAME "$host" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    if [[ "$dns_hint" =~ (cloudfront\.net|fastly\.net|fastlylb\.net|akamai|edgekey\.net|edgesuite\.net|azureedge\.net|azurefd\.net|trafficmanager\.net|cdn77\.org|b-cdn\.net) ]]; then
      REALITY_TARGET_RISK_REASON="DNS CNAME 指向共享 CDN：$dns_hint"
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    headers="$(curl -ksSI --connect-timeout 4 --max-time 7 "https://${host}:${port}/" 2>/dev/null || true)"
    if grep -Eiq '^(server:[[:space:]]*(cloudflare|akamaighost)|cf-ray:|x-amz-cf-|x-served-by:|x-azure-ref:)' <<<"$headers"; then
      REALITY_TARGET_RISK_REASON="HTTPS 响应头显示目标可能位于共享 CDN"
      return 0
    fi
  fi

  return 1
}

configure_reality_fallback_limits() {
  local profile up_after_mib down_after_mib up_rate_kib down_rate_kib up_burst_kib down_burst_kib

  echo
  warn "REALITY 会把未通过认证的连接转发到 target；限速只能降低被扫描滥用后的流量损失。"
  echo "回落连接保护："
  echo "1) 流量保护（推荐低流量 VPS，参数随机化）"
  echo "2) 隐蔽平衡（限速更宽松，参数随机化）"
  echo "3) 不限速（隐蔽优先，仅建议安全 target）"
  profile="$(ask_default "请选择" "1")"

  case "$profile" in
    1)
      up_after_mib="$(random_range 4 8)"
      down_after_mib="$(random_range 6 12)"
      up_rate_kib="$(random_range 128 320)"
      down_rate_kib="$(random_range 256 640)"
      up_burst_kib="$(random_range 768 1536)"
      down_burst_kib="$(random_range 1536 3072)"
      ;;
    2)
      up_after_mib="$(random_range 8 16)"
      down_after_mib="$(random_range 12 24)"
      up_rate_kib="$(random_range 512 1024)"
      down_rate_kib="$(random_range 1024 2048)"
      up_burst_kib="$(random_range 2048 4096)"
      down_burst_kib="$(random_range 4096 8192)"
      ;;
    3)
      if (( REALITY_TARGET_HIGH_RISK )); then
        warn "高风险共享 CDN target 关闭限速后，扫描者可能持续消耗你的 VPS 流量。"
        warn "不限速更接近正常网站行为，但不能防止回落流量滥用。"
        confirm "确认仍关闭 REALITY 回落限速？" || return 1
      fi
      REALITY_LIMIT_FALLBACK=0
      warn "已关闭 REALITY 回落限速。请优先使用非共享 CDN target，并持续关注 VPS 流量。"
      return 0
      ;;
    *)
      err "无效选择。"
      return 1
      ;;
  esac

  REALITY_LIMIT_FALLBACK=1
  REALITY_LIMIT_UP_AFTER=$((up_after_mib * 1024 * 1024))
  REALITY_LIMIT_DOWN_AFTER=$((down_after_mib * 1024 * 1024))
  REALITY_LIMIT_UP_RATE=$((up_rate_kib * 1024))
  REALITY_LIMIT_DOWN_RATE=$((down_rate_kib * 1024))
  REALITY_LIMIT_UP_BURST=$((up_burst_kib * 1024))
  REALITY_LIMIT_DOWN_BURST=$((down_burst_kib * 1024))
}

generate_reality_keys() {
  local out pubout
  out="$("$XRAY_BIN" x25519 2>/dev/null)" || return 1
  REALITY_PRIVATE="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  REALITY_PUBLIC="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /(password|public)/ {print $2; exit}')"

  if [[ -z "$REALITY_PRIVATE" ]]; then
    REALITY_PRIVATE="$(printf '%s\n' "$out" | awk 'NR==1 {print $NF}')"
  fi

  if [[ -z "$REALITY_PUBLIC" && -n "$REALITY_PRIVATE" ]]; then
    pubout="$("$XRAY_BIN" x25519 -i "$REALITY_PRIVATE" 2>/dev/null || true)"
    REALITY_PUBLIC="$(printf '%s\n' "$pubout" | awk -F': *' 'tolower($1) ~ /(password|public)/ {print $2; exit}')"
  fi

  [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]]
}

build_reality_settings() {
  local target_host target_port sni
  [[ "$TRANSPORT" == "raw" || "$TRANSPORT" == "xhttp" || "$TRANSPORT" == "grpc" ]] || {
    err "REALITY 仅在本向导中用于 RAW / XHTTP / gRPC。"
    return 1
  }

  generate_reality_keys || {
    err "无法生成 REALITY X25519 密钥。"
    return 1
  }

  echo
  info "优先使用自己的域名/本机 Web 服务，或同 ASN 的非 CDN 小站；避免 Cloudflare 等共享 CDN。"
  target_host="$(ask_required "REALITY target 域名或 IP（不含端口）")"
  target_port="$(ask_port "REALITY target 端口" "443")"
  sni="$(ask_default "客户端 SNI/serverName" "$target_host")"

  if reality_target_risk_check "$target_host" "$target_port"; then
    REALITY_TARGET_HIGH_RISK=1
    warn "高风险 REALITY target：$REALITY_TARGET_RISK_REASON"
    warn "未认证连接可能借此把你的 VPS 当作 CDN 转发节点并消耗流量。"
    confirm "仍然使用这个 target？" || {
      warn "已取消，请重新选择非共享 CDN target。"
      return 1
    }
  else
    REALITY_TARGET_HIGH_RISK=0
    info "未发现明显共享 CDN 特征；这是启发式检测，不能代替人工确认。"
  fi

  configure_reality_fallback_limits || return 1

  REALITY_TARGET="${target_host}:${target_port}"
  REALITY_SNI="$sni"
  REALITY_SHORTID="$(random_hex 8)"

  SECURITY_SETTINGS="$(jq -cn \
    --arg target "$REALITY_TARGET" \
    --arg sni "$REALITY_SNI" \
    --arg private "$REALITY_PRIVATE" \
    --arg sid "$REALITY_SHORTID" \
    --argjson limit "$REALITY_LIMIT_FALLBACK" \
    --argjson up_after "$REALITY_LIMIT_UP_AFTER" \
    --argjson up_rate "$REALITY_LIMIT_UP_RATE" \
    --argjson up_burst "$REALITY_LIMIT_UP_BURST" \
    --argjson down_after "$REALITY_LIMIT_DOWN_AFTER" \
    --argjson down_rate "$REALITY_LIMIT_DOWN_RATE" \
    --argjson down_burst "$REALITY_LIMIT_DOWN_BURST" \
    '{
      security:"reality",
      realitySettings:({
        show:false,
        target:$target,
        xver:0,
        serverNames:[$sni],
        privateKey:$private,
        shortIds:[$sid]
      } + (if $limit == 1 then {
        limitFallbackUpload:{
          afterBytes:$up_after,
          bytesPerSec:$up_rate,
          burstBytesPerSec:$up_burst
        },
        limitFallbackDownload:{
          afterBytes:$down_after,
          bytesPerSec:$down_rate,
          burstBytesPerSec:$down_burst
        }
      } else {} end))
    }')"
}

build_tls_settings() {
  local tag="$1" server_name
  tls_certificate_wizard "$tag" || return 1
  server_name="$(ask_default "TLS SNI/证书域名" "${TLS_DOMAIN:-}")"
  SECURITY_SETTINGS="$(jq -cn \
    --arg cert "$MANAGED_CERT" \
    --arg key "$MANAGED_KEY" \
    --arg sn "$server_name" \
    '{
      security:"tls",
      tlsSettings:{
        serverName:$sn,
        certificates:[
          {
            usage:"encipherment",
            certificateFile:$cert,
            keyFile:$key
          }
        ]
      }
    }')"
}

build_stream_settings() {
  local protocol="$1" tag="$2" sec_choice base
  STREAM_SETTINGS='{}'
  SECURITY_SETTINGS='{}'
  choose_transport

  base="$(jq -cn --arg m "$TRANSPORT" --argjson s "$TRANSPORT_SETTINGS" '$s + {method:$m}')"

  if [[ "$TRANSPORT" == "mkcp" ]]; then
    warn "mKCP 向导使用无 TLS/REALITY 的基础模式；新版 mKCP 的旧 header/seed 已移除，需要伪装可用 FinalMask + 自定义 JSON。"
    if [[ "$protocol" == "vless" ]]; then
      warn "VLESS 公网使用通常应有外层传输安全；这里更建议 VMess+mKCP，或自行配置 VLESS Encryption/FinalMask。"
      confirm "仍创建 VLESS + mKCP + security=none？" || return 1
    fi
    STREAM_SETTINGS="$(jq -cn --argjson b "$base" '$b + {security:"none"}')"
    return 0
  fi

  echo
  if [[ "$protocol" == "vless" && ( "$TRANSPORT" == "raw" || "$TRANSPORT" == "xhttp" || "$TRANSPORT" == "grpc" ) ]]; then
    echo "传输安全："
    echo "1) REALITY（推荐）"
    echo "2) TLS"
    echo "3) none（仅可信私网/自行承担风险）"
    read -r -p "请选择 [1]: " sec_choice || true
    sec_choice="${sec_choice:-1}"
  elif [[ "$protocol" == "trojan" ]]; then
    echo "Trojan 正常公网使用应启用 TLS。"
    echo "1) TLS"
    echo "2) none（仅可信私网）"
    read -r -p "请选择 [1]: " sec_choice || true
    sec_choice="${sec_choice:-1}"
    [[ "$sec_choice" == "2" ]] && sec_choice="3"
  else
    echo "传输安全："
    echo "1) TLS"
    echo "2) none"
    read -r -p "请选择 [1]: " sec_choice || true
    sec_choice="${sec_choice:-1}"
    [[ "$sec_choice" == "2" ]] && sec_choice="3"
  fi

  case "$sec_choice" in
    1)
      if [[ "$protocol" == "vless" && ( "$TRANSPORT" == "raw" || "$TRANSPORT" == "xhttp" || "$TRANSPORT" == "grpc" ) ]]; then
        build_reality_settings || return 1
      else
        build_tls_settings "$tag" || return 1
      fi
      ;;
    2)
      build_tls_settings "$tag" || return 1
      ;;
    3)
      warn "你选择了 security=none。公网场景请确认协议/网络环境确实适合。"
      confirm "继续？" || return 1
      SECURITY_SETTINGS='{"security":"none"}'
      ;;
    *)
      err "无效选择。"
      return 1
      ;;
  esac

  STREAM_SETTINGS="$(jq -cn --argjson b "$base" --argjson s "$SECURITY_SETTINGS" '$b + $s')"
}

maybe_ufw_for_transport() {
  local port="$1" transport="$2" protocol="${3:-}"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0

  if [[ "$transport" == "mkcp" || "$transport" == "hysteria" || "$protocol" == "wireguard" ]]; then
    ufw allow "$port/udp" comment "Xray" >/dev/null 2>&1 || ufw allow "$port/udp" >/dev/null 2>&1 || true
  elif [[ "$protocol" == "shadowsocks" ]]; then
    ufw allow "$port/tcp" comment "Xray" >/dev/null 2>&1 || ufw allow "$port/tcp" >/dev/null 2>&1 || true
    ufw allow "$port/udp" comment "Xray" >/dev/null 2>&1 || ufw allow "$port/udp" >/dev/null 2>&1 || true
  else
    ufw allow "$port/tcp" comment "Xray" >/dev/null 2>&1 || ufw allow "$port/tcp" >/dev/null 2>&1 || true
  fi
}

show_created_summary() {
  local tag="$1" protocol="$2" listen="$3" port="$4" credential="$5"
  echo
  printf "${C_BOLD}创建结果${C_RESET}\n"
  printf "  Tag        : %s\n" "$tag"
  printf "  Protocol   : %s\n" "$protocol"
  printf "  Listen     : %s\n" "$listen"
  printf "  Port       : %s\n" "$port"
  [[ -n "$credential" ]] && printf "  Credential : %s\n" "$credential"
  [[ -n "$TRANSPORT" ]] && printf "  Transport  : %s\n" "$TRANSPORT"
  [[ -n "$TRANSPORT_PATH" ]] && printf "  Path       : %s\n" "$TRANSPORT_PATH"
  [[ -n "$TRANSPORT_HOST" ]] && printf "  Host       : %s\n" "$TRANSPORT_HOST"
  [[ -n "$GRPC_SERVICE" ]] && printf "  gRPC       : %s\n" "$GRPC_SERVICE"
  if [[ -n "$REALITY_SNI" ]]; then
    printf "  REALITY SNI: %s\n" "$REALITY_SNI"
    printf "  Target     : %s\n" "$REALITY_TARGET"
    printf "  PublicKey  : %s\n" "$REALITY_PUBLIC"
    printf "  ShortID    : %s\n" "$REALITY_SHORTID"
    if (( REALITY_LIMIT_FALLBACK )); then
      printf "  Fallback   : 已启用未认证连接随机限速\n"
    else
      printf "  Fallback   : 未限速\n"
    fi
  fi
  echo
}

add_vless() {
  need_xray || return
  local tag port listen uuid flow stream json
  TRANSPORT=""; TRANSPORT_PATH=""; TRANSPORT_HOST=""; GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""
  REALITY_TARGET_HIGH_RISK=0
  REALITY_LIMIT_FALLBACK=0

  tag="$(ask_tag "vless-reality")"
  port="$(ask_port "监听端口" "443")"
  warn_port "$port" || return
  listen="$(ask_default "监听地址" "$(default_public_listen)")"
  uuid="$(ask_default "UUID（留默认自动生成）" "$(generate_uuid)")"

  build_stream_settings "vless" "$tag" || return
  stream="$STREAM_SETTINGS"

  flow=""
  if jq -e '.security=="reality"' >/dev/null <<<"$stream" && [[ "$TRANSPORT" == "raw" ]]; then
    if confirm "RAW + REALITY 是否启用 xtls-rprx-vision？（推荐）"; then
      flow="xtls-rprx-vision"
    fi
  fi

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg id "$uuid" --arg flow "$flow" --argjson stream "$stream" '
    {
      inbounds:[
        {
          tag:$tag,
          listen:$listen,
          port:$port,
          protocol:"vless",
          settings:{
            users:[{id:$id,level:0,email:($tag+"@xray.local"),flow:$flow}],
            decryption:"none"
          },
          streamSettings:$stream,
          sniffing:{enabled:true,destOverride:["http","tls","quic"]}
        }
      ]
    }')"

  safe_write_inbound "$tag" "$json" || return
  maybe_ufw_for_transport "$port" "$TRANSPORT" "vless"
  show_created_summary "$tag" "vless" "$listen" "$port" "$uuid"
}

add_vmess() {
  need_xray || return
  local tag port listen uuid stream json
  TRANSPORT=""; TRANSPORT_PATH=""; TRANSPORT_HOST=""; GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  tag="$(ask_tag "vmess")"
  port="$(ask_port "监听端口" "8443")"
  warn_port "$port" || return
  listen="$(ask_default "监听地址" "$(default_public_listen)")"
  uuid="$(ask_default "UUID（留默认自动生成）" "$(generate_uuid)")"
  build_stream_settings "vmess" "$tag" || return
  stream="$STREAM_SETTINGS"

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg id "$uuid" --argjson stream "$stream" '
    {
      inbounds:[
        {
          tag:$tag,
          listen:$listen,
          port:$port,
          protocol:"vmess",
          settings:{users:[{id:$id,level:0,email:($tag+"@xray.local")}]},
          streamSettings:$stream,
          sniffing:{enabled:true,destOverride:["http","tls","quic"]}
        }
      ]
    }')"

  safe_write_inbound "$tag" "$json" || return
  maybe_ufw_for_transport "$port" "$TRANSPORT" "vmess"
  show_created_summary "$tag" "vmess" "$listen" "$port" "$uuid"
  warn "VMess 对系统时间敏感，建议保持 NTP/chrony 正常。"
}

add_trojan() {
  need_xray || return
  local tag port listen password stream json
  TRANSPORT=""; TRANSPORT_PATH=""; TRANSPORT_HOST=""; GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  tag="$(ask_tag "trojan-tls")"
  port="$(ask_port "监听端口" "443")"
  warn_port "$port" || return
  listen="$(ask_default "监听地址" "$(default_public_listen)")"
  password="$(ask_default "Trojan 密码" "$(random_secret)")"
  build_stream_settings "trojan" "$tag" || return
  stream="$STREAM_SETTINGS"

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg password "$password" --argjson stream "$stream" '
    {
      inbounds:[
        {
          tag:$tag,
          listen:$listen,
          port:$port,
          protocol:"trojan",
          settings:{users:[{password:$password,level:0,email:($tag+"@xray.local")}]},
          streamSettings:$stream,
          sniffing:{enabled:true,destOverride:["http","tls","quic"]}
        }
      ]
    }')"

  safe_write_inbound "$tag" "$json" || return
  maybe_ufw_for_transport "$port" "$TRANSPORT" "trojan"
  show_created_summary "$tag" "trojan" "$listen" "$port" "$password"
}

add_shadowsocks() {
  need_xray || return
  local tag port listen method keylen password network json c
  TRANSPORT="native"
  TRANSPORT_PATH=""
  TRANSPORT_HOST=""
  GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  tag="$(ask_tag "ss2022")"
  port="$(ask_port "监听端口" "8388")"
  warn_port "$port" || return
  listen="$(ask_default "监听地址" "$(default_public_listen)")"

  echo "加密方式："
  echo "1) 2022-blake3-aes-128-gcm"
  echo "2) 2022-blake3-aes-256-gcm"
  echo "3) 2022-blake3-chacha20-poly1305"
  echo "4) aes-256-gcm（兼容旧客户端）"
  read -r -p "请选择 [2]: " c || true
  c="${c:-2}"
  case "$c" in
    1) method="2022-blake3-aes-128-gcm"; keylen=16 ;;
    2) method="2022-blake3-aes-256-gcm"; keylen=32 ;;
    3) method="2022-blake3-chacha20-poly1305"; keylen=32 ;;
    4) method="aes-256-gcm"; keylen=0 ;;
    *) method="2022-blake3-aes-256-gcm"; keylen=32 ;;
  esac

  if (( keylen > 0 )); then
    password="$(openssl rand -base64 "$keylen" | tr -d '\n')"
  else
    password="$(random_secret)"
  fi
  password="$(ask_default "密码/PSK" "$password")"
  network="$(ask_default "监听网络 tcp / udp / tcp,udp" "tcp,udp")"
  [[ "$network" == "tcp" || "$network" == "udp" || "$network" == "tcp,udp" ]] || network="tcp,udp"

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg method "$method" --arg password "$password" --arg network "$network" '
    {
      inbounds:[
        {
          tag:$tag,
          listen:$listen,
          port:$port,
          protocol:"shadowsocks",
          settings:{
            network:$network,
            method:$method,
            password:$password,
            level:0,
            email:($tag+"@xray.local")
          }
        }
      ]
    }')"

  safe_write_inbound "$tag" "$json" || return
  maybe_ufw_for_transport "$port" "native" "shadowsocks"
  show_created_summary "$tag" "shadowsocks" "$listen" "$port" "$password"
  printf "  Method     : %s\n\n" "$method"
}

add_socks() {
  need_xray || return
  local tag port listen auth user pass udp json c
  TRANSPORT="local"
  TRANSPORT_PATH=""; TRANSPORT_HOST=""; GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  warn "SOCKS 本身不加密，默认只监听 127.0.0.1。"
  tag="$(ask_tag "socks-local")"
  port="$(ask_port "监听端口" "1080")"
  warn_port "$port" || return
  listen="$(ask_default "监听地址" "127.0.0.1")"

  echo "认证：1) 用户名密码  2) 无认证"
  read -r -p "请选择 [1]: " c || true
  c="${c:-1}"
  if [[ "$c" == "2" ]]; then
    auth="noauth"; user=""; pass=""
  else
    auth="password"
    user="$(ask_default "用户名" "xray")"
    pass="$(ask_default "密码" "$(random_secret)")"
  fi
  udp="true"
  confirm "启用 UDP？" || udp="false"

  if [[ "$auth" == "password" ]]; then
    json="$(jq -cn \
      --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
      --arg user "$user" --arg pass "$pass" --argjson udp "$udp" '
      {inbounds:[{tag:$tag,listen:$listen,port:$port,protocol:"socks",
      settings:{auth:"password",users:[{user:$user,pass:$pass}],udp:$udp,userLevel:0}}]}')"
  else
    json="$(jq -cn \
      --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson udp "$udp" '
      {inbounds:[{tag:$tag,listen:$listen,port:$port,protocol:"socks",
      settings:{auth:"noauth",udp:$udp,userLevel:0}}]}')"
  fi

  safe_write_inbound "$tag" "$json" || return
  if [[ "$listen" != "127.0.0.1" && "$listen" != "::1" ]]; then
    warn "你把 SOCKS 暴露到了非本机地址，请确保防火墙只允许可信来源。"
  fi
  show_created_summary "$tag" "socks" "$listen" "$port" "${user:+$user:$pass}"
}

add_http() {
  need_xray || return
  local tag port listen user pass json
  TRANSPORT="local"
  TRANSPORT_PATH=""; TRANSPORT_HOST=""; GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  warn "HTTP 入站不加密，默认只监听 127.0.0.1。"
  tag="$(ask_tag "http-local")"
  port="$(ask_port "监听端口" "8080")"
  warn_port "$port" || return
  listen="$(ask_default "监听地址" "127.0.0.1")"
  user="$(ask_default "用户名" "xray")"
  pass="$(ask_default "密码" "$(random_secret)")"

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg user "$user" --arg pass "$pass" '
    {inbounds:[{tag:$tag,listen:$listen,port:$port,protocol:"http",
    settings:{users:[{user:$user,pass:$pass}],allowTransparent:false,userLevel:0}}]}')"

  safe_write_inbound "$tag" "$json" || return
  if [[ "$listen" != "127.0.0.1" && "$listen" != "::1" ]]; then
    warn "你把 HTTP 代理暴露到了非本机地址，请确保防火墙只允许可信来源。"
  fi
  show_created_summary "$tag" "http" "$listen" "$port" "$user:$pass"
}

add_hysteria2() {
  need_xray || return
  local tag port listen auth stream json domain cert key up down
  TRANSPORT="hysteria"
  TRANSPORT_PATH=""
  TRANSPORT_HOST=""
  GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  tag="$(ask_tag "hysteria2")"
  port="$(ask_port "UDP 监听端口" "443")"
  warn_port "$port" || return
  listen="$(ask_default "监听地址" "$(default_public_listen)")"
  auth="$(ask_default "Hysteria2 auth" "$(random_secret)")"

  tls_certificate_wizard "$tag" || return
  domain="$(ask_default "TLS SNI/证书域名" "${TLS_DOMAIN:-}")"
  cert="$MANAGED_CERT"
  key="$MANAGED_KEY"
  up="$(ask_default "Brutal 上行参考速率" "100 mbps")"
  down="$(ask_default "Brutal 下行参考速率" "100 mbps")"

  stream="$(jq -cn \
    --arg sn "$domain" --arg cert "$cert" --arg key "$key" \
    --arg auth "$auth" --arg up "$up" --arg down "$down" '
    {
      method:"hysteria",
      security:"tls",
      tlsSettings:{
        serverName:$sn,
        alpn:["h3"],
        certificates:[{usage:"encipherment",certificateFile:$cert,keyFile:$key}]
      },
      hysteriaSettings:{version:2,auth:$auth},
      finalmask:{quicParams:{congestion:"brutal",brutalUp:$up,brutalDown:$down}}
    }')"

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg auth "$auth" --argjson stream "$stream" '
    {
      inbounds:[
        {
          tag:$tag,
          listen:$listen,
          port:$port,
          protocol:"hysteria",
          settings:{version:2,users:[{auth:$auth,level:0,email:($tag+"@xray.local")}]},
          streamSettings:$stream
        }
      ]
    }')"

  safe_write_inbound "$tag" "$json" || return
  maybe_ufw_for_transport "$port" "hysteria" "hysteria"
  show_created_summary "$tag" "hysteria2" "$listen" "$port" "$auth"
  printf "  SNI        : %s\n" "$domain"
  printf "  ALPN       : h3\n\n"
}

install_wireguard_tools() {
  command -v wg >/dev/null 2>&1 && return 0
  case "$PKG_MGR" in
    apt) pkg_install_optional wireguard-tools ;;
    dnf|yum) pkg_install_optional wireguard-tools ;;
    zypper) pkg_install_optional wireguard-tools ;;
    pacman) pkg_install_optional wireguard-tools ;;
    apk) pkg_install_optional wireguard-tools ;;
    *) return 1 ;;
  esac
}

add_wireguard() {
  need_xray || return
  local tag port listen server_priv server_pub client_pub allowed mtu json
  TRANSPORT="wireguard"
  TRANSPORT_PATH=""; TRANSPORT_HOST=""; GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  warn "这是 Xray 的 userspace WireGuard 入站；它不是专门为代理伪装设计的。"
  tag="$(ask_tag "wireguard-in")"
  port="$(ask_port "UDP 监听端口" "51820")"
  warn_port "$port" || return
  listen="$(ask_default "监听地址" "$(default_public_listen)")"

  install_wireguard_tools || {
    err "无法安装 wireguard-tools，无法安全生成 WireGuard 密钥。"
    return 1
  }

  server_priv="$(wg genkey)"
  server_pub="$(printf '%s' "$server_priv" | wg pubkey)"
  client_pub="$(ask_required "客户端 WireGuard PublicKey")"
  allowed="$(ask_default "允许的客户端源网段 allowedIPs" "0.0.0.0/0,::/0")"
  mtu="$(ask_default "MTU" "1420")"
  [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1420

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg priv "$server_priv" --arg pub "$client_pub" --arg allowed "$allowed" --argjson mtu "$mtu" '
    {
      inbounds:[
        {
          tag:$tag,
          listen:$listen,
          port:$port,
          protocol:"wireguard",
          settings:{
            secretKey:$priv,
            peers:[{publicKey:$pub,allowedIPs:($allowed|split(","))}],
            mtu:$mtu
          }
        }
      ]
    }')"

  safe_write_inbound "$tag" "$json" || return
  maybe_ufw_for_transport "$port" "wireguard" "wireguard"
  show_created_summary "$tag" "wireguard" "$listen" "$port" ""
  printf "  Server PrivateKey: %s\n" "$server_priv"
  printf "  Server PublicKey : %s\n\n" "$server_pub"
  warn "客户端还需要完整 WireGuard 地址/路由设计；本项只生成 Xray 入站。"
}

add_tunnel() {
  need_xray || return
  local tag listen port network target target_port json
  TRANSPORT="tunnel"
  TRANSPORT_PATH=""; TRANSPORT_HOST=""; GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  tag="$(ask_tag "tunnel")"
  listen="$(ask_default "本地监听地址" "127.0.0.1")"
  port="$(ask_port "本地监听端口" "25565")"
  warn_port "$port" || return
  network="$(ask_default "网络 tcp / udp / tcp,udp" "tcp")"
  [[ "$network" == "tcp" || "$network" == "udp" || "$network" == "tcp,udp" ]] || network="tcp"
  target="$(ask_required "转发目标域名/IP")"
  target_port="$(ask_port "转发目标端口" "$port")"

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg network "$network" --arg target "$target" --argjson target_port "$target_port" '
    {inbounds:[{
      tag:$tag,listen:$listen,port:$port,protocol:"tunnel",
      settings:{
        allowedNetwork:$network,
        rewriteAddress:$target,
        rewritePort:$target_port,
        followRedirect:false,
        userLevel:0
      }
    }]}')"

  safe_write_inbound "$tag" "$json" || return
  if [[ "$listen" != "127.0.0.1" && "$listen" != "::1" ]]; then
    maybe_ufw_for_transport "$port" "raw" "tunnel"
  fi
  show_created_summary "$tag" "tunnel" "$listen" "$port" ""
}

add_tun() {
  need_xray || return
  local tag name mtu gw4 gw6 routes json
  TRANSPORT="tun"

  warn "TUN 是本机透明接管/路由功能，不是给远程客户端连接的代理协议。"
  warn "错误的全局路由可能造成 VPS 失联；默认仅创建接口，不自动接管 0.0.0.0/0。"
  confirm "理解并继续？" || return

  tag="$(ask_tag "tun-local")"
  name="$(ask_default "TUN 接口名" "xraytun0")"
  mtu="$(ask_default "MTU" "1500")"
  [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1500
  gw4="$(ask_default "IPv4 gateway CIDR" "10.66.0.1/30")"
  gw6="$(ask_default "IPv6 gateway CIDR（留空则不加）" "")"

  routes='[]'
  if confirm "让 Xray 自动添加系统路由？（VPS 上建议先选 N）"; then
    warn "不要直接在远程 VPS 上盲目接管默认路由，否则可能把 SSH 也卷进 TUN。"
    local route_text
    route_text="$(ask_default "CIDR，逗号分隔" "10.0.0.0/8")"
    routes="$(jq -cn --arg s "$route_text" '$s|split(",")')"
  fi

  json="$(jq -cn \
    --arg tag "$tag" --arg name "$name" --arg gw4 "$gw4" --arg gw6 "$gw6" \
    --argjson mtu "$mtu" --argjson routes "$routes" '
    {
      inbounds:[
        {
          tag:$tag,
          protocol:"tun",
          settings:(
            {
              name:$name,
              mtu:$mtu,
              gateway:(if $gw6=="" then [$gw4] else [$gw4,$gw6] end),
              userLevel:0
            }
            + (if ($routes|length)>0 then {autoSystemRoutingTable:$routes,autoOutboundsInterface:"auto"} else {} end)
          )
        }
      ]
    }')"

  safe_write_inbound "$tag" "$json" || return
  ok "TUN 入站已创建。请自行确认 Linux 路由表后再扩大接管范围。"
}

import_custom_json() {
  need_xray || return
  local tag tmp input json
  tag="$(ask_tag "custom")"
  echo
  echo '请粘贴“单个 InboundObject”JSON，例如：'
  echo '{"tag":"custom","listen":"0.0.0.0","port":12345,"protocol":"...","settings":{}}'
  echo "输入完成后按 Ctrl-D："

  tmp="$(mktemp)"
  cat >"$tmp"
  input="$(cat "$tmp")"
  rm -f "$tmp"

  jq -e 'type=="object"' >/dev/null <<<"$input" || {
    err "输入不是有效 JSON 对象。"
    return
  }

  # Force the selected manager tag so filename, list and delete operations stay consistent.
  json="$(jq -cn --argjson inbound "$input" --arg tag "$tag" '
    {inbounds:[($inbound + {tag:$tag})]}')"

  safe_write_inbound "$tag" "$json"
}

add_inbound_menu() {
  while true; do
    clear || true
    echo "========== 添加 Xray 入站 =========="
    echo "1) VLESS（RAW/XHTTP/gRPC/WS/HTTPUpgrade/mKCP；REALITY/TLS）"
    echo "2) VMess（多传输；TLS/none）"
    echo "3) Trojan（多传输；TLS）"
    echo "4) Shadowsocks 2022 / AEAD"
    echo "5) Hysteria2"
    echo "6) SOCKS5（默认本机）"
    echo "7) HTTP Proxy（默认本机）"
    echo "8) WireGuard Inbound"
    echo "9) Tunnel / 端口映射"
    echo "10) TUN（高级，本机路由）"
    echo "11) 自定义 Inbound JSON（覆盖未来/冷门功能）"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) add_vless; pause ;;
      2) add_vmess; pause ;;
      3) add_trojan; pause ;;
      4) add_shadowsocks; pause ;;
      5) add_hysteria2; pause ;;
      6) add_socks; pause ;;
      7) add_http; pause ;;
      8) add_wireguard; pause ;;
      9) add_tunnel; pause ;;
      10) add_tun; pause ;;
      11) import_custom_json; pause ;;
      0) return ;;
    esac
  done
}

list_inbounds() {
  ensure_layout
  local found=0 f
  printf "\n%-24s %-14s %-16s %-8s %-12s %-10s\n" "TAG" "PROTOCOL" "LISTEN" "PORT" "TRANSPORT" "SECURITY"
  printf "%-24s %-14s %-16s %-8s %-12s %-10s\n" "------------------------" "--------------" "----------------" "--------" "------------" "----------"
  shopt -s nullglob
  for f in "$CONF_DIR"/10_inbound_*.json; do
    found=1
    jq -r '
      .inbounds[]? |
      [
        (.tag // "-"),
        (.protocol // "-"),
        (.listen // "-"),
        ((.port // "-")|tostring),
        (.streamSettings.method // .streamSettings.network // "-"),
        (.streamSettings.security // "-")
      ] | @tsv' "$f" 2>/dev/null |
    while IFS=$'\t' read -r tag proto listen port transport security; do
      printf "%-24s %-14s %-16s %-8s %-12s %-10s\n" "$tag" "$proto" "$listen" "$port" "$transport" "$security"
    done
  done
  shopt -u nullglob
  (( found )) || echo "暂无由本脚本管理的入站。"
  echo
}

show_inbound_details() {
  list_inbounds
  local tag f
  tag="$(ask_required "输入要查看的 Tag")"
  f="$(grep -Rl --include='10_inbound_*.json' "\"tag\"[[:space:]]*:[[:space:]]*\"$tag\"" "$CONF_DIR" 2>/dev/null | head -n 1 || true)"
  [[ -n "$f" ]] || { err "未找到。"; return; }
  if confirm "显示完整敏感信息（UUID、密码、REALITY 私钥等）？"; then
    warn "请勿截图、录屏或把完整输出粘贴到公开位置。"
    jq . "$f"
  else
    info "已默认脱敏；如确需完整值，请重新进入并明确确认。"
    jq '
      def sensitive_key:
        . == "id" or . == "password" or . == "privatekey" or
        . == "publickey" or . == "auth" or . == "shortids" or
        . == "key";
      walk(
        if type == "object" then
          with_entries(
            if (.key | ascii_downcase | sensitive_key) then
              .value = "<redacted>"
            else . end
          )
        else . end
      )
    ' "$f"
  fi
}

delete_inbound() {
  need_xray || return
  list_inbounds
  local tag file backup tmp
  tag="$(ask_required "输入要删除的 Tag")"
  file="$(grep -Rl --include='10_inbound_*.json' "\"tag\"[[:space:]]*:[[:space:]]*\"$tag\"" "$CONF_DIR" 2>/dev/null | head -n 1 || true)"
  [[ -n "$file" ]] || { err "未找到 Tag：$tag"; return; }

  confirm "确认删除 $tag？" || return
  backup="$(backup_now)"
  tmp="$(mktemp)"
  rm -f "$tmp"
  mv "$file" "$tmp"

  if test_config && service_restart; then
    rm -f "$tmp"
    ok "已删除：$tag"
    info "备份：$backup"
  else
    err "删除后配置/服务异常，正在回滚。"
    mv "$tmp" "$file"
    service_restart || true
  fi
}

update_xray() {
  need_xray || return
  ensure_layout
  load_network_state
  if uses_cloudflare_distribution; then
    info "更新来源为 Cloudflare，不访问 GitHub/XTLS。"
    cloudflare_install_or_update_xray
    return
  fi
  prepare_download_network || return 1
  pkg_install_base

  local tmp
  tmp="$(mktemp -d)"

  if [[ "$INIT_SYS" == "systemd" ]]; then
    download_to_tmp "$OFFICIAL_INSTALLER" "$tmp/install-release.sh"
    run_systemd_installer "$tmp/install-release.sh" install
  elif [[ "$INIT_SYS" == "openrc" && "$PKG_MGR" == "apk" ]]; then
    download_to_tmp "$OFFICIAL_ALPINE_INSTALLER" "$tmp/install-release.sh"
    run_alpine_installer "$tmp/install-release.sh"
    configure_openrc_confdir
  else
    err "当前系统无法自动更新。"
    return 1
  fi

  ensure_layout
  test_config && service_restart
  rm -rf "$tmp"
  ok "Xray 更新完成。"
  "$XRAY_BIN" version 2>/dev/null | head -n 1 || "$XRAY_BIN" -version 2>/dev/null | head -n 1 || true
}

update_geodata() {
  need_xray || return
  ensure_layout
  load_network_state
  if uses_cloudflare_distribution; then
    info "更新来源为 Cloudflare，不访问 GitHub/XTLS。"
    cloudflare_update_geodata
    return
  fi
  prepare_download_network || return 1
  local tmp
  tmp="$(mktemp -d)"

  if [[ "$INIT_SYS" == "systemd" ]]; then
    download_to_tmp "$OFFICIAL_INSTALLER" "$tmp/install-release.sh"
    run_systemd_installer "$tmp/install-release.sh" install-geodata
  elif [[ "$INIT_SYS" == "openrc" && "$PKG_MGR" == "apk" ]]; then
    warn "XTLS 的 Alpine 安装器没有单独 install-geodata 动作，将更新 Xray + GeoIP + GeoSite。"
    download_to_tmp "$OFFICIAL_ALPINE_INSTALLER" "$tmp/install-release.sh"
    run_alpine_installer "$tmp/install-release.sh"
    configure_openrc_confdir
  else
    err "当前系统无法自动更新 GeoData。"
    return 1
  fi

  service_restart || true
  rm -rf "$tmp"
  ok "GeoIP / GeoSite 更新完成。"
  ls -lh "$ASSET_DIR/geoip.dat" "$ASSET_DIR/geosite.dat" 2>/dev/null || true
}

detect_ssh_port() {
  local p=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
  fi
  if [[ -z "$p" ]] && command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)"
  fi
  [[ "$p" =~ ^[0-9]+$ ]] || p=22
  printf '%s' "$p"
}

install_ufw() {
  if command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  info "安装 UFW..."
  case "$PKG_MGR" in
    apt) pkg_install_optional ufw ;;
    pacman) pkg_install_optional ufw ;;
    apk) pkg_install_optional ufw ;;
    zypper) pkg_install_optional ufw ;;
    dnf|yum)
      if ! pkg_install_optional ufw; then
        err "当前 RPM 软件源没有 UFW。请配置发行版合适的软件源，或继续使用 firewalld。"
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

ufw_allow_if_active() {
  local port="$1" proto="${2:-tcp}"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw allow "$port/$proto" >/dev/null 2>&1 || true
}

ufw_safe_enable() {
  install_ufw || return
  local ssh_port
  ssh_port="$(detect_ssh_port)"

  if has_global_ipv6 && [[ -f /etc/default/ufw ]]; then
    if grep -q '^IPV6=no' /etc/default/ufw 2>/dev/null; then
      sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
      info "检测到 IPv6 网络，已将 UFW 的 IPV6=yes 打开。"
    fi
  fi

  if [[ "$INIT_SYS" == "systemd" ]] && systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "检测到 firewalld 正在运行。UFW 与 firewalld 同时管理规则容易冲突。"
    if confirm "停止并禁用 firewalld，改用 UFW？"; then
      systemctl disable --now firewalld
    else
      warn "已取消启用 UFW。"
      return
    fi
  fi

  info "先放行当前 SSH 端口：$ssh_port/tcp"
  ufw allow "$ssh_port/tcp"
  ufw default deny incoming
  ufw default allow outgoing

  if confirm "现在启用 UFW？"; then
    ufw --force enable
    ok "UFW 已启用。"
    ufw status verbose
  fi
}

ufw_add_rule() {
  install_ufw || return
  local port proto
  port="$(ask_port "端口" "443")"
  proto="$(ask_default "协议 tcp / udp" "tcp")"
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || proto="tcp"
  ufw allow "$port/$proto"
  ufw status numbered
}

ufw_delete_rule() {
  command -v ufw >/dev/null 2>&1 || { warn "未安装 UFW。"; return; }
  ufw status numbered
  local n
  n="$(ask_required "输入要删除的规则编号")"
  [[ "$n" =~ ^[0-9]+$ ]] || { err "编号无效。"; return; }
  ufw --force delete "$n"
}

ufw_menu() {
  while true; do
    clear || true
    echo "========== UFW =========="
    echo "1) 安装并安全启用（先放行当前 SSH）"
    echo "2) 查看状态/规则"
    echo "3) 放行端口"
    echo "4) 删除规则"
    echo "5) 禁用 UFW"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) ufw_safe_enable; pause ;;
      2) command -v ufw >/dev/null && ufw status verbose || warn "未安装 UFW"; pause ;;
      3) ufw_add_rule; pause ;;
      4) ufw_delete_rule; pause ;;
      5)
        if command -v ufw >/dev/null && confirm "确认禁用 UFW？"; then ufw disable; fi
        pause
        ;;
      0) return ;;
    esac
  done
}

enable_bbr() {
  local available current
  command -v sysctl >/dev/null 2>&1 || { err "缺少 sysctl/procps。"; return 1; }

  modprobe tcp_bbr 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<<"$available"; then
    err "当前内核没有提供 BBR。"
    uname -a
    warn "本脚本不会为兼容性而自动更换内核；请先升级到发行版支持 BBR 的内核。"
    return 1
  fi

  cat >/etc/sysctl.d/99-xray-bbr.conf <<'EOF'
# Managed by xray-manager
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null

  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ "$current" == "bbr" ]]; then
    ok "BBR 已启用。"
  else
    warn "已写入 sysctl，但当前算法为：$current"
  fi
  printf "qdisc: %s\n" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  printf "available: %s\n" "$available"
}

bbr_status() {
  echo "Kernel: $(uname -r)"
  echo "Current CC : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  echo "Available  : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '?')"
  echo "Qdisc      : $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  lsmod 2>/dev/null | grep -E '^tcp_bbr\b' || true
}

restore_backup() {
  need_xray || return
  local files=() f i choice selected tmp
  shopt -s nullglob
  for f in "$BACKUP_DIR"/xray-config-*.tar.gz; do files+=("$f"); done
  shopt -u nullglob

  ((${#files[@]} > 0)) || { warn "没有备份。"; return; }

  for i in "${!files[@]}"; do
    printf "%d) %s\n" "$((i+1))" "$(basename "${files[$i]}")"
  done
  choice="$(ask_required "选择备份编号")"
  [[ "$choice" =~ ^[0-9]+$ ]] || { err "无效编号。"; return; }
  (( choice >= 1 && choice <= ${#files[@]} )) || { err "超出范围。"; return; }
  selected="${files[$((choice-1))]}"

  tmp="$(mktemp -d)"
  tar -xzf "$selected" -C "$tmp"
  [[ -d "$tmp/$(basename "$CONF_DIR")" ]] || { rm -rf "$tmp"; err "备份结构无效。"; return; }

  if ! test_config_dir "$tmp/$(basename "$CONF_DIR")"; then
    rm -rf "$tmp"
    err "备份中的配置测试失败，拒绝恢复。"
    return
  fi

  confirm "确认恢复 $(basename "$selected")？当前配置会先再备份一次。" || { rm -rf "$tmp"; return; }
  backup_now >/dev/null

  rm -rf "$CONF_DIR"
  cp -a "$tmp/$(basename "$CONF_DIR")" "$CONF_DIR"
  if [[ -d "$tmp/$(basename "$CERT_DIR")" ]]; then
    rm -rf "$CERT_DIR"
    cp -a "$tmp/$(basename "$CERT_DIR")" "$CERT_DIR"
  fi
  rm -rf "$tmp"

  ensure_layout
  service_restart
  ok "恢复完成。"
}

backup_menu() {
  while true; do
    clear || true
    echo "========== 备份 / 恢复 =========="
    echo "1) 立即备份"
    echo "2) 查看备份"
    echo "3) 恢复备份"
    echo "0) 返回"
    local c f
    read -r -p "请选择: " c || true
    case "$c" in
      1) f="$(backup_now)"; ok "已备份：$f"; pause ;;
      2) ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "暂无备份"; pause ;;
      3) restore_backup; pause ;;
      0) return ;;
    esac
  done
}

service_menu() {
  while true; do
    clear || true
    echo "========== Xray 服务 / 诊断 =========="
    echo "1) 配置测试"
    echo "2) 重启 Xray"
    echo "3) 启动 Xray"
    echo "4) 停止 Xray"
    echo "5) 服务状态"
    echo "6) 查看日志"
    echo "7) 查看版本"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) need_xray && test_config; pause ;;
      2) need_xray && service_restart && ok "已重启"; pause ;;
      3) need_xray && service_start && ok "已启动"; pause ;;
      4) need_xray && service_stop && ok "已停止"; pause ;;
      5) service_status; pause ;;
      6) show_logs; pause ;;
      7) "$XRAY_BIN" version 2>/dev/null || "$XRAY_BIN" -version 2>/dev/null || true; pause ;;
      0) return ;;
    esac
  done
}

certificate_menu() {
  need_xray || return
  local tag
  tag="$(ask_default "证书目录名称" "shared-tls")"
  tls_certificate_wizard "$tag" || return
  echo
  ok "证书准备完成："
  echo "Cert: $MANAGED_CERT"
  echo "Key : $MANAGED_KEY"
}

system_info() {
  echo "Script       : $SCRIPT_VERSION"
  echo "OS           : $OS_ID ${OS_LIKE:+($OS_LIKE)}"
  echo "Init         : $INIT_SYS"
  echo "Package mgr  : $PKG_MGR"
  echo "Kernel       : $(uname -r)"
  echo "Arch         : $(uname -m)"
  echo "Config dir   : $CONF_DIR"
  echo "Asset dir    : $ASSET_DIR"
  echo "Run group    : $XRAY_RUN_GROUP"
  echo "Network      : $(network_stack_label)"
  echo "DNS64        : $([[ -s "$DNS64_STATE_FILE" ]] && echo enabled-by-script || echo default)"
  echo "Dl proxy     : $([[ -n "${DOWNLOAD_PROXY:-}" ]] && echo configured || echo none)"
  echo "Dl source    : ${UPDATE_SOURCE:-official}"
  if xray_exists; then
    "$XRAY_BIN" version 2>/dev/null | head -n 1 || "$XRAY_BIN" -version 2>/dev/null | head -n 1 || true
  else
    echo "Xray         : 未安装"
  fi
  echo "BBR          : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  if command -v ufw >/dev/null 2>&1; then
    ufw status | head -n 1
  else
    echo "UFW          : 未安装"
  fi
}

main_menu() {
  while true; do
    clear || true
    printf "${C_CYAN}${C_BOLD}Xray Manager %s${C_RESET}\n" "$SCRIPT_VERSION"
    echo "=================================================="
    echo "1) 一键安装 / 修复 Xray"
    echo "2) 添加入站协议"
    echo "3) 查看入站列表"
    echo "4) 查看某入站完整配置"
    echo "5) 删除入站"
    echo "6) 更新 Xray-core"
    echo "7) 更新 GeoIP / GeoSite"
    echo "8) UFW 防火墙"
    echo "9) BBR"
    echo "10) TLS 证书管理"
    echo "11) Xray 服务 / 配置测试 / 日志"
    echo "12) 备份 / 恢复"
    echo "13) 系统信息"
    echo "14) IPv6-only / NAT64 网络助手"
    echo "15) 完全离线安装 / 导入 Xray + GeoData"
    echo "0) 退出"
    echo "=================================================="

    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) install_or_repair_xray; pause ;;
      2) add_inbound_menu ;;
      3) list_inbounds; pause ;;
      4) show_inbound_details; pause ;;
      5) delete_inbound; pause ;;
      6) update_xray; pause ;;
      7) update_geodata; pause ;;
      8) ufw_menu ;;
      9)
        echo "1) 启用/修复 BBR  2) 查看 BBR 状态"
        read -r -p "请选择 [1]: " c || true
        if [[ "${c:-1}" == "2" ]]; then bbr_status; else enable_bbr; fi
        pause
        ;;
      10) certificate_menu; pause ;;
      11) service_menu ;;
      12) backup_menu ;;
      13) system_info; pause ;;
      14) ipv6_only_menu ;;
      15) offline_import_menu; pause ;;
      0) echo "Bye."; exit 0 ;;
      *) warn "无效选择。"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  require_root
  detect_platform
  ensure_layout
  load_network_state
  main_menu
fi
