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

SCRIPT_VERSION="1.8.2"
XRAY_BIN="/usr/local/bin/xray"
XRAY_ROOT="/usr/local/etc/xray"
CONF_DIR="${XRAY_ROOT}/conf.d"
CERT_DIR="${XRAY_ROOT}/certs"
ASSET_DIR="/usr/local/share/xray"
LOG_DIR="/var/log/xray"
STATE_DIR="/etc/xray-manager"
BACKUP_DIR="${STATE_DIR}/backups"
BASE_FILE="${CONF_DIR}/00_base.json"
ROUTING_FILE="${CONF_DIR}/30_routing.json"
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
LOCK_DIR="${XRAY_MANAGER_LOCK_DIR:-/run/xray-manager.lock}"
MANAGER_LOCK_HELD=0

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

tag_exists() {
  local tag="$1"
  grep -Rqs --include='*.json' "\"tag\"[[:space:]]*:[[:space:]]*\"$tag\"" "$CONF_DIR" 2>/dev/null
}

ask_named_tag() {
  local kind="$1" default="$2" t
  while true; do
    t="$(ask_default "${kind}名称/Tag" "$default")"
    t="$(sanitize_tag "$t")"
    if ! tag_exists "$t"; then
      printf '%s' "$t"
      return 0
    fi
    warn "Tag '$t' 已存在，请换一个。"
  done
}

ask_tag() {
  ask_named_tag "入站" "$1"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
  [[ -n "${BASH_VERSION:-}" ]] || die "本脚本需要 Bash。"
}

acquire_manager_lock() {
  local operation="$1" owner_pid owner_operation owner_started
  if mkdir -m 700 "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "${BASHPID:-$$}" >"$LOCK_DIR/pid"
    printf '%s\n' "$operation" >"$LOCK_DIR/operation"
    date -u +%Y-%m-%dT%H:%M:%SZ >"$LOCK_DIR/started"
    MANAGER_LOCK_HELD=1
    return 0
  fi

  owner_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  owner_operation="$(cat "$LOCK_DIR/operation" 2>/dev/null || printf unknown)"
  owner_started="$(cat "$LOCK_DIR/started" 2>/dev/null || printf unknown)"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    err "Xray Manager 正在执行：$owner_operation（PID $owner_pid，开始于 $owner_started）。"
    return 1
  fi

  warn "发现已失效的 Xray Manager 锁，正在安全清理。"
  rm -f "$LOCK_DIR/pid" "$LOCK_DIR/operation" "$LOCK_DIR/started"
  rmdir "$LOCK_DIR" 2>/dev/null || {
    err "锁目录包含未知文件，拒绝清理：$LOCK_DIR"
    return 1
  }
  mkdir -m 700 "$LOCK_DIR" || return 1
  printf '%s\n' "${BASHPID:-$$}" >"$LOCK_DIR/pid"
  printf '%s\n' "$operation" >"$LOCK_DIR/operation"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$LOCK_DIR/started"
  MANAGER_LOCK_HELD=1
}

release_manager_lock() {
  (( MANAGER_LOCK_HELD )) || return 0
  if [[ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" == "${BASHPID:-$$}" ]]; then
    rm -f "$LOCK_DIR/pid" "$LOCK_DIR/operation" "$LOCK_DIR/started"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  MANAGER_LOCK_HELD=0
}

with_manager_lock() (
  local operation="$1"
  shift
  acquire_manager_lock "$operation" || return 1
  trap release_manager_lock EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  "$@"
)

OS_ID="unknown"
OS_LIKE=""
PKG_MGR=""
INIT_SYS=""
XRAY_RUN_USER=""
XRAY_RUN_GROUP=""

detect_xray_run_identity() {
  local service_user="" service_group=""

  if [[ "$INIT_SYS" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
    service_user="$(systemctl show xray -p User --value 2>/dev/null || true)"
    service_group="$(systemctl show xray -p Group --value 2>/dev/null || true)"
  fi

  if [[ -z "$service_user" ]] || ! id "$service_user" >/dev/null 2>&1; then
    if id nobody >/dev/null 2>&1; then
      service_user="nobody"
    else
      service_user="root"
    fi
  fi

  if [[ -z "$service_group" ]] || ! getent group "$service_group" >/dev/null 2>&1; then
    service_group="$(id -gn "$service_user" 2>/dev/null || true)"
  fi

  XRAY_RUN_USER="${service_user:-root}"
  XRAY_RUN_GROUP="${service_group:-root}"
}

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

  detect_xray_run_identity
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

ensure_runtime_dependencies() {
  local command_name
  local -a missing=()

  for command_name in curl jq openssl unzip ip ss ps tar gzip base64; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  (( ${#missing[@]} == 0 )) && return 0

  warn "检测到缺失的运行依赖：$(printf '%s ' "${missing[@]}")"
  pkg_install_base
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
  local run_user="${XRAY_RUN_USER:-root}"
  local run_group="${XRAY_RUN_GROUP:-$(id -gn "$run_user" 2>/dev/null || printf 'root')}"

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
  chown root:"$run_group" "$LOG_DIR" 2>/dev/null || true
  chmod 750 "$LOG_DIR" 2>/dev/null || true
  chown "$run_user":"$run_group" "$LOG_DIR/access.log" "$LOG_DIR/error.log" 2>/dev/null || true
  chmod 600 "$LOG_DIR/access.log" "$LOG_DIR/error.log" 2>/dev/null || true
  chown root:"$run_group" "$XRAY_ROOT" "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
  chmod 750 "$XRAY_ROOT" "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
  find "$CONF_DIR" -maxdepth 1 -type f -name '*.json' -exec chown root:"$run_group" {} \; -exec chmod 640 {} \; 2>/dev/null || true
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

extract_xray_binary_from_command() {
  local command_line="$1" token
  local -a tokens=()
  local IFS=' '

  command_line="${command_line//;/ }"
  command_line="${command_line//\{/ }"
  command_line="${command_line//\}/ }"
  read -r -a tokens <<<"$command_line"

  for token in "${tokens[@]}"; do
    token="${token//\"/}"
    token="${token//\'/}"
    case "$token" in
      path=*|argv\[\]=*|command=*) token="${token#*=}" ;;
    esac
    if [[ "${token##*/}" == "xray" && -x "$token" ]]; then
      printf '%s' "$token"
      return 0
    fi
  done
  return 1
}

discover_existing_xray_binary() {
  local path="${XRAY_MANAGER_LEGACY_XRAY_BIN:-}" command_line=""

  if [[ -n "$path" ]]; then
    [[ -x "$path" ]] || {
      err "指定的旧 Xray 不可执行：$path"
      return 1
    }
    printf '%s' "$path"
    return 0
  fi

  if [[ "$INIT_SYS" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
    command_line="$(systemctl show xray -p ExecStart --value 2>/dev/null || true)"
    path="$(extract_xray_binary_from_command "$command_line" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
      printf '%s' "$path"
      return 0
    fi
  elif [[ "$INIT_SYS" == "openrc" ]]; then
    for path in /etc/conf.d/xray /etc/init.d/xray; do
      [[ -r "$path" ]] || continue
      command_line="$(tr '\n' ' ' <"$path")"
      path="$(extract_xray_binary_from_command "$command_line" 2>/dev/null || true)"
      if [[ -n "$path" ]]; then
        printf '%s' "$path"
        return 0
      fi
    done
  fi

  for path in "$XRAY_BIN" /usr/bin/xray /opt/xray/xray; do
    if [[ -x "$path" ]]; then
      printf '%s' "$path"
      return 0
    fi
  done
  path="$(command -v xray 2>/dev/null || true)"
  [[ -n "$path" && -x "$path" ]] || return 1
  printf '%s' "$path"
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
  local test_xray="${3:-$XRAY_BIN}"
  local stamp backup stage previous first_json

  source="${source%/}"
  echo
  warn "检测到脚本接管前的 Xray 配置：$source"
  echo "迁移目标：$CONF_DIR"
  echo "配置校验：$test_xray"
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
  if [[ -f "$test_xray" ]]; then
    cp -a "$test_xray" "$backup/xray" || true
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

  if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$test_xray" \
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
  local discovered kind source test_xray
  [[ -s "$CONFIG_MIGRATION_STATE_FILE" ]] && return 0

  discovered="$(discover_existing_xray_config || true)"
  [[ -n "$discovered" ]] || return 0
  IFS=$'\t' read -r kind source <<<"$discovered"
  [[ -n "$kind" && -n "$source" ]] || return 0
  test_xray="$(discover_existing_xray_binary || true)"
  if [[ -z "$test_xray" ]]; then
    err "检测到已有 Xray 配置，但找不到可用于校验的旧 Xray，已停止安装/修复。"
    warn "可通过 XRAY_MANAGER_LEGACY_XRAY_BIN=/实际/xray/路径 明确指定。"
    return 1
  fi
  migrate_existing_xray_config "$kind" "$source" "$test_xray"
}

configure_systemd_offline_service() {
  local unit="/etc/systemd/system/xray.service"
  local dropin="/etc/systemd/system/xray.service.d/20-xray-manager-offline.conf"
  local service_user="${XRAY_RUN_USER:-root}"
  local service_group="${XRAY_RUN_GROUP:-root}"

  if [[ ! -f "$unit" && ! -f /usr/lib/systemd/system/xray.service && ! -f /lib/systemd/system/xray.service ]]; then
    cat >"$unit" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=$service_user
Group=$service_group
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
  local service_user="${XRAY_RUN_USER:-root}"
  local service_group="${XRAY_RUN_GROUP:-root}"
  if [[ ! -f /etc/init.d/xray ]]; then
    cat >/etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="$XRAY_BIN"
command_args="run -confdir $CONF_DIR"
command_user="$service_user:$service_group"
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
  local ts stage temp_file token file wireguard_dir xray_version
  ts="$(date +%Y%m%d-%H%M%S)"
  stage="$(mktemp -d "$BACKUP_DIR/.backup-stage.XXXXXX")"
  temp_file="$(mktemp "$BACKUP_DIR/.xray-config-$ts.XXXXXX")"
  token="${temp_file##*.}"
  file="$BACKUP_DIR/xray-config-$ts-$token.tar.gz"
  wireguard_dir="${STATE_DIR}/wireguard"

  rm -f "$temp_file"
  cp -a "$CONF_DIR" "$stage/$(basename "$CONF_DIR")" || {
    rm -rf "$stage"
    err "无法暂存 Xray 配置，备份已取消。"
    return 1
  }
  [[ ! -d "$CERT_DIR" ]] || cp -a "$CERT_DIR" "$stage/$(basename "$CERT_DIR")"
  [[ ! -d "$wireguard_dir" ]] || cp -a "$wireguard_dir" "$stage/wireguard"

  xray_version="$(
    "$XRAY_BIN" version 2>/dev/null | head -n 1 ||
      "$XRAY_BIN" -version 2>/dev/null | head -n 1 || true
  )"
  jq -n \
    --arg format "1" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg manager_version "$SCRIPT_VERSION" \
    --arg xray_version "$xray_version" \
    --argjson certificates "$([[ -d "$CERT_DIR" ]] && printf true || printf false)" \
    --argjson wireguard "$([[ -d "$wireguard_dir" ]] && printf true || printf false)" \
    '{
      format: ($format | tonumber),
      createdAt: $created_at,
      managerVersion: $manager_version,
      xrayVersion: $xray_version,
      includes: {
        configuration: true,
        certificates: $certificates,
        wireguard: $wireguard
      }
    }' >"$stage/backup-manifest.json"

  if ! tar -C "$stage" -czf "$temp_file" .; then
    rm -rf "$stage"
    rm -f "$temp_file"
    err "创建备份压缩包失败。"
    return 1
  fi
  chmod 600 "$temp_file"
  mv "$temp_file" "$file"
  rm -rf "$stage"
  printf '%s' "$file"
}

safe_write_config_file() {
  local filename="$1" json="$2" success_message="$3"
  local tmp backup previous had_previous=0

  [[ "$filename" == "$(basename "$filename")" && "$filename" == *.json ]] || {
    err "拒绝写入不安全的配置文件名：$filename"
    return 1
  }

  ensure_layout

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
  previous="$(mktemp)"
  if [[ -f "$CONF_DIR/$filename" ]]; then
    cp -a "$CONF_DIR/$filename" "$previous"
    had_previous=1
  fi
  cp "$tmp/$filename" "$CONF_DIR/$filename"
  rm -rf "$tmp"

  chown root:"$XRAY_RUN_GROUP" "$CONF_DIR/$filename" 2>/dev/null || true
  chmod 640 "$CONF_DIR/$filename" 2>/dev/null || true

  if service_restart; then
    rm -f "$previous"
    ok "$success_message"
    info "自动备份：$backup"
  else
    err "服务重启失败，正在回滚..."
    if (( had_previous )); then
      cp -a "$previous" "$CONF_DIR/$filename"
    else
      rm -f "$CONF_DIR/$filename"
    fi
    rm -f "$previous"
    service_restart || true
    return 1
  fi
}

safe_write_inbound() {
  local tag="$1" json="$2"
  safe_write_config_file \
    "10_inbound_$(sanitize_tag "$tag").json" \
    "$json" \
    "已添加入站：$tag"
}

safe_remove_config_file() {
  local file="$1" success_message="$2" backup held
  [[ -f "$file" && "$file" == "$CONF_DIR/"*.json ]] || {
    err "目标不是可管理的配置文件。"
    return 1
  }

  backup="$(backup_now)"
  held="$(mktemp)"
  mv "$file" "$held"

  info "测试删除后的完整配置..."
  if test_config && service_restart; then
    rm -f "$held"
    ok "$success_message"
    info "自动备份：$backup"
    return 0
  fi

  err "删除后配置或服务异常，正在回滚..."
  mv "$held" "$file"
  service_restart || true
  return 1
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

generate_shadowsocks_secret() {
  local method="$1" keylen
  case "$method" in
    2022-blake3-aes-128-gcm) keylen=16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) keylen=32 ;;
    *) random_secret; return ;;
  esac
  openssl rand -base64 "$keylen" | tr -d '\n'
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

managed_ufw_comment() {
  local tag="$1" protocol="$2"
  printf 'XrayManager:%s:%s' "$(sanitize_tag "$tag")" "$protocol"
}

managed_ufw_allow() {
  local port="$1" protocol="$2" tag="${3:-}" comment="Xray"
  [[ -n "$tag" ]] && comment="$(managed_ufw_comment "$tag" "$protocol")"
  ufw allow "$port/$protocol" comment "$comment" >/dev/null 2>&1 || \
    ufw allow "$port/$protocol" >/dev/null 2>&1 || true
}

remove_managed_ufw_rules() {
  local tag="$1" port="$2" protocol comment status
  command -v ufw >/dev/null 2>&1 || return 0
  status="$(ufw status 2>/dev/null || true)"
  [[ "$status" == *"Status: active"* ]] || return 0

  for protocol in tcp udp; do
    comment="$(managed_ufw_comment "$tag" "$protocol")"
    if printf '%s\n' "$status" | grep -F -- "$comment" | \
       grep -Eq "(^|[[:space:]])${port}/${protocol}([[:space:]]|$)"; then
      ufw --force delete allow "$port/$protocol" >/dev/null 2>&1 || \
        warn "无法自动清理由管理器创建的 UFW 规则：$port/$protocol"
    fi
  done
  return 0
}

maybe_ufw_for_transport() {
  local port="$1" transport="$2" protocol="${3:-}" tag="${4:-}"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0

  if [[ "$transport" == "mkcp" || "$transport" == "hysteria" || "$protocol" == "wireguard" ]]; then
    managed_ufw_allow "$port" udp "$tag"
  elif [[ "$protocol" == "shadowsocks" ]]; then
    managed_ufw_allow "$port" tcp "$tag"
    managed_ufw_allow "$port" udp "$tag"
  else
    managed_ufw_allow "$port" tcp "$tag"
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
  maybe_ufw_for_transport "$port" "$TRANSPORT" "vless" "$tag"
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
  maybe_ufw_for_transport "$port" "$TRANSPORT" "vmess" "$tag"
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
  maybe_ufw_for_transport "$port" "$TRANSPORT" "trojan" "$tag"
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

  password="$(generate_shadowsocks_secret "$method")"
  if (( keylen > 0 )); then
    info "已随机生成与加密方式匹配的 SS2022 PSK；末尾 = 或 == 只是 Base64 填充。"
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
  maybe_ufw_for_transport "$port" "native" "shadowsocks" "$tag"
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
  maybe_ufw_for_transport "$port" "hysteria" "hysteria" "$tag"
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

validate_wireguard_key() {
  local value="$1" decoded
  [[ "$value" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  decoded="$(printf '%s' "$value" | base64 --decode 2>/dev/null |
    wc -c | tr -d '[:space:]')" || return 1
  [[ "$decoded" == "32" ]]
}

ask_wireguard_key() {
  local prompt="$1" value
  while true; do
    value="$(ask_required "$prompt")"
    if validate_wireguard_key "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "WireGuard 密钥必须是编码后长度为 44 位的标准 Base64 32 字节密钥。"
  done
}

validate_ipv4_address() {
  local address="$1" part
  local -a parts=()
  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<<"$address"
  (( ${#parts[@]} == 4 )) || return 1
  for part in "${parts[@]}"; do
    (( ${#part} <= 3 && 10#$part <= 255 )) || return 1
  done
}

validate_ipv6_address() {
  local address="$1" tail part compressed=0 count=0
  local -a parts=()
  [[ "$address" == *:* && "$address" =~ ^[[:xdigit:]:.]+$ ]] || return 1
  [[ "$address" != *:::* ]] || return 1
  if [[ "$address" == *.* ]]; then
    tail="${address##*:}"
    validate_ipv4_address "$tail" || return 1
    address="${address%:*}:0:0"
  fi
  if [[ "$address" == *::* ]]; then
    tail="${address#*::}"
    [[ "$tail" != *::* ]] || return 1
    compressed=1
  else
    [[ "$address" != :* && "$address" != *: ]] || return 1
  fi
  IFS=: read -r -a parts <<<"$address"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    [[ "$part" =~ ^[[:xdigit:]]{1,4}$ ]] || return 1
    count=$((count + 1))
  done
  if (( compressed )); then
    (( count < 8 ))
  else
    (( count == 8 ))
  fi
}

validate_wireguard_cidr() {
  local value="$1" address prefix
  [[ "$value" == */* ]] || return 1
  address="${value%/*}"
  prefix="${value##*/}"
  [[ -n "$address" && "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
  if [[ "$address" == *:* ]]; then
    validate_ipv6_address "$address" && (( 10#$prefix <= 128 ))
  else
    validate_ipv4_address "$address" && (( 10#$prefix <= 32 ))
  fi
}

validate_wireguard_cidr_list() {
  local value="$1" item count=0
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    validate_wireguard_cidr "$item" || return 1
    count=$((count + 1))
  done < <(jq -r '.[]' <<<"$(csv_to_json_array "$value")")
  (( count > 0 ))
}

ask_wireguard_cidrs() {
  local prompt="$1" default="$2" value
  while true; do
    value="$(ask_default "$prompt" "$default")"
    if validate_wireguard_cidr_list "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "请输入有效的 IPv4/IPv6 CIDR，多个地址用逗号分隔。"
  done
}

validate_wireguard_endpoint() {
  local endpoint="$1" host port
  if [[ "$endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    validate_ipv6_address "$host" || return 1
  elif [[ "$endpoint" =~ ^([^:[:space:]]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    [[ -n "$host" ]] || return 1
  else
    return 1
  fi
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

ask_wireguard_endpoint() {
  local prompt="$1" default="$2" value
  while true; do
    value="$(ask_default "$prompt" "$default")"
    if validate_wireguard_endpoint "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "Endpoint 必须是 域名:端口、IPv4:端口 或 [IPv6]:端口。"
  done
}

ask_wireguard_mtu() {
  local prompt="${1:-MTU}" default="${2:-1280}" value
  while true; do
    value="$(ask_default "$prompt" "$default")"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value >= 576 && 10#$value <= 9000 )); then
      printf '%s' "$((10#$value))"
      return 0
    fi
    warn "WireGuard MTU 必须在 576-9000 之间；IPv6 建议不低于 1280。"
  done
}

ask_wireguard_keepalive() {
  local prompt="${1:-KeepAlive 秒数}" default="${2:-0}" value
  while true; do
    value="$(ask_default "$prompt" "$default")"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value <= 65535 )); then
      printf '%s' "$((10#$value))"
      return 0
    fi
    warn "KeepAlive 必须是 0-65535 之间的整数；NAT 场景通常使用 25。"
  done
}

wireguard_profile_directory() {
  printf '%s/wireguard/%s' "$STATE_DIR" "$(sanitize_tag "$1")"
}

wireguard_profile_path() {
  local tag="$1" public_key="$2" digest
  digest="$(printf '%s' "$public_key" | openssl dgst -sha256 | awk '{print $NF}')"
  printf '%s/%s.json' "$(wireguard_profile_directory "$tag")" "$digest"
}

wireguard_save_profile() {
  local tag="$1" label="$2" public_key="$3" private_key="$4" addresses="$5"
  local endpoint_host="$6" dns="$7" allowed="$8" keepalive="$9"
  local server_public="${10}" dir file tmp
  dir="$(wireguard_profile_directory "$tag")"
  mkdir -p "$dir"
  chmod 700 "${STATE_DIR}/wireguard" "$dir"
  file="$(wireguard_profile_path "$tag" "$public_key")"
  tmp="$(mktemp "$dir/.peer.XXXXXX")"
  chmod 600 "$tmp"
  jq -n \
    --arg label "$label" --arg public "$public_key" --arg private "$private_key" \
    --arg addresses "$addresses" --arg endpoint "$endpoint_host" --arg dns "$dns" \
    --arg allowed "$allowed" --arg server "$server_public" \
    --argjson keepalive "$keepalive" '
      {
        label:$label,publicKey:$public,privateKey:$private,address:$addresses,
        endpointHost:$endpoint,dns:$dns,allowedIPs:$allowed,
        keepAlive:$keepalive,serverPublicKey:$server
      }
    ' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
  chmod 600 "$file"
}

wireguard_peer_label() {
  local tag="$1" public_key="$2" index="$3" profile
  profile="$(wireguard_profile_path "$tag" "$public_key")"
  if [[ -r "$profile" ]]; then
    jq -r --arg fallback "peer-$index" '.label // $fallback' "$profile"
  else
    printf 'peer-%s' "$index"
  fi
}

wireguard_peer_label_exists() {
  local tag="$1" label="$2" ignore="${3:-}" profile
  shopt -s nullglob
  for profile in "$(wireguard_profile_directory "$tag")"/*.json; do
    [[ "$profile" != "$ignore" ]] || continue
    if jq -e --arg label "$label" '.label == $label' "$profile" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

wireguard_next_client_address() {
  local file="$1" number candidate
  for ((number = 2; number <= 254; number++)); do
    candidate="10.66.66.${number}/32"
    if ! jq -e --arg address "$candidate" '
      .inbounds[0].settings.peers[]?.allowedIPs[]? | select(. == $address)
    ' "$file" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  err "10.66.66.0/24 已没有可自动分配的客户端地址。"
  return 1
}

wireguard_ipv4_integer() {
  local address="$1" a b c d
  IFS=. read -r a b c d <<<"$address"
  printf '%s' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

wireguard_ipv6_expanded() {
  local address="${1,,}" left right part tail a b c d missing index output=""
  local -a left_parts=() right_parts=() parts=()
  if [[ "$address" == *.* ]]; then
    tail="${address##*:}"
    IFS=. read -r a b c d <<<"$tail"
    address="${address%:*}:$(printf '%x:%x' \
      "$(( (10#$a << 8) | 10#$b ))" "$(( (10#$c << 8) | 10#$d ))")"
  fi
  if [[ "$address" == *::* ]]; then
    left="${address%%::*}"
    right="${address#*::}"
    [[ -z "$left" ]] || IFS=: read -r -a left_parts <<<"$left"
    [[ -z "$right" ]] || IFS=: read -r -a right_parts <<<"$right"
    missing=$((8 - ${#left_parts[@]} - ${#right_parts[@]}))
    parts=("${left_parts[@]}")
    for ((index = 0; index < missing; index++)); do parts+=(0); done
    parts+=("${right_parts[@]}")
  else
    IFS=: read -r -a parts <<<"$address"
  fi
  for part in "${parts[@]}"; do
    output="${output}$(printf '%04x' "$((16#$part))"):"
  done
  printf '%s' "${output%:}"
}

wireguard_ipv6_prefix_match() {
  local first="$1" second="$2" prefix="$3" full partial index mask
  local -a first_parts=() second_parts=()
  IFS=: read -r -a first_parts <<<"$(wireguard_ipv6_expanded "$first")"
  IFS=: read -r -a second_parts <<<"$(wireguard_ipv6_expanded "$second")"
  full=$((10#$prefix / 16))
  partial=$((10#$prefix % 16))
  for ((index = 0; index < full; index++)); do
    (( 16#${first_parts[index]} == 16#${second_parts[index]} )) || return 1
  done
  if (( partial > 0 )); then
    mask="$(( (0xffff << (16 - partial)) & 0xffff ))"
    (( (16#${first_parts[full]} & mask) == (16#${second_parts[full]} & mask) )) || return 1
  fi
}

wireguard_cidrs_overlap() {
  local first="$1" second="$2" first_address second_address first_prefix second_prefix prefix mask
  first_address="${first%/*}"
  second_address="${second%/*}"
  first_prefix="${first##*/}"
  second_prefix="${second##*/}"
  if [[ "$first_address" == *:* || "$second_address" == *:* ]]; then
    [[ "$first_address" == *:* && "$second_address" == *:* ]] || return 1
    prefix="$first_prefix"
    (( 10#$second_prefix >= 10#$prefix )) || prefix="$second_prefix"
    wireguard_ipv6_prefix_match "$first_address" "$second_address" "$prefix"
    return
  fi
  prefix="$first_prefix"
  (( 10#$second_prefix >= 10#$prefix )) || prefix="$second_prefix"
  if (( 10#$prefix == 0 )); then
    return 0
  fi
  mask="$(( (0xffffffff << (32 - 10#$prefix)) & 0xffffffff ))"
  (( ($(wireguard_ipv4_integer "$first_address") & mask) ==
     ($(wireguard_ipv4_integer "$second_address") & mask) ))
}

wireguard_peer_addresses_available() {
  local file="$1" addresses="$2" ignore="${3:--1}" proposed existing index
  while IFS= read -r proposed; do
    [[ -n "$proposed" ]] || continue
    while IFS=$'\t' read -r index existing; do
      [[ -n "$existing" ]] || continue
      [[ "$index" != "$ignore" ]] || continue
      if wireguard_cidrs_overlap "$proposed" "$existing"; then
        err "客户端地址 $proposed 与已有 Peer $((index + 1)) 的 $existing 冲突。"
        return 1
      fi
    done < <(jq -r '
      (.inbounds[0].settings.peers // []) | to_entries[]? |
      .key as $index | .value.allowedIPs[]? | [$index, .] | @tsv
    ' "$file")
  done < <(jq -r '.[]' <<<"$(csv_to_json_array "$addresses")")
}

wireguard_default_client_routes() {
  local addresses="$1" value ipv4=0 ipv6=0
  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    if [[ "$value" == *:* ]]; then ipv6=1; else ipv4=1; fi
  done < <(jq -r '.[]' <<<"$(csv_to_json_array "$addresses")")
  if (( ipv4 && ipv6 )); then
    printf '%s' '0.0.0.0/0,::/0'
  elif (( ipv6 )); then
    printf '%s' '::/0'
  else
    printf '%s' '0.0.0.0/0'
  fi
}

wireguard_server_public_key() {
  local file="$1" private
  private="$(jq -r '.inbounds[0].settings.secretKey // empty' "$file")"
  validate_wireguard_key "$private" || return 1
  install_wireguard_tools || return 1
  printf '%s' "$private" | wg pubkey
}

render_wireguard_client_config() {
  local tag="$1" index="$2" file public profile private address endpoint port server dns allowed keepalive mtu
  file="$(find_inbound_file "$tag" || true)"
  [[ -n "$file" && "$index" =~ ^[0-9]+$ && "$index" -ge 1 ]] || return 1
  public="$(jq -r --argjson index "$((index - 1))" '
    .inbounds[0].settings.peers[$index].publicKey // empty
  ' "$file")"
  [[ -n "$public" ]] || { err "WireGuard Peer INDEX 不存在。"; return 1; }
  profile="$(wireguard_profile_path "$tag" "$public")"
  [[ -r "$profile" ]] || {
    err "该 Peer 没有保存的客户端配置；导入现有公钥时不会拥有客户端私钥。"
    return 1
  }
  private="$(jq -r '.privateKey // empty' "$profile")"
  [[ -n "$private" ]] || {
    err "该 Peer 是通过已有客户端公钥导入的，私钥只保存在原客户端。"
    return 1
  }
  address="$(jq -r '.address // empty' "$profile")"
  endpoint="$(jq -r '.endpointHost // empty' "$profile")"
  server="$(jq -r '.serverPublicKey // empty' "$profile")"
  dns="$(jq -r '.dns // empty' "$profile")"
  allowed="$(jq -r '.allowedIPs // empty' "$profile")"
  keepalive="$(jq -r '.keepAlive // 0' "$profile")"
  port="$(jq -r '.inbounds[0].port' "$file")"
  mtu="$(jq -r '.inbounds[0].settings.mtu // 1420' "$file")"
  [[ -n "$endpoint" && -n "$server" ]] || { err "客户端配置缺少服务端地址或公钥。"; return 1; }

  printf '[Interface]\nPrivateKey = %s\nAddress = %s\n' "$private" "$address"
  [[ -z "$dns" ]] || printf 'DNS = %s\n' "$dns"
  printf 'MTU = %s\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = %s\n' \
    "$mtu" "$server" "$(uri_host "$endpoint")" "$port" "$allowed"
  (( keepalive == 0 )) || printf 'PersistentKeepalive = %s\n' "$keepalive"
}

add_wireguard() {
  need_xray || return
  local tag port listen server_priv server_pub client_priv client_pub allowed mtu json
  local mode label endpoint_host dns routes keepalive profile
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
  mode="$(ask_default "客户端密钥：1 自动生成 / 2 导入已有客户端 PublicKey" "1")"
  label="$(ask_default "客户端名称" "${tag}-client1")"
  allowed="$(ask_wireguard_cidrs "客户端隧道地址/CIDR" "10.66.66.2/32")"
  mtu="$(ask_wireguard_mtu "MTU" "1420")"
  client_priv=""
  endpoint_host=""
  dns=""
  routes="$(wireguard_default_client_routes "$allowed")"
  keepalive=0
  case "$mode" in
    1)
      client_priv="$(wg genkey)"
      client_pub="$(printf '%s' "$client_priv" | wg pubkey)"
      case "$listen" in
        0.0.0.0|::|'') endpoint_host="$(ask_required "客户端连接的服务器域名/IP")" ;;
        *) endpoint_host="$(ask_default "客户端连接的服务器域名/IP" "$listen")" ;;
      esac
      dns="$(ask_default "客户端 DNS（留空不写入）" "1.1.1.1")"
      routes="$(ask_wireguard_cidrs "客户端代理网段 AllowedIPs" "$routes")"
      keepalive="$(ask_wireguard_keepalive "PersistentKeepalive 秒数（NAT 推荐 25）" "25")"
      ;;
    2)
      client_pub="$(ask_wireguard_key "已有客户端 WireGuard PublicKey")"
      ;;
    *) err "无效的客户端密钥模式。"; return 1 ;;
  esac

  json="$(jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg priv "$server_priv" --arg pub "$client_pub" \
    --argjson allowed "$(csv_to_json_array "$allowed")" --argjson mtu "$mtu" '
    {
      inbounds:[
        {
          tag:$tag,
          listen:$listen,
          port:$port,
          protocol:"wireguard",
          settings:{
            secretKey:$priv,
            peers:[{publicKey:$pub,allowedIPs:$allowed}],
            mtu:$mtu
          }
        }
      ]
    }')"

  safe_write_inbound "$tag" "$json" || return
  if ! wireguard_save_profile "$tag" "$label" "$client_pub" "$client_priv" "$allowed" \
       "$endpoint_host" "$dns" "$routes" "$keepalive" "$server_pub"; then
    warn "入站已创建，但客户端配置保存失败；请安全保存客户端私钥。"
  fi
  maybe_ufw_for_transport "$port" "wireguard" "wireguard" "$tag"
  show_created_summary "$tag" "wireguard" "$listen" "$port" ""
  printf '  Server PublicKey : %s\n' "$server_pub"
  printf '  Client PublicKey : %s\n' "$client_pub"
  printf '  Client Address   : %s\n' "$allowed"
  if [[ -n "$client_priv" ]]; then
    profile="$(wireguard_profile_path "$tag" "$client_pub")"
    printf '  Client Profile   : %s（仅 root 可读）\n\n' "$profile"
    info "请在入站详情 → 分享配置与二维码中查看完整 WireGuard 客户端配置。"
  else
    echo
    info "已登记现有客户端公钥；客户端私钥仍只保存在原设备。"
  fi
}

add_tunnel() {
  need_xray || return
  local tag listen_choice listen_default listen port network_choice network
  local target target_port outbound protocol file json
  TRANSPORT="tunnel"
  TRANSPORT_PATH=""; TRANSPORT_HOST=""; GRPC_SERVICE=""
  REALITY_PUBLIC=""; REALITY_SNI=""; REALITY_TARGET=""; REALITY_SHORTID=""

  tag="$(ask_tag "tunnel")"
  if has_global_ipv4; then
    listen_default="1"
  else
    listen_default="2"
  fi
  echo "监听范围："
  echo "1) 公网 IPv4（0.0.0.0）"
  echo "2) 公网 IPv6（::）"
  echo "3) 仅本机（127.0.0.1）"
  echo "4) 自定义监听地址"
  listen_choice="$(ask_default "请选择" "$listen_default")"
  case "$listen_choice" in
    2) listen="::" ;;
    3) listen="127.0.0.1" ;;
    4) listen="$(ask_required "本地监听地址")" ;;
    *) listen="0.0.0.0" ;;
  esac
  port="$(ask_port "本地监听端口" "25565")"
  warn_port "$port" || return
  echo "转发协议：1) TCP  2) UDP  3) TCP + UDP"
  network_choice="$(ask_default "请选择" "1")"
  case "$network_choice" in
    2) network="udp" ;;
    3) network="tcp,udp" ;;
    *) network="tcp" ;;
  esac
  target="$(ask_required "转发目标域名/IP")"
  target_port="$(ask_port "转发目标端口" "$port")"
  outbound="$(choose_outbound_tag "该端口转发使用的出站" "direct")"
  protocol="$(
    file="$(find_outbound_file "$outbound" || true)"
    if [[ -n "$file" ]]; then
      jq -r --arg tag "$outbound" '.outbounds[]? | select(.tag == $tag) | .protocol' "$file"
    fi
  )"
  if [[ "$protocol" == "http" && "$network" != "tcp" ]]; then
    err "HTTP 出站不支持 UDP，请选择 TCP 或更换出站。"
    return
  fi

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
    case "$network" in
      tcp) ufw_allow_if_active "$port" "tcp" "$tag" ;;
      udp) ufw_allow_if_active "$port" "udp" "$tag" ;;
      tcp,udp)
        ufw_allow_if_active "$port" "tcp" "$tag"
        ufw_allow_if_active "$port" "udp" "$tag"
        ;;
    esac
  fi
  if [[ "$outbound" != "direct" ]]; then
    if ! add_inbound_route_rule "$tag" "$outbound"; then
      warn "端口转发已创建，但出站路由创建失败；当前会使用默认出站。"
    fi
  fi
  show_created_summary "$tag" "tunnel" "$listen" "$port" ""
  printf "  Target     : %s:%s\n" "$target" "$target_port"
  printf "  Network    : %s\n" "$network"
  printf "  Outbound   : %s\n\n" "$outbound"
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

inbound_inventory_rows() {
  local file source
  shopt -s nullglob
  for file in "$CONF_DIR"/*.json; do
    case "$file" in
      "$CONF_DIR"/10_inbound_*.json) source="managed" ;;
      *) source="external" ;;
    esac
    jq -r --arg source "$source" --arg file "$file" '
      .inbounds[]? |
      (.settings.users // []) as $users |
      [
        (.tag // "-"),
        (.protocol // "-"),
        (.listen // "-"),
        ((.port // "-") | tostring),
        (.streamSettings.method // .streamSettings.network //
          (if .protocol == "shadowsocks" then "native" else "-" end)),
        (.streamSettings.security // "-"),
        (
          if .protocol == "shadowsocks" then
            if ($users | length) == 0 then "single/1"
            else "multi/" + (($users | length) | tostring) end
          elif .protocol == "wireguard" then
            "peers/" + (((.settings.peers // []) | length) | tostring)
          elif .protocol == "socks" and (.settings.auth // "") == "noauth" then
            "noauth"
          elif ($users | length) > 0 then
            "users/" + (($users | length) | tostring)
          else "-" end
        ),
        $source,
        $file
      ] | @tsv
    ' "$file" 2>/dev/null || true
  done
  shopt -u nullglob
}

list_inbounds() {
  ensure_layout
  local index=0 tag protocol listen port transport security users source file
  printf "\n%-5s %-22s %-13s %-18s %-7s %-11s %-9s %-10s %-9s\n" \
    "INDEX" "TAG" "PROTOCOL" "LISTEN" "PORT" "TRANSPORT" "SECURITY" "USERS" "SOURCE"
  printf "%-5s %-22s %-13s %-18s %-7s %-11s %-9s %-10s %-9s\n" \
    "-----" "----------------------" "-------------" "------------------" "-------" \
    "-----------" "---------" "----------" "---------"
  while IFS=$'\t' read -r tag protocol listen port transport security users source file; do
    [[ -n "$file" ]] || continue
    index=$((index + 1))
    printf "%-5s %-22s %-13s %-18s %-7s %-11s %-9s %-10s %-9s\n" \
      "$index" "$tag" "$protocol" "$listen" "$port" "$transport" "$security" "$users" "$source"
  done < <(inbound_inventory_rows)
  (( index > 0 )) || echo "暂无 Xray 入站。"
  echo
  (( index > 0 )) && info "输入编号或 Tag 选择；external 表示迁移/外部配置，只读查看。"
  return 0
}

find_any_inbound_file() {
  local tag="$1" file
  shopt -s nullglob
  for file in "$CONF_DIR"/*.json; do
    if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' \
       "$file" >/dev/null 2>&1; then
      printf '%s' "$file"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

resolve_inbound_selection() {
  local selection="$1" index=0 tag protocol listen port transport security users source file
  if find_any_inbound_file "$selection" >/dev/null 2>&1; then
    printf '%s' "$selection"
    return 0
  fi
  [[ "$selection" =~ ^[0-9]+$ ]] || return 1
  while IFS=$'\t' read -r tag protocol listen port transport security users source file; do
    [[ -n "$file" ]] || continue
    index=$((index + 1))
    if (( index == 10#$selection )); then
      [[ "$tag" != "-" ]] || return 1
      printf '%s' "$tag"
      return 0
    fi
  done < <(inbound_inventory_rows)
  return 1
}

choose_inbound_tag() {
  local prompt="${1:-选择入站}" requested="${2:-}" scope="${3:-managed}"
  local selection tag
  if [[ -n "$requested" ]]; then
    selection="$requested"
  else
    list_inbounds >&2
    selection="$(ask_required "$prompt（编号或 Tag）")"
  fi
  tag="$(resolve_inbound_selection "$selection" || true)"
  [[ -n "$tag" ]] || {
    err "未找到入站：$selection"
    return 1
  }
  if [[ "$scope" == "managed" ]] && ! find_inbound_file "$tag" >/dev/null 2>&1; then
    err "入站 $tag 位于迁移/外部配置中，目前只支持查看和诊断。"
    return 1
  fi
  printf '%s' "$tag"
}

inbound_networks() {
  local file="$1" tag="$2"
  jq -r --arg tag "$tag" '
    first(.inbounds[]? | select(.tag == $tag)) |
    if .protocol == "shadowsocks" then (.settings.network // "tcp,udp")
    elif .protocol == "wireguard" or .protocol == "hysteria" or
         (.streamSettings.method // "") == "mkcp" then "udp"
    elif .protocol == "tunnel" then (.settings.allowedNetwork // "tcp")
    elif .protocol == "socks" and (.settings.udp // false) then "tcp,udp"
    else "tcp" end
  ' "$file"
}

inbound_default_outbound() {
  local file tag
  if [[ -f "$ROUTING_FILE" ]]; then
    tag="$(jq -r '.routing.rules[]? | select(.ruleTag == "manager-default") |
      .outboundTag // empty' "$ROUTING_FILE" 2>/dev/null | head -n 1)"
    if [[ -n "$tag" ]]; then
      printf '%s' "$tag"
      return 0
    fi
  fi
  shopt -s nullglob
  for file in "$CONF_DIR"/*.json; do
    tag="$(jq -r '.outbounds[0].tag // empty' "$file" 2>/dev/null || true)"
    if [[ -n "$tag" ]]; then
      printf '%s' "$tag"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  printf '%s' "-"
}

inbound_matching_routes() {
  local tag="$1" file
  shopt -s nullglob
  for file in "$CONF_DIR"/*.json; do
    jq -r --arg tag "$tag" '
      .routing.rules[]? |
      select((.inboundTag // []) | index($tag)) |
      "\(.ruleTag // "unnamed") → \(.outboundTag // "-")"
    ' "$file" 2>/dev/null || true
  done
  shopt -u nullglob
}

show_inbound_summary_file() {
  local file="$1" tag="$2" inbound protocol listen port transport security
  local count method credential source network routes default_outbound target sni
  inbound="$(jq -ce --arg tag "$tag" '
    first(.inbounds[]? | select(.tag == $tag))
  ' "$file" 2>/dev/null || true)"
  [[ -n "$inbound" && "$inbound" != "null" ]] || {
    err "未找到入站配置：$tag"
    return 1
  }

  protocol="$(jq -r '.protocol // "-"' <<<"$inbound")"
  listen="$(jq -r '.listen // "-"' <<<"$inbound")"
  port="$(jq -r '.port // "-"' <<<"$inbound")"
  transport="$(jq -r '.streamSettings.method // .streamSettings.network // "native"' <<<"$inbound")"
  security="$(jq -r '.streamSettings.security // "none"' <<<"$inbound")"
  count="$(jq -r '(.settings.users // []) | length' <<<"$inbound")"
  method="$(jq -r '.settings.method // ""' <<<"$inbound")"
  network="$(inbound_networks "$file" "$tag")"
  default_outbound="$(inbound_default_outbound)"
  routes="$(inbound_matching_routes "$tag")"
  case "$file" in
    "$CONF_DIR"/10_inbound_*.json) source="Xray Manager" ;;
    *) source="迁移/外部配置（只读）" ;;
  esac

  echo
  printf "${C_BOLD}入站详情：%s${C_RESET}\n" "$tag"
  printf '  协议        : %s\n' "$protocol"
  printf '  监听地址    : %s\n' "$listen"
  printf '  监听端口    : %s\n' "$port"
  printf '  网络        : %s\n' "${network//,/ + }"
  printf '  传输方式    : %s\n' "$transport"
  printf '  传输安全    : %s\n' "$security"
  [[ -z "$method" ]] || printf '  加密方式    : %s\n' "$method"

  if [[ "$protocol" == "wireguard" ]]; then
    count="$(jq -r '(.settings.peers // []) | length' <<<"$inbound")"
    printf '  客户端数量  : %s\n' "$count"
    printf '  MTU         : %s\n' "$(jq -r '.settings.mtu // 1420' <<<"$inbound")"
  elif [[ "$protocol" == "shadowsocks" ]]; then
    credential="$(jq -r '.settings.password // ""' <<<"$inbound")"
    if (( count == 0 )); then
      printf '  用户模式    : 单用户\n'
      printf '  用户数量    : 1\n'
      printf '  客户端密码  : %s\n' "$(mask_credential "$credential")"
    else
      printf '  用户模式    : 多用户\n'
      printf '  用户数量    : %s\n' "$count"
      if [[ "$method" == 2022-* ]]; then
        printf '  服务器主 PSK: %s（不是独立用户）\n' "$(mask_credential "$credential")"
        printf '  密码格式    : ServerPassword:UserPassword\n'
      else
        printf '  顶层密码    : 多用户模式下不参与客户端认证\n'
      fi
    fi
  elif (( count > 0 )); then
    printf '  用户数量    : %s\n' "$count"
  fi

  case "$security" in
    reality)
      sni="$(jq -r '.streamSettings.realitySettings.serverNames[0] // "-"' <<<"$inbound")"
      target="$(jq -r '.streamSettings.realitySettings.target //
        .streamSettings.realitySettings.dest // "-"' <<<"$inbound")"
      printf '  REALITY SNI : %s\n' "$sni"
      printf '  回落目标    : %s\n' "$target"
      ;;
    tls)
      sni="$(jq -r '.streamSettings.tlsSettings.serverName // "-"' <<<"$inbound")"
      printf '  TLS SNI     : %s\n' "$sni"
      ;;
  esac

  printf '  默认出口    : %s\n' "$default_outbound"
  if [[ -n "$routes" ]]; then
    while IFS= read -r target; do
      printf '  关联路由    : %s\n' "$target"
    done <<<"$routes"
  else
    printf '  关联路由    : 无入站专属规则\n'
  fi

  if [[ "$port" =~ ^[0-9]+$ ]]; then
    if port_in_use "$port"; then
      printf '  监听状态    : 正在监听\n'
    else
      printf '  监听状态    : 当前未检测到监听\n'
    fi
  fi
  printf '  配置来源    : %s\n' "$source"
  printf '  配置文件    : %s\n' "$file"
  echo
}

show_inbound_details() {
  local tag file
  tag="$(choose_inbound_tag "选择要查看的入站" "${1:-}" any)" || return 1
  file="$(find_any_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到入站：$tag"; return 1; }
  show_inbound_summary_file "$file" "$tag"
}

show_inbound_raw_config() {
  local tag file
  tag="$(choose_inbound_tag "选择要查看原始配置的入站" "${1:-}" any)" || return 1
  file="$(find_any_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到入站：$tag"; return 1; }

  if confirm "显示完整敏感信息（UUID、密码、REALITY 私钥等）？"; then
    warn "请勿截图、录屏或把完整输出粘贴到公开位置。"
    jq --arg tag "$tag" '{inbounds:[.inbounds[]? | select(.tag == $tag)]}' "$file"
  else
    info "已默认脱敏；如确需完整值，请重新进入并明确确认。"
    jq --arg tag "$tag" '
      def sensitive_key:
        . == "id" or . == "password" or . == "privatekey" or
        . == "publickey" or . == "auth" or . == "shortids" or
        . == "key" or . == "pass";
      {inbounds:[.inbounds[]? | select(.tag == $tag)]} |
      walk(
        if type == "object" then
          with_entries(
            if (.key | ascii_downcase | sensitive_key) then
              .value = "<redacted>"
            else . end
          )
        else . end
      )
    ' "$file"
  fi
}

find_inbound_file() {
  local tag="$1" f
  shopt -s nullglob
  for f in "$CONF_DIR"/10_inbound_*.json; do
    if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$f" >/dev/null 2>&1; then
      printf '%s' "$f"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

preview_inbound_change() {
  local file="$1" json="$2" before after
  before="$(mktemp)"
  after="$(mktemp)"
  jq . "$file" >"$before"
  jq . <<<"$json" >"$after"
  echo
  printf "${C_BOLD}配置差异（- 当前 / + 修改后）${C_RESET}\n"
  if command -v diff >/dev/null 2>&1; then
    diff -u --label "$(basename "$file") 当前" --label "$(basename "$file") 修改后" \
      "$before" "$after" || true
  else
    warn "系统缺少 diff，改为显示修改后的完整 JSON。"
    cat "$after"
  fi
  rm -f "$before" "$after"
}

write_inbound_candidate() {
  local file="$1" json="$2" success_message="$3" old_tag new_tag
  [[ -f "$file" && "$file" == "$CONF_DIR/"10_inbound_*.json ]] || {
    err "目标不是由 Xray Manager 管理的入站文件。"
    return 1
  }
  jq -e '
    type == "object" and
    (.inbounds | type == "array" and length == 1) and
    (.inbounds[0] | type == "object")
  ' >/dev/null <<<"$json" || {
    err "一个受管入站文件必须只包含一个 InboundObject。"
    return 1
  }

  old_tag="$(jq -r '.inbounds[0].tag // empty' "$file")"
  new_tag="$(jq -r '.inbounds[0].tag // empty' <<<"$json")"
  [[ -n "$old_tag" && "$new_tag" == "$old_tag" ]] || {
    err "为避免路由引用和文件名失配，入站 Tag 不能在编辑器中直接修改。"
    return 1
  }

  if cmp -s <(jq -S . "$file") <(jq -S . <<<"$json"); then
    info "配置没有变化，无需写入或重启。"
    return 0
  fi

  warn "以下差异可能含 UUID、密码或密钥，请勿复制到公开位置。"
  preview_inbound_change "$file" "$json"
  confirm "确认应用以上修改？" || {
    warn "已取消，正式配置未改变。"
    return 1
  }
  safe_write_config_file "$(basename "$file")" "$json" "$success_message"
}

edit_inbound_json() {
  local file="$1" tag="$2" tmp editor json
  warn "高级编辑允许修改协议与传输细节；错误字段会被完整配置测试拦截。"
  tmp="$(mktemp --suffix=.json 2>/dev/null || mktemp)"
  jq . "$file" >"$tmp"

  editor="${VISUAL:-${EDITOR:-}}"
  if [[ -n "$editor" ]] && command -v "$editor" >/dev/null 2>&1; then
    "$editor" "$tmp" || { rm -f "$tmp"; return 1; }
  elif command -v nano >/dev/null 2>&1; then
    nano "$tmp" || { rm -f "$tmp"; return 1; }
  elif command -v vi >/dev/null 2>&1; then
    vi "$tmp" || { rm -f "$tmp"; return 1; }
  else
    warn "未找到可用终端编辑器，请粘贴修改后的完整 JSON，按 Ctrl-D 结束。"
    cat >"$tmp"
  fi

  json="$(cat "$tmp")"
  rm -f "$tmp"
  jq -e . >/dev/null <<<"$json" || {
    err "JSON 语法无效，未修改正式配置。"
    return 1
  }
  write_inbound_candidate "$file" "$json" "已更新入站：$tag"
}

edit_inbound() {
  need_xray || return
  local tag file protocol port old_port listen json c transport
  tag="$(choose_inbound_tag "选择要编辑的入站" "${1:-}")" || return 1
  file="$(find_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到 Tag：$tag"; return; }
  protocol="$(jq -r '.inbounds[0].protocol // "-"' "$file")"

  echo "配置文件：$file"
  echo "协议：$protocol"
  echo "1) 修改监听端口"
  echo "2) 修改监听地址"
  echo "3) 高级：编辑完整 Inbound JSON"
  echo "0) 取消"
  read -r -p "请选择: " c || true
  case "$c" in
    1)
      old_port="$(jq -r '.inbounds[0].port // empty' "$file")"
      [[ "$old_port" =~ ^[0-9]+$ ]] || {
        err "该入站没有普通数字端口，请使用高级 JSON 编辑。"
        return 1
      }
      port="$(ask_port "新监听端口" "$old_port")"
      if [[ "$port" == "$old_port" ]]; then
        info "端口没有变化。"
        return
      fi
      warn_port "$port" || return
      json="$(jq --arg tag "$tag" --argjson port "$port" '
        .inbounds |= map(if .tag == $tag then .port = $port else . end)
      ' "$file")"
      if write_inbound_candidate "$file" "$json" "已更新入站端口：$tag"; then
        transport="$(jq -r '.inbounds[0].streamSettings.method // "native"' "$file")"
        maybe_ufw_for_transport "$port" "$transport" "$protocol" "$tag"
        remove_managed_ufw_rules "$tag" "$old_port"
      fi
      ;;
    2)
      listen="$(jq -r '.inbounds[0].listen // empty' "$file")"
      listen="$(ask_default "新监听地址" "${listen:-0.0.0.0}")"
      if [[ "$listen" == "$(jq -r '.inbounds[0].listen // empty' "$file")" ]]; then
        info "监听地址没有变化。"
        return
      fi
      if [[ "$protocol" == "socks" || "$protocol" == "http" ]] && \
         [[ "$listen" != "127.0.0.1" && "$listen" != "::1" ]]; then
        warn "$protocol 入站本身不加密，暴露公网会有明显风险。"
        confirm "确认使用非本机监听地址？" || return
      fi
      json="$(jq --arg tag "$tag" --arg listen "$listen" '
        .inbounds |= map(if .tag == $tag then .listen = $listen else . end)
      ' "$file")"
      write_inbound_candidate "$file" "$json" "已更新入站监听地址：$tag"
      ;;
    3) edit_inbound_json "$file" "$tag" ;;
    0) return ;;
    *) err "无效选择。"; return 1 ;;
  esac
}

inbound_supports_user_management() {
  case "$1" in
    vless|vmess|trojan|shadowsocks|hysteria|socks|http|wireguard) return 0 ;;
    *) return 1 ;;
  esac
}

mask_credential() {
  local value="$1" length
  length="${#value}"
  if (( length <= 8 )); then
    printf '********'
  else
    printf '%s…%s' "${value:0:4}" "${value: -4}"
  fi
}

list_inbound_users_file() {
  local file="$1" reveal="${2:-0}" protocol count i email credential flow method
  local tag profile addresses
  protocol="$(jq -r '.inbounds[0].protocol // empty' "$file")"
  if [[ "$protocol" == "wireguard" ]]; then
    tag="$(jq -r '.inbounds[0].tag' "$file")"
    count="$(jq -r '(.inbounds[0].settings.peers // []) | length' "$file")"
    printf '\n%-6s %-24s %-34s %-28s %-12s\n' \
      "INDEX" "NAME" "CLIENT PUBLIC KEY" "CLIENT ADDRESS" "PROFILE"
    printf '%-6s %-24s %-34s %-28s %-12s\n' \
      "------" "------------------------" "----------------------------------" \
      "----------------------------" "------------"
    for ((i = 0; i < count; i++)); do
      credential="$(jq -r --argjson i "$i" '.inbounds[0].settings.peers[$i].publicKey' "$file")"
      addresses="$(jq -r --argjson i "$i" '
        .inbounds[0].settings.peers[$i].allowedIPs | join(",")
      ' "$file")"
      email="$(wireguard_peer_label "$tag" "$credential" "$((i + 1))")"
      profile="$(wireguard_profile_path "$tag" "$credential")"
      if [[ -r "$profile" ]] && jq -e '.privateKey | length > 0' "$profile" >/dev/null 2>&1; then
        flow="可导出"
      else
        flow="仅公钥"
      fi
      (( reveal == 1 )) || credential="$(mask_credential "$credential")"
      printf '%-6s %-24s %-34s %-28s %-12s\n' \
        "$((i + 1))" "$email" "$credential" "$addresses" "$flow"
    done
    echo
    return 0
  fi
  count="$(jq -r '(.inbounds[0].settings.users // []) | length' "$file")"

  if [[ "$protocol" == "shadowsocks" ]] && (( count > 0 )); then
    method="$(jq -r '.inbounds[0].settings.method // "-"' "$file")"
    if [[ "$method" == 2022-* ]]; then
      credential="$(jq -r '.inbounds[0].settings.password // empty' "$file")"
      (( reveal == 1 )) || credential="$(mask_credential "$credential")"
      printf '\n服务器主 PSK : %s（不是用户，不能单独生成多用户链接）\n' "$credential"
      printf '客户端密码格式: ServerPassword:UserPassword\n'
    else
      printf '\n多用户模式：顶层默认密码不会用于客户端认证。\n'
    fi
  fi

  printf "\n%-6s %-28s %-28s %-22s\n" "INDEX" "NAME / EMAIL" "CREDENTIAL" "FLOW / METHOD"
  printf "%-6s %-28s %-28s %-22s\n" "------" "----------------------------" "----------------------------" "----------------------"

  if [[ "$protocol" == "shadowsocks" ]] && (( count == 0 )); then
    email="$(jq -r '.inbounds[0].settings.email // "default"' "$file")"
    credential="$(jq -r '.inbounds[0].settings.password // empty' "$file")"
    method="$(jq -r '.inbounds[0].settings.method // "-"' "$file")"
    (( reveal == 1 )) || credential="$(mask_credential "$credential")"
    printf "%-6s %-28s %-28s %-22s\n" "0" "$email" "$credential" "$method"
  fi

  for ((i = 0; i < count; i++)); do
    email="$(jq -r --argjson i "$i" '
      .inbounds[0].settings.users[$i] |
      (.email // .user // ("user-" + (($i + 1) | tostring)))
    ' "$file")"
    credential="$(jq -r --argjson i "$i" '
      .inbounds[0].settings.users[$i] |
      (.id // .password // .auth // .pass // empty)
    ' "$file")"
    flow="$(jq -r --argjson i "$i" '
      .inbounds[0].settings.users[$i] |
      (.flow // .method // "-")
    ' "$file")"
    (( reveal == 1 )) || credential="$(mask_credential "$credential")"
    printf "%-6s %-28s %-28s %-22s\n" "$((i + 1))" "$email" "$credential" "$flow"
  done
  echo
}

list_inbound_users() {
  local tag file protocol reveal=0
  tag="$(choose_inbound_tag "选择要查看用户的入站" "${1:-}")" || return 1
  file="$(find_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到 Tag：$tag"; return; }
  protocol="$(jq -r '.inbounds[0].protocol // empty' "$file")"
  inbound_supports_user_management "$protocol" || {
    err "$protocol 入站不支持此用户管理器，请使用高级 JSON 编辑。"
    return 1
  }
  if confirm "显示完整凭据？"; then
    reveal=1
    warn "请勿截图、录屏或把凭据粘贴到公开位置。"
  fi
  echo "配置文件：$file"
  list_inbound_users_file "$file" "$reveal"
}

generate_shadowsocks_user_secret() {
  generate_shadowsocks_secret "$1"
}

inbound_user_label_exists() {
  local file="$1" label="$2" ignore_index="${3:--1}"
  jq -e --arg label "$label" --argjson ignore "$ignore_index" '
    (.inbounds[0].settings.users // [])
    | to_entries[]?
    | select(.key != $ignore)
    | .value
    | select((.email // .user // "") == $label)
  ' "$file" >/dev/null 2>&1
}

add_wireguard_peer() {
  local tag="$1" file="$2" count mode label addresses private public endpoint dns routes
  local keepalive server_public json listen
  count="$(jq -r '(.inbounds[0].settings.peers // []) | length' "$file")"
  mode="$(ask_default "客户端密钥：1 自动生成 / 2 导入已有客户端 PublicKey" "1")"
  label="$(ask_default "客户端名称" "${tag}-client$((count + 1))")"
  if wireguard_peer_label_exists "$tag" "$label"; then
    err "WireGuard 客户端名称已存在：$label"
    return 1
  fi
  addresses="$(ask_wireguard_cidrs "客户端隧道地址/CIDR" \
    "$(wireguard_next_client_address "$file")")" || return 1
  wireguard_peer_addresses_available "$file" "$addresses" || return 1
  private=""
  endpoint=""
  dns=""
  routes="$(wireguard_default_client_routes "$addresses")"
  keepalive=0
  server_public="$(wireguard_server_public_key "$file")" || {
    err "无法根据服务端私钥推导 WireGuard 服务端公钥。"
    return 1
  }
  case "$mode" in
    1)
      private="$(wg genkey)"
      public="$(printf '%s' "$private" | wg pubkey)"
      listen="$(jq -r '.inbounds[0].listen // empty' "$file")"
      case "$listen" in
        0.0.0.0|::|'') endpoint="$(ask_required "客户端连接的服务器域名/IP")" ;;
        *) endpoint="$(ask_default "客户端连接的服务器域名/IP" "$listen")" ;;
      esac
      dns="$(ask_default "客户端 DNS（留空不写入）" "1.1.1.1")"
      routes="$(ask_wireguard_cidrs "客户端代理网段 AllowedIPs" "$routes")"
      keepalive="$(ask_wireguard_keepalive "PersistentKeepalive 秒数（NAT 推荐 25）" "25")"
      ;;
    2) public="$(ask_wireguard_key "已有客户端 WireGuard PublicKey")" ;;
    *) err "无效的客户端密钥模式。"; return 1 ;;
  esac
  if jq -e --arg public "$public" '
    .inbounds[0].settings.peers[]? | select(.publicKey == $public)
  ' "$file" >/dev/null 2>&1; then
    err "WireGuard 客户端公钥已存在。"
    return 1
  fi
  json="$(jq --arg public "$public" --argjson addresses "$(csv_to_json_array "$addresses")" '
    .inbounds[0].settings.peers = ((.inbounds[0].settings.peers // []) +
      [{publicKey:$public,allowedIPs:$addresses}])
  ' "$file")"
  write_inbound_candidate "$file" "$json" "已向 WireGuard 入站 $tag 添加客户端：$label" || return 1
  wireguard_save_profile "$tag" "$label" "$public" "$private" "$addresses" \
    "$endpoint" "$dns" "$routes" "$keepalive" "$server_public" || {
    warn "Peer 已添加，但 root-only 客户端配置保存失败。"
    return 1
  }
  [[ -z "$private" ]] || info '客户端配置已保存；可在分享配置与二维码中按 INDEX 导出。'
}

edit_wireguard_peer() {
  local tag="$1" file="$2" count index array_index choice public profile label value json tmp
  count="$(jq -r '(.inbounds[0].settings.peers // []) | length' "$file")"
  list_inbound_users_file "$file" 0
  index="$(ask_default "客户端 INDEX" "1")"
  [[ "$index" =~ ^[0-9]+$ ]] && (( 10#$index >= 1 && 10#$index <= count )) || {
    err "WireGuard 客户端 INDEX 不存在。"
    return 1
  }
  array_index=$((10#$index - 1))
  public="$(jq -r --argjson index "$array_index" '
    .inbounds[0].settings.peers[$index].publicKey
  ' "$file")"
  profile="$(wireguard_profile_path "$tag" "$public")"
  echo "1) 修改客户端名称"
  echo "2) 修改客户端隧道地址/CIDR"
  read -r -p "请选择: " choice || true
  case "$choice" in
    1)
      label="$(wireguard_peer_label "$tag" "$public" "$index")"
      value="$(ask_default "新客户端名称" "$label")"
      if wireguard_peer_label_exists "$tag" "$value" "$profile"; then
        err "WireGuard 客户端名称已存在：$value"
        return 1
      fi
      if [[ ! -r "$profile" ]]; then
        wireguard_save_profile "$tag" "$value" "$public" "" \
          "$(jq -r --argjson i "$array_index" '
            .inbounds[0].settings.peers[$i].allowedIPs | join(",")
          ' "$file")" "" "" "0.0.0.0/0" 0 "" || return 1
      else
        tmp="$(mktemp "$(wireguard_profile_directory "$tag")/.peer.XXXXXX")"
        chmod 600 "$tmp"
        jq --arg label "$value" '.label = $label' "$profile" >"$tmp" || {
          rm -f "$tmp"
          return 1
        }
        mv "$tmp" "$profile"
        chmod 600 "$profile"
      fi
      ok "已更新 WireGuard 客户端名称：$value"
      ;;
    2)
      value="$(jq -r --argjson i "$array_index" '
        .inbounds[0].settings.peers[$i].allowedIPs | join(",")
      ' "$file")"
      value="$(ask_wireguard_cidrs "新客户端隧道地址/CIDR" "$value")"
      wireguard_peer_addresses_available "$file" "$value" "$array_index" || return 1
      json="$(jq --argjson i "$array_index" --argjson addresses "$(csv_to_json_array "$value")" '
        .inbounds[0].settings.peers[$i].allowedIPs = $addresses
      ' "$file")"
      write_inbound_candidate "$file" "$json" \
        "已更新 WireGuard 入站 $tag 的客户端 $index 地址" || return 1
      if [[ -r "$profile" ]]; then
        tmp="$(mktemp "$(wireguard_profile_directory "$tag")/.peer.XXXXXX")"
        chmod 600 "$tmp"
        jq --arg address "$value" '.address = $address' "$profile" >"$tmp" || {
          rm -f "$tmp"
          return 1
        }
        mv "$tmp" "$profile"
        chmod 600 "$profile"
      fi
      ;;
    *) err "无效选择。"; return 1 ;;
  esac
}

delete_wireguard_peer() {
  local tag="$1" file="$2" count index array_index public profile json
  count="$(jq -r '(.inbounds[0].settings.peers // []) | length' "$file")"
  (( count > 1 )) || {
    err "拒绝删除最后一个 WireGuard 客户端；请先添加替代客户端或删除整个入站。"
    return 1
  }
  list_inbound_users_file "$file" 0
  index="$(ask_default "要删除的客户端 INDEX" "1")"
  [[ "$index" =~ ^[0-9]+$ ]] && (( 10#$index >= 1 && 10#$index <= count )) || {
    err "WireGuard 客户端 INDEX 不存在。"
    return 1
  }
  array_index=$((10#$index - 1))
  public="$(jq -r --argjson index "$array_index" '
    .inbounds[0].settings.peers[$index].publicKey
  ' "$file")"
  profile="$(wireguard_profile_path "$tag" "$public")"
  json="$(jq --argjson index "$array_index" '
    .inbounds[0].settings.peers |= del(.[$index])
  ' "$file")"
  write_inbound_candidate "$file" "$json" \
    "已删除 WireGuard 入站 $tag 的客户端 $index" || return 1
  rm -f "$profile"
}

add_inbound_user() {
  need_xray || return
  local tag file protocol count label credential flow method json username
  tag="$(choose_inbound_tag "选择要添加用户的入站" "${1:-}")" || return 1
  file="$(find_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到 Tag：$tag"; return; }
  protocol="$(jq -r '.inbounds[0].protocol // empty' "$file")"
  inbound_supports_user_management "$protocol" || {
    err "$protocol 入站不支持此用户管理器。"
    return 1
  }
  if [[ "$protocol" == "wireguard" ]]; then
    add_wireguard_peer "$tag" "$file"
    return
  fi
  count="$(jq -r '(.inbounds[0].settings.users // []) | length' "$file")"

  if [[ "$protocol" == "shadowsocks" ]]; then
    method="$(jq -r '.inbounds[0].settings.method // empty' "$file")"
    if [[ "$method" == 2022-* && "$method" != 2022-blake3-aes-128-gcm &&
          "$method" != 2022-blake3-aes-256-gcm ]]; then
      err "$method 当前只支持单用户；Xray 的 SS2022 多用户仅支持 AES-128/AES-256。"
      return 1
    fi
    if (( count == 0 )); then
      warn "添加第一个用户会将 Shadowsocks 从单用户切换到多用户，原单用户链接将失效。"
      confirm "确认切换到多用户模式？" || return 1
    fi
  fi

  case "$protocol" in
    vless|vmess|trojan|hysteria|shadowsocks)
      label="$(ask_default "用户备注/email（需唯一）" "${tag}-user$((count + 1))@xray.local")"
      inbound_user_label_exists "$file" "$label" && {
        err "用户备注/email 已存在：$label"
        return 1
      }
      ;;
  esac

  case "$protocol" in
    vless)
      credential="$(ask_default "UUID" "$(generate_uuid)")"
      flow="$(jq -r '.inbounds[0].settings.users[0].flow // .inbounds[0].settings.flow // ""' "$file")"
      flow="$(ask_default "Flow（可留空）" "$flow")"
      json="$(jq --arg id "$credential" --arg email "$label" --arg flow "$flow" '
        .inbounds[0].settings.users = ((.inbounds[0].settings.users // []) +
          [{id:$id,level:0,email:$email,flow:$flow}])
      ' "$file")"
      ;;
    vmess)
      credential="$(ask_default "UUID / ID" "$(generate_uuid)")"
      json="$(jq --arg id "$credential" --arg email "$label" '
        .inbounds[0].settings.users = ((.inbounds[0].settings.users // []) +
          [{id:$id,level:0,email:$email}])
      ' "$file")"
      ;;
    trojan)
      credential="$(ask_default "Trojan 密码" "$(random_secret)")"
      json="$(jq --arg password "$credential" --arg email "$label" '
        .inbounds[0].settings.users = ((.inbounds[0].settings.users // []) +
          [{password:$password,level:0,email:$email}])
      ' "$file")"
      ;;
    hysteria)
      credential="$(ask_default "Hysteria2 auth" "$(random_secret)")"
      json="$(jq --arg auth "$credential" --arg email "$label" '
        .inbounds[0].settings.users = ((.inbounds[0].settings.users // []) +
          [{auth:$auth,level:0,email:$email}])
      ' "$file")"
      ;;
    shadowsocks)
      credential="$(ask_default "用户密码/PSK" "$(generate_shadowsocks_user_secret "$method")")"
      if [[ "$method" == 2022-* ]]; then
        json="$(jq --arg password "$credential" --arg email "$label" '
          .inbounds[0].settings.users = ((.inbounds[0].settings.users // []) +
            [{password:$password,level:0,email:$email}])
        ' "$file")"
      else
        json="$(jq --arg method "$method" --arg password "$credential" --arg email "$label" '
          .inbounds[0].settings.users = ((.inbounds[0].settings.users // []) +
            [{method:$method,password:$password,level:0,email:$email}])
        ' "$file")"
      fi
      ;;
    socks|http)
      username="$(ask_default "用户名" "user$((count + 1))")"
      inbound_user_label_exists "$file" "$username" && {
        err "用户名已存在：$username"
        return 1
      }
      credential="$(ask_default "密码" "$(random_secret)")"
      json="$(jq --arg user "$username" --arg pass "$credential" '
        .inbounds[0].settings.users = ((.inbounds[0].settings.users // []) +
          [{user:$user,pass:$pass}]) |
        (if .inbounds[0].protocol == "socks" then .inbounds[0].settings.auth = "password" else . end)
      ' "$file")"
      label="$username"
      ;;
  esac

  write_inbound_candidate "$file" "$json" "已向入站 $tag 添加用户：$label"
}

edit_inbound_user() {
  need_xray || return
  local tag file protocol count index array_index c current value json method
  tag="$(choose_inbound_tag "选择要编辑用户的入站" "${1:-}")" || return 1
  file="$(find_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到 Tag：$tag"; return; }
  protocol="$(jq -r '.inbounds[0].protocol // empty' "$file")"
  inbound_supports_user_management "$protocol" || { err "$protocol 不支持此用户管理器。"; return 1; }
  if [[ "$protocol" == "wireguard" ]]; then
    edit_wireguard_peer "$tag" "$file"
    return
  fi
  count="$(jq -r '(.inbounds[0].settings.users // []) | length' "$file")"
  list_inbound_users_file "$file" 0
  if [[ "$protocol" == "shadowsocks" ]] && (( count > 0 )); then
    method="$(jq -r '.inbounds[0].settings.method // empty' "$file")"
    [[ "$method" != 2022-* ]] || info "输入 0 可单独修改服务器主 PSK；它不是可分享用户。"
  fi
  index="$(ask_default "用户 INDEX" "1")"
  [[ "$index" =~ ^[0-9]+$ ]] || { err "INDEX 必须是数字。"; return 1; }

  if [[ "$protocol" == "shadowsocks" && "$index" == "0" ]]; then
    method="$(jq -r '.inbounds[0].settings.method // empty' "$file")"
    if (( count > 0 )); then
      [[ "$method" == 2022-* ]] || {
        err "旧版 Shadowsocks 多用户模式不使用顶层默认密码。"
        return 1
      }
      echo "1) 修改服务器主 PSK（将使全部现有链接失效）"
    else
      echo "1) 修改默认密码/PSK"
      echo "2) 修改默认 email"
    fi
    read -r -p "请选择: " c || true
    case "$c" in
      1)
        current="$(jq -r '.inbounds[0].settings.password' "$file")"
        if (( count > 0 )); then
          warn "修改 Shadowsocks 主密码会同时使全部 SS2022 多用户分享链接失效。"
        fi
        value="$(ask_default "新密码/PSK" "$current")"
        json="$(jq --arg value "$value" '.inbounds[0].settings.password = $value' "$file")"
        ;;
      2)
        (( count == 0 )) || { err "多用户模式没有独立的默认用户 email。"; return 1; }
        current="$(jq -r '.inbounds[0].settings.email // "default"' "$file")"
        value="$(ask_default "新 email" "$current")"
        json="$(jq --arg value "$value" '.inbounds[0].settings.email = $value' "$file")"
        ;;
      *) err "无效选择。"; return 1 ;;
    esac
  else
    (( index >= 1 && index <= count )) || { err "用户 INDEX 不存在。"; return 1; }
    array_index=$((index - 1))
    case "$protocol" in
      vless)
        echo "1) 修改 UUID  2) 修改 email  3) 修改 Flow"
        read -r -p "请选择: " c || true
        case "$c" in
          1) current="$(jq -r --argjson i "$array_index" '.inbounds[0].settings.users[$i].id' "$file")";
             value="$(ask_default "新 UUID" "$current")";
             json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].id=$value' "$file")" ;;
          2) current="$(jq -r --argjson i "$array_index" '.inbounds[0].settings.users[$i].email // ""' "$file")";
             value="$(ask_default "新 email" "$current")";
             inbound_user_label_exists "$file" "$value" "$array_index" && { err "email 已存在。"; return 1; };
             json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].email=$value' "$file")" ;;
          3) current="$(jq -r --argjson i "$array_index" '.inbounds[0].settings.users[$i].flow // ""' "$file")";
             value="$(ask_default "新 Flow（可留空）" "$current")";
             json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].flow=$value' "$file")" ;;
          *) err "无效选择。"; return 1 ;;
        esac
        ;;
      vmess|trojan|hysteria|shadowsocks)
        echo "1) 修改凭据  2) 修改 email"
        read -r -p "请选择: " c || true
        if [[ "$c" == "1" ]]; then
          current="$(jq -r --argjson i "$array_index" '
            .inbounds[0].settings.users[$i] | (.id // .password // .auth // empty)
          ' "$file")"
          value="$(ask_default "新凭据" "$current")"
          case "$protocol" in
            vmess) json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].id=$value' "$file")" ;;
            trojan|shadowsocks) json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].password=$value' "$file")" ;;
            hysteria) json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].auth=$value' "$file")" ;;
          esac
        elif [[ "$c" == "2" ]]; then
          current="$(jq -r --argjson i "$array_index" '.inbounds[0].settings.users[$i].email // ""' "$file")"
          value="$(ask_default "新 email" "$current")"
          inbound_user_label_exists "$file" "$value" "$array_index" && { err "email 已存在。"; return 1; }
          json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].email=$value' "$file")"
        else
          err "无效选择。"; return 1
        fi
        ;;
      socks|http)
        echo "1) 修改用户名  2) 修改密码"
        read -r -p "请选择: " c || true
        if [[ "$c" == "1" ]]; then
          current="$(jq -r --argjson i "$array_index" '.inbounds[0].settings.users[$i].user' "$file")"
          value="$(ask_default "新用户名" "$current")"
          inbound_user_label_exists "$file" "$value" "$array_index" && { err "用户名已存在。"; return 1; }
          json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].user=$value' "$file")"
        elif [[ "$c" == "2" ]]; then
          current="$(jq -r --argjson i "$array_index" '.inbounds[0].settings.users[$i].pass' "$file")"
          value="$(ask_default "新密码" "$current")"
          json="$(jq --argjson i "$array_index" --arg value "$value" '.inbounds[0].settings.users[$i].pass=$value' "$file")"
        else
          err "无效选择。"; return 1
        fi
        ;;
    esac
  fi
  write_inbound_candidate "$file" "$json" "已更新入站 $tag 的用户 $index"
}

delete_inbound_user() {
  need_xray || return
  local tag file protocol count index array_index json
  tag="$(choose_inbound_tag "选择要删除用户的入站" "${1:-}")" || return 1
  file="$(find_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到 Tag：$tag"; return; }
  protocol="$(jq -r '.inbounds[0].protocol // empty' "$file")"
  inbound_supports_user_management "$protocol" || { err "$protocol 不支持此用户管理器。"; return 1; }
  if [[ "$protocol" == "wireguard" ]]; then
    delete_wireguard_peer "$tag" "$file"
    return
  fi
  count="$(jq -r '(.inbounds[0].settings.users // []) | length' "$file")"
  list_inbound_users_file "$file" 0
  index="$(ask_default "要删除的用户 INDEX" "1")"
  [[ "$index" =~ ^[0-9]+$ ]] || { err "INDEX 必须是数字。"; return 1; }
  if [[ "$protocol" == "shadowsocks" && "$index" == "0" ]]; then
    err "Shadowsocks 默认主密码不能删除；可以修改，或删除整个入站。"
    return 1
  fi
  (( index >= 1 && index <= count )) || { err "用户 INDEX 不存在。"; return 1; }
  if [[ "$protocol" != "shadowsocks" ]] && (( count <= 1 )); then
    err "拒绝删除最后一个用户；请添加替代用户，或删除整个入站。"
    return 1
  fi
  if [[ "$protocol" == "shadowsocks" ]] && (( count == 1 )); then
    warn "删除最后一个用户会恢复 Shadowsocks 单用户模式，现有多用户链接将失效。"
    confirm "确认恢复单用户模式？" || return 1
  fi
  array_index=$((index - 1))
  json="$(jq --argjson i "$array_index" '
    .inbounds[0].settings.users |= del(.[$i]) |
    if .inbounds[0].protocol == "shadowsocks" and
       ((.inbounds[0].settings.users // []) | length) == 0
    then del(.inbounds[0].settings.users)
    else . end
  ' "$file")"
  write_inbound_candidate "$file" "$json" "已删除入站 $tag 的用户 $index"
}

inbound_user_management_menu() {
  local selected_tag="${1:-}"
  while true; do
    clear || true
    echo "========== 入站用户管理 =========="
    [[ -z "$selected_tag" ]] || echo "当前入站：$selected_tag"
    echo "1) 查看用户"
    echo "2) 添加用户"
    echo "3) 编辑用户"
    echo "4) 删除用户"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) list_inbound_users "$selected_tag"; pause ;;
      2) add_inbound_user "$selected_tag"; pause ;;
      3) edit_inbound_user "$selected_tag"; pause ;;
      4) delete_inbound_user "$selected_tag"; pause ;;
      0) return ;;
    esac
  done
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

base64_urlsafe() {
  base64 | tr -d '\n=' | tr '+/' '-_'
}

uri_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

SHARE_QUERY=""
query_add() {
  local key="$1" value="$2" encoded
  [[ -n "$value" ]] || return 0
  encoded="$(urlencode "$value")"
  if [[ -n "$SHARE_QUERY" ]]; then
    SHARE_QUERY+="&"
  fi
  SHARE_QUERY+="${key}=${encoded}"
}

link_transport_name() {
  case "$1" in
    raw|'') printf 'tcp' ;;
    websocket) printf 'ws' ;;
    mkcp) printf 'kcp' ;;
    *) printf '%s' "$1" ;;
  esac
}

reality_public_from_file() {
  local file="$1" private out public
  private="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$file")"
  [[ -n "$private" && -x "$XRAY_BIN" ]] || return 1
  out="$("$XRAY_BIN" x25519 -i "$private" 2>/dev/null || true)"
  public="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /(password|public)/ {print $2; exit}')"
  [[ -n "$public" ]] || return 1
  printf '%s' "$public"
}

add_stream_link_parameters() {
  local file="$1" method type security sni alpn path host service mode mtu public sid
  method="$(jq -r '.inbounds[0].streamSettings.method // "raw"' "$file")"
  type="$(link_transport_name "$method")"
  security="$(jq -r '.inbounds[0].streamSettings.security // "none"' "$file")"
  query_add "type" "$type"
  query_add "security" "$security"

  case "$method" in
    xhttp)
      path="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // empty' "$file")"
      host="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host // empty' "$file")"
      mode="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.mode // empty' "$file")"
      query_add "path" "$path"; query_add "host" "$host"; query_add "mode" "$mode"
      path="$(jq -c '.inbounds[0].streamSettings.xhttpSettings.extra // empty' "$file")"
      query_add "extra" "$path"
      ;;
    grpc)
      service="$(jq -r '.inbounds[0].streamSettings.grpcSettings.serviceName // empty' "$file")"
      mode="$(jq -r '.inbounds[0].streamSettings.grpcSettings.mode // empty' "$file")"
      host="$(jq -r '.inbounds[0].streamSettings.grpcSettings.authority // empty' "$file")"
      query_add "serviceName" "$service"; query_add "mode" "$mode"; query_add "authority" "$host"
      ;;
    websocket)
      path="$(jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$file")"
      host="$(jq -r '.inbounds[0].streamSettings.wsSettings.host // empty' "$file")"
      query_add "path" "$path"; query_add "host" "$host"
      ;;
    httpupgrade)
      path="$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.path // empty' "$file")"
      host="$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.host // empty' "$file")"
      query_add "path" "$path"; query_add "host" "$host"
      ;;
    mkcp)
      mtu="$(jq -r '.inbounds[0].streamSettings.kcpSettings.mtu // empty' "$file")"
      query_add "mtu" "$mtu"
      ;;
  esac

  case "$security" in
    tls)
      sni="$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName // empty' "$file")"
      alpn="$(jq -r '.inbounds[0].streamSettings.tlsSettings.alpn // [] | join(",")' "$file")"
      query_add "sni" "$sni"; query_add "alpn" "$alpn"
      ;;
    reality)
      sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$file")"
      sid="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$file")"
      public="$(reality_public_from_file "$file" || true)"
      [[ -n "$public" ]] || {
        err "无法由 REALITY 私钥推导客户端 pbk/password，不能生成完整链接。"
        return 1
      }
      query_add "sni" "$sni"; query_add "fp" "chrome"; query_add "pbk" "$public"; query_add "sid" "$sid"
      ;;
  esac
}

SHARE_LINK=""
build_share_link() {
  local file="$1" user_index="$2" server_host="$3" remark="$4"
  local protocol port host index id password auth flow method master user_password user_method
  local tls sni path transport_host vmess_json username user_count
  protocol="$(jq -r '.inbounds[0].protocol // empty' "$file")"
  port="$(jq -r '.inbounds[0].port // empty' "$file")"
  [[ "$port" =~ ^[0-9]+$ ]] || { err "该入站没有可分享的普通端口。"; return 1; }
  host="$(uri_host "$server_host")"
  [[ "$user_index" =~ ^[0-9]+$ ]] || return 1
  index=$((user_index - 1))
  SHARE_QUERY=""

  case "$protocol" in
    vless)
      id="$(jq -r --argjson i "$index" '.inbounds[0].settings.users[$i].id // empty' "$file")"
      flow="$(jq -r --argjson i "$index" '
        .inbounds[0] as $inbound |
        ($inbound.settings.users[$i].flow // $inbound.settings.flow // "")
      ' "$file")"
      [[ -n "$id" ]] || { err "用户 INDEX 不存在。"; return 1; }
      query_add "encryption" "none"
      query_add "flow" "$flow"
      add_stream_link_parameters "$file" || return 1
      SHARE_LINK="vless://$(urlencode "$id")@${host}:${port}?${SHARE_QUERY}#$(urlencode "$remark")"
      ;;
    vmess)
      id="$(jq -r --argjson i "$index" '.inbounds[0].settings.users[$i].id // empty' "$file")"
      [[ -n "$id" ]] || { err "用户 INDEX 不存在。"; return 1; }
      method="$(jq -r '.inbounds[0].streamSettings.method // "raw"' "$file")"
      method="$(link_transport_name "$method")"
      tls="$(jq -r '.inbounds[0].streamSettings.security // "none"' "$file")"
      [[ "$tls" == "none" ]] && tls=""
      sni="$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName // empty' "$file")"
      path="$(jq -r '
        .inbounds[0].streamSettings |
        (.xhttpSettings.path // .grpcSettings.serviceName // .wsSettings.path // .httpupgradeSettings.path // "")
      ' "$file")"
      transport_host="$(jq -r '
        .inbounds[0].streamSettings |
        (.xhttpSettings.host // .grpcSettings.authority // .wsSettings.host // .httpupgradeSettings.host // "")
      ' "$file")"
      vmess_json="$(jq -cn --arg ps "$remark" --arg add "$server_host" --arg port "$port" \
        --arg id "$id" --arg net "$method" --arg host "$transport_host" --arg path "$path" \
        --arg tls "$tls" --arg sni "$sni" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,
         type:"none",host:$host,path:$path,tls:$tls,sni:$sni}
      ')"
      SHARE_LINK="vmess://$(printf '%s' "$vmess_json" | base64 | tr -d '\n')"
      ;;
    trojan)
      password="$(jq -r --argjson i "$index" '.inbounds[0].settings.users[$i].password // empty' "$file")"
      [[ -n "$password" ]] || { err "用户 INDEX 不存在。"; return 1; }
      add_stream_link_parameters "$file" || return 1
      SHARE_LINK="trojan://$(urlencode "$password")@${host}:${port}?${SHARE_QUERY}#$(urlencode "$remark")"
      ;;
    shadowsocks)
      method="$(jq -r '.inbounds[0].settings.method // empty' "$file")"
      master="$(jq -r '.inbounds[0].settings.password // empty' "$file")"
      user_count="$(jq -r '(.inbounds[0].settings.users // []) | length' "$file")"
      if (( user_index == 0 )); then
        (( user_count == 0 )) || {
          err "多用户模式下服务器主密码不是独立用户，不能单独生成链接。"
          return 1
        }
        password="$master"
      else
        user_password="$(jq -r --argjson i "$index" '.inbounds[0].settings.users[$i].password // empty' "$file")"
        [[ -n "$user_password" ]] || { err "用户 INDEX 不存在。"; return 1; }
        user_method="$(jq -r --argjson i "$index" '.inbounds[0].settings.users[$i].method // empty' "$file")"
        if [[ "$method" == 2022-* ]]; then
          password="${master}:${user_password}"
        else
          password="$user_password"
          method="${user_method:-$method}"
        fi
      fi
      SHARE_LINK="ss://$(printf '%s' "${method}:${password}" | base64_urlsafe)@${host}:${port}#$(urlencode "$remark")"
      ;;
    hysteria)
      auth="$(jq -r --argjson i "$index" '.inbounds[0].settings.users[$i].auth // empty' "$file")"
      [[ -n "$auth" ]] || { err "用户 INDEX 不存在。"; return 1; }
      sni="$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName // empty' "$file")"
      query_add "sni" "$sni"
      SHARE_LINK="hysteria2://$(urlencode "$auth")@${host}:${port}?${SHARE_QUERY}#$(urlencode "$remark")"
      ;;
    socks|http)
      username="$(jq -r --argjson i "$index" '.inbounds[0].settings.users[$i].user // empty' "$file")"
      password="$(jq -r --argjson i "$index" '.inbounds[0].settings.users[$i].pass // empty' "$file")"
      [[ -n "$username" ]] || { err "用户 INDEX 不存在或该入站没有密码用户。"; return 1; }
      if [[ "$protocol" == "socks" ]]; then
        protocol="socks5"
      fi
      SHARE_LINK="${protocol}://$(urlencode "$username"):$(urlencode "$password")@${host}:${port}#$(urlencode "$remark")"
      ;;
    *)
      err "$protocol 暂无通用分享链接标准，请查看配置并手动配置客户端。"
      return 1
      ;;
  esac
}

ensure_qrencode() {
  command -v qrencode >/dev/null 2>&1 && return 0
  warn "终端二维码需要 qrencode。"
  confirm "现在安装 qrencode？" || return 1
  pkg_install_optional qrencode || return 1
  command -v qrencode >/dev/null 2>&1
}

show_wireguard_client_config() {
  local tag="$1" file="$2" count index config
  list_inbound_users_file "$file" 0
  count="$(jq -r '(.inbounds[0].settings.peers // []) | length' "$file")"
  index="$(ask_default "要导出的客户端 INDEX" "1")"
  [[ "$index" =~ ^[0-9]+$ ]] && (( 10#$index >= 1 && 10#$index <= count )) || {
    err "WireGuard 客户端 INDEX 不存在。"
    return 1
  }
  config="$(render_wireguard_client_config "$tag" "$((10#$index))")" || return 1
  warn "WireGuard 客户端配置与二维码包含客户端私钥；不要截图或发送到公开位置。"
  confirm "确认在终端显示完整客户端配置？" || return 1
  printf '\n%sWireGuard 客户端配置%s\n%s\n' "$C_BOLD" "$C_RESET" "$config"
  if confirm "在终端显示可供 WireGuard App 扫描的二维码？"; then
    if ensure_qrencode; then
      printf '\n'
      printf '%s\n' "$config" | qrencode -t ANSIUTF8
    else
      warn "未生成二维码，配置仍可复制保存为 .conf 导入。"
    fi
  fi
}

show_inbound_share_link() {
  local tag file protocol count user_index listen server_host remark default_index
  tag="$(choose_inbound_tag "选择要分享的入站" "${1:-}")" || return 1
  file="$(find_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到 Tag：$tag"; return; }
  protocol="$(jq -r '.inbounds[0].protocol // empty' "$file")"
  if [[ "$protocol" == "wireguard" ]]; then
    show_wireguard_client_config "$tag" "$file"
    return
  fi
  inbound_supports_user_management "$protocol" || {
    err "$protocol 暂无通用分享链接。"
    return 1
  }
  list_inbound_users_file "$file" 0
  count="$(jq -r '(.inbounds[0].settings.users // []) | length' "$file")"
  default_index=1
  if [[ "$protocol" == "shadowsocks" ]] && (( count == 0 )); then
    default_index=0
  fi
  user_index="$(ask_default "要分享的用户 INDEX" "$default_index")"
  [[ "$user_index" =~ ^[0-9]+$ ]] || { err "INDEX 必须是数字。"; return 1; }
  if [[ "$protocol" == "shadowsocks" ]]; then
    if (( count == 0 )); then
      (( user_index == 0 )) || { err "单用户 Shadowsocks 请选择 INDEX 0。"; return 1; }
    else
      (( user_index >= 1 && user_index <= count )) || {
        err "多用户 Shadowsocks 请选择实际用户 INDEX 1-$count；主 PSK 不是用户。"
        return 1
      }
    fi
  else
    (( user_index >= 1 && user_index <= count )) || { err "用户 INDEX 不存在。"; return 1; }
  fi

  listen="$(jq -r '.inbounds[0].listen // empty' "$file")"
  case "$listen" in 0.0.0.0|::|'') listen="" ;; esac
  if [[ -n "$listen" ]]; then
    server_host="$(ask_default "客户端连接域名/IP（不加方括号）" "$listen")"
  else
    server_host="$(ask_required "客户端连接域名/IP（不加方括号）")"
  fi
  remark="$(ask_default "节点名称" "$tag")"

  warn "分享链接和二维码包含完整认证凭据，任何拿到的人都可以使用该节点。"
  confirm "确认在终端显示完整链接？" || return
  build_share_link "$file" "$user_index" "$server_host" "$remark" || return
  echo
  printf "${C_BOLD}分享链接${C_RESET}\n%s\n" "$SHARE_LINK"
  if confirm "在终端显示二维码？"; then
    if ensure_qrencode; then
      echo
      qrencode -t ANSIUTF8 "$SHARE_LINK"
    else
      warn "未生成二维码，链接仍可复制导入。"
    fi
  fi
}

delete_inbound() {
  need_xray || return
  local requested="${1:-}" tag file backup tmp old_port
  tag="$(choose_inbound_tag "选择要删除的入站" "$requested")" || return 1
  file="$(find_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到 Tag：$tag"; return; }
  old_port="$(jq -r '.inbounds[0].port // empty' "$file")"

  confirm "确认删除 $tag？" || return
  backup="$(backup_now)"
  tmp="$(mktemp)"
  rm -f "$tmp"
  mv "$file" "$tmp"

  if test_config && service_restart; then
    rm -f "$tmp"
    ok "已删除：$tag"
    info "备份：$backup"
    if [[ -d "$(wireguard_profile_directory "$tag")" ]]; then
      rm -rf "$(wireguard_profile_directory "$tag")"
      info "已清理对应 WireGuard 客户端私钥和配置资料。"
    fi
    [[ "$old_port" =~ ^[0-9]+$ ]] && remove_managed_ufw_rules "$tag" "$old_port"
    if ! remove_managed_route_tag "forward-$(sanitize_tag "$tag")"; then
      warn "入站已删除，但对应的自动路由清理失败，请在路由菜单中检查。"
    fi
  else
    err "删除后配置/服务异常，正在回滚。"
    mv "$tmp" "$file"
    service_restart || true
  fi
}

validate_shadowsocks_2022_secret() {
  local method="$1" secret="$2" expected decoded
  case "$method" in
    2022-blake3-aes-128-gcm) expected=16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) expected=32 ;;
    *) return 0 ;;
  esac
  decoded="$(printf '%s' "$secret" | base64 --decode 2>/dev/null |
    wc -c | tr -d '[:space:]')" || return 1
  [[ "$decoded" == "$expected" ]]
}

diagnose_inbound() {
  local tag file inbound protocol port listen method count credential network status item
  local failures=0 warnings=0 index sync cert outbound
  tag="$(choose_inbound_tag "选择要诊断的入站" "${1:-}" any)" || return 1
  file="$(find_any_inbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到入站：$tag"; return 1; }
  inbound="$(jq -ce --arg tag "$tag" 'first(.inbounds[]? | select(.tag == $tag))' "$file")"
  protocol="$(jq -r '.protocol // ""' <<<"$inbound")"
  port="$(jq -r '.port // ""' <<<"$inbound")"
  listen="$(jq -r '.listen // ""' <<<"$inbound")"
  network="$(inbound_networks "$file" "$tag")"

  echo
  printf "${C_BOLD}入站诊断：%s${C_RESET}\n" "$tag"
  if test_config >/dev/null 2>&1; then
    ok "完整 Xray 配置测试通过。"
  else
    err "完整 Xray 配置测试失败。"
    failures=$((failures + 1))
  fi

  case "$INIT_SYS" in
    systemd)
      if systemctl is-active --quiet xray 2>/dev/null; then
        ok "Xray systemd 服务正在运行。"
      else
        warn "Xray systemd 服务未处于 active 状态。"
        warnings=$((warnings + 1))
      fi
      ;;
    openrc)
      if rc-service xray status >/dev/null 2>&1; then
        ok "Xray OpenRC 服务正在运行。"
      else
        warn "Xray OpenRC 服务未处于运行状态。"
        warnings=$((warnings + 1))
      fi
      ;;
  esac

  if [[ "$port" =~ ^[0-9]+$ ]]; then
    if port_in_use "$port"; then
      ok "监听端口 $port 已被监听。"
    else
      warn "监听端口 $port 当前未检测到监听。"
      warnings=$((warnings + 1))
    fi
  fi

  if [[ "$protocol" == "shadowsocks" ]]; then
    method="$(jq -r '.settings.method // ""' <<<"$inbound")"
    count="$(jq -r '(.settings.users // []) | length' <<<"$inbound")"
    if [[ "$method" == 2022-* ]]; then
      credential="$(jq -r '.settings.password // ""' <<<"$inbound")"
      if validate_shadowsocks_2022_secret "$method" "$credential"; then
        ok "SS2022 服务器 PSK 的 Base64 和密钥长度正常。"
      else
        err "SS2022 服务器 PSK 不是与 $method 匹配的有效 Base64 密钥。"
        failures=$((failures + 1))
      fi
      if (( count > 0 )) && [[ "$method" != 2022-blake3-aes-128-gcm &&
                                "$method" != 2022-blake3-aes-256-gcm ]]; then
        err "$method 不支持 Xray SS2022 多用户模式。"
        failures=$((failures + 1))
      fi
      for ((index = 0; index < count; index++)); do
        credential="$(jq -r --argjson index "$index" '
          .settings.users[$index].password // ""' <<<"$inbound")"
        if ! validate_shadowsocks_2022_secret "$method" "$credential"; then
          err "SS2022 用户 $((index + 1)) 的 PSK 长度或 Base64 编码无效。"
          failures=$((failures + 1))
        fi
      done
    fi
  fi

  if [[ "$protocol" == "wireguard" ]]; then
    credential="$(jq -r '.settings.secretKey // empty' <<<"$inbound")"
    if validate_wireguard_key "$credential"; then
      ok "WireGuard 服务端私钥的 Base64 和长度正常。"
    else
      err "WireGuard 服务端私钥不是有效的 Base64 32 字节密钥。"
      failures=$((failures + 1))
    fi
    count="$(jq -r '(.settings.peers // []) | length' <<<"$inbound")"
    (( count > 0 )) || { err "WireGuard 入站没有配置客户端 Peer。"; failures=$((failures + 1)); }
    for ((index = 0; index < count; index++)); do
      credential="$(jq -r --argjson index "$index" '
        .settings.peers[$index].publicKey // ""' <<<"$inbound")"
      if ! validate_wireguard_key "$credential"; then
        err "WireGuard 客户端 $((index + 1)) 的公钥格式无效。"
        failures=$((failures + 1))
      fi
      while IFS= read -r item; do
        if ! validate_wireguard_cidr "$item"; then
          err "WireGuard 客户端 $((index + 1)) 的地址无效：$item"
          failures=$((failures + 1))
        fi
      done < <(jq -r --argjson index "$index" '
        .settings.peers[$index].allowedIPs[]?' <<<"$inbound")
    done
    if jq -e '
      ((.settings.peers // []) | map(.publicKey) | length) !=
      ((.settings.peers // []) | map(.publicKey) | unique | length)
    ' <<<"$inbound" >/dev/null 2>&1; then
      err "WireGuard 入站存在重复的客户端公钥。"
      failures=$((failures + 1))
    fi
  fi

  if [[ "$protocol" == "vmess" ||
        ( "$protocol" == "shadowsocks" && "${method:-}" == 2022-* ) ]]; then
    if command -v timedatectl >/dev/null 2>&1; then
      sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
      case "$sync" in
        yes) ok "系统时钟已经同步。" ;;
        no)
          warn "系统时钟未同步，可能导致 $protocol 握手或时间戳校验失败。"
          warnings=$((warnings + 1))
          ;;
        *) info "当前环境无法读取 NTP 同步状态。" ;;
      esac
    fi
  fi

  if [[ "$protocol" == "socks" || "$protocol" == "http" ]] &&
     [[ "$listen" != "127.0.0.1" && "$listen" != "::1" ]]; then
    if [[ "$protocol" == "socks" &&
          "$(jq -r '.settings.auth // ""' <<<"$inbound")" == "noauth" ]]; then
      err "无认证 SOCKS 入站暴露在非本机地址。"
      failures=$((failures + 1))
    else
      warn "$protocol 入站暴露在非本机地址，请确认来源防火墙限制。"
      warnings=$((warnings + 1))
    fi
  fi

  while IFS= read -r outbound; do
    [[ -n "$outbound" ]] || continue
    if outbound_tag_exists "$outbound"; then
      ok "关联路由引用的出站存在：$outbound"
    else
      err "关联路由引用了不存在的出站：$outbound"
      failures=$((failures + 1))
    fi
  done < <(
    for item in "$CONF_DIR"/*.json; do
      [[ -f "$item" ]] || continue
      jq -r --arg tag "$tag" '
        .routing.rules[]? |
        select((.inboundTag // []) | index($tag)) |
        .outboundTag // empty
      ' "$item" 2>/dev/null || true
    done
  )

  while IFS= read -r cert; do
    [[ -n "$cert" ]] || continue
    if [[ ! -r "$cert" ]]; then
      err "TLS 证书不可读取：$cert"
      failures=$((failures + 1))
    elif openssl x509 -checkend 604800 -noout -in "$cert" >/dev/null 2>&1; then
      ok "TLS 证书有效期超过 7 天：$cert"
    else
      warn "TLS 证书已过期、7 天内到期或无法解析：$cert"
      warnings=$((warnings + 1))
    fi
  done < <(jq -r '
    .streamSettings.tlsSettings.certificates[]?.certificateFile // empty
  ' <<<"$inbound")

  if command -v ufw >/dev/null 2>&1 && [[ "$port" =~ ^[0-9]+$ ]]; then
    status="$(ufw status 2>/dev/null || true)"
    if [[ "$status" == *"Status: active"* && "$listen" != "127.0.0.1" && "$listen" != "::1" ]]; then
      for item in tcp udp; do
        [[ ",$network," == *",$item,"* ]] || continue
        if printf '%s\n' "$status" | grep -Eq "(^|[[:space:]])${port}/${item}([[:space:]]|$)"; then
          ok "UFW 已放行 $port/$item。"
        else
          warn "UFW 未发现 $port/$item 的放行规则。"
          warnings=$((warnings + 1))
        fi
      done
    fi
  fi

  printf '\n诊断结果：%s 项错误，%s 项警告。\n' "$failures" "$warnings"
  (( failures == 0 ))
}

show_inbound_routes() {
  local tag routes
  tag="$(choose_inbound_tag "选择要查看路由的入站" "${1:-}" any)" || return 1
  routes="$(inbound_matching_routes "$tag")"
  echo
  printf '入站 Tag：%s\n' "$tag"
  printf '默认出口：%s\n' "$(inbound_default_outbound)"
  if [[ -n "$routes" ]]; then
    printf '关联路由：\n%s\n' "$routes"
  else
    echo "关联路由：没有专门匹配此入站的规则。"
  fi
}

inbound_detail_menu() {
  local tag file choice managed
  tag="$(choose_inbound_tag "选择要管理的入站" "" any)" || return 1

  while true; do
    file="$(find_any_inbound_file "$tag" || true)"
    [[ -n "$file" ]] || return 0
    managed=0
    [[ "$file" == "$CONF_DIR/"10_inbound_*.json ]] && managed=1
    clear || true
    show_inbound_summary_file "$file" "$tag"
    if (( managed )); then
      echo "1) 查看用户"
      echo "2) 分享链接 / WireGuard 客户端配置与二维码"
      echo "3) 编辑入站"
      echo "4) 用户管理"
    else
      echo "此入站来自迁移/外部配置，只支持安全查看和诊断。"
    fi
    echo "5) 查看关联路由"
    echo "6) 运行入站诊断"
    echo "7) 查看原始 JSON"
    (( managed == 0 )) || echo "8) 删除入站"
    echo "0) 返回"
    read -r -p "请选择: " choice || true
    case "$choice" in
      1) (( managed )) && list_inbound_users "$tag"; pause ;;
      2) (( managed )) && show_inbound_share_link "$tag"; pause ;;
      3) (( managed )) && edit_inbound "$tag"; pause ;;
      4) (( managed )) && inbound_user_management_menu "$tag" ;;
      5) show_inbound_routes "$tag"; pause ;;
      6) diagnose_inbound "$tag" || true; pause ;;
      7) show_inbound_raw_config "$tag"; pause ;;
      8)
        if (( managed )) && delete_inbound "$tag"; then
          pause
          return 0
        fi
        pause
        ;;
      0) return 0 ;;
      *) warn "无效选择。"; pause ;;
    esac
  done
}

csv_to_json_array() {
  local value="$1"
  jq -cn --arg value "$value" '
    $value
    | split(",")
    | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | map(select(length > 0))
  '
}

outbound_tag_exists() {
  local tag="$1" f
  shopt -s nullglob
  for f in "$CONF_DIR"/*.json; do
    if jq -e --arg tag "$tag" '.outbounds[]? | select(.tag == $tag)' "$f" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

inbound_tag_exists() {
  local tag="$1" f
  shopt -s nullglob
  for f in "$CONF_DIR"/*.json; do
    if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$f" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

find_outbound_file() {
  local tag="$1" f
  shopt -s nullglob
  for f in "$CONF_DIR"/*.json; do
    if jq -e --arg tag "$tag" '.outbounds[]? | select(.tag == $tag)' "$f" >/dev/null 2>&1; then
      printf '%s' "$f"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

list_outbounds() {
  ensure_layout
  local found=0 f
  printf "\n%-24s %-14s %-32s %-8s\n" "TAG" "PROTOCOL" "SERVER / ENDPOINT" "PORT"
  printf "%-24s %-14s %-32s %-8s\n" "------------------------" "--------------" "--------------------------------" "--------"
  shopt -s nullglob
  for f in "$CONF_DIR"/*.json; do
    if jq -e '.outbounds | type == "array"' "$f" >/dev/null 2>&1; then
      found=1
      jq -r '
        .outbounds[]? |
        [
          (.tag // "-"),
          (.protocol // "-"),
          (
            .settings.peers[0].endpoint //
            (
              if (.settings.address | type) == "array"
              then (.settings.address | join(","))
              else .settings.address
              end
            ) //
            "-"
          ),
          ((.settings.port // "-") | tostring)
        ] | @tsv
      ' "$f" 2>/dev/null |
      while IFS=$'\t' read -r tag protocol server port; do
        printf "%-24s %-14s %-32s %-8s\n" "$tag" "$protocol" "$server" "$port"
      done
    fi
  done
  shopt -u nullglob
  (( found )) || echo "暂无出站。"
  echo
}

choose_outbound_tag() {
  local prompt="${1:-选择目标出站}" default="${2:-direct}" tag
  list_outbounds >&2
  while true; do
    tag="$(ask_default "$prompt" "$default")"
    if outbound_tag_exists "$tag"; then
      printf '%s' "$tag"
      return 0
    fi
    warn "未找到出站 Tag：$tag"
  done
}

safe_write_outbound() {
  local tag="$1" json="$2"
  safe_write_config_file \
    "20_outbound_$(sanitize_tag "$tag")_tail.json" \
    "$json" \
    "已添加出站：$tag"
}

add_freedom_outbound() {
  need_xray || return
  local tag c strategy send_through json
  tag="$(ask_named_tag "出站" "direct-v4")"
  echo "1) 自动/保持域名（AsIs）"
  echo "2) 强制使用 IPv4（UseIPv4）"
  echo "3) 强制使用 IPv6（UseIPv6）"
  c="$(ask_default "请选择" "2")"
  case "$c" in
    1) strategy="AsIs" ;;
    3) strategy="UseIPv6" ;;
    *) strategy="UseIPv4" ;;
  esac
  send_through="$(ask_default "指定源 IP/CIDR（留空自动选择）" "")"
  json="$(jq -cn \
    --arg tag "$tag" --arg strategy "$strategy" --arg send "$send_through" '
    {
      outbounds:[
        (
          {
            tag:$tag,
            protocol:"freedom",
            settings:{domainStrategy:$strategy}
          }
          + (if $send == "" then {} else {sendThrough:$send} end)
        )
      ]
    }
  ')"
  safe_write_outbound "$tag" "$json"
}

add_plain_proxy_outbound() {
  local protocol="$1"
  need_xray || return
  local tag address port auth user="" pass="" json
  tag="$(ask_named_tag "出站" "${protocol}-out")"
  address="$(ask_required "代理服务器域名/IP")"
  if [[ "$protocol" == "http" ]]; then
    port="$(ask_port "代理服务器端口" "3128")"
    warn "HTTP 出站只支持 TCP；不要把明文 HTTP 代理暴露在不可信公网。"
  else
    port="$(ask_port "代理服务器端口" "1080")"
  fi
  auth="$(ask_default "是否需要用户名密码 y / n" "n")"
  if [[ "${auth,,}" == "y" || "${auth,,}" == "yes" ]]; then
    user="$(ask_required "用户名")"
    pass="$(ask_required "密码")"
  fi
  json="$(jq -cn \
    --arg tag "$tag" --arg protocol "$protocol" \
    --arg address "$address" --argjson port "$port" \
    --arg user "$user" --arg pass "$pass" '
    {
      outbounds:[
        {
          tag:$tag,
          protocol:$protocol,
          settings:
            (
              {address:$address,port:$port}
              + (if $user == "" then {} else {user:$user,pass:$pass,level:0} end)
            )
        }
      ]
    }
  ')"
  safe_write_outbound "$tag" "$json"
}

add_shadowsocks_outbound() {
  need_xray || return
  local tag address port method password json
  tag="$(ask_named_tag "出站" "ss-out")"
  address="$(ask_required "Shadowsocks 服务器域名/IP")"
  port="$(ask_port "服务器端口" "443")"
  echo "推荐方法：2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm"
  method="$(ask_default "加密方法" "2022-blake3-aes-128-gcm")"
  password="$(ask_required "密码/预共享密钥")"
  json="$(jq -cn \
    --arg tag "$tag" --arg address "$address" --argjson port "$port" \
    --arg method "$method" --arg password "$password" '
    {
      outbounds:[
        {
          tag:$tag,
          protocol:"shadowsocks",
          settings:{
            address:$address,
            port:$port,
            method:$method,
            password:$password,
            level:0
          }
        }
      ]
    }
  ')"
  safe_write_outbound "$tag" "$json"
}

wireguard_reserved_json() {
  local value="$1" result
  if [[ -z "$value" ]]; then
    printf '[]'
    return 0
  fi
  value="${value#[}"
  value="${value%]}"
  result="$(jq -cn --arg value "$value" '
    $value | split(",") | map(gsub("[[:space:]]"; "") | tonumber)
  ' 2>/dev/null)" || {
    err "Reserved 必须是逗号分隔的数字。"
    return 1
  }
  if ! jq -e 'length == 3 and all(type == "number" and . == floor and . >= 0 and . <= 255)' \
       >/dev/null <<<"$result"; then
    err "Reserved 必须正好包含 3 个 0-255 的整数。"
    return 1
  fi
  printf '%s' "$result"
}

wireguard_validate_strategy() {
  local addresses="$1" strategy="$2" value ipv4=0 ipv6=0
  case "$strategy" in
    ForceIP|ForceIPv4|ForceIPv6|ForceIPv6v4|ForceIPv4v6) ;;
    *) err "无效的 WireGuard 域名解析策略：$strategy"; return 1 ;;
  esac
  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    if [[ "$value" == *:* ]]; then ipv6=1; else ipv4=1; fi
  done < <(jq -r '.[]' <<<"$(csv_to_json_array "$addresses")")
  if [[ "$strategy" == "ForceIPv4" && "$ipv4" != "1" ]]; then
    err "ForceIPv4 需要客户端地址中包含 IPv4 地址。"
    return 1
  fi
  if [[ "$strategy" == "ForceIPv6" && "$ipv6" != "1" ]]; then
    err "ForceIPv6 需要客户端地址中包含 IPv6 地址。"
    return 1
  fi
}

build_wireguard_outbound_json() {
  local tag="$1" secret="$2" addresses="$3" endpoint="$4" public_key="$5"
  local allowed="$6" preshared="$7" reserved="$8" mtu="$9" keepalive="${10}"
  local strategy="${11}" no_kernel="${12}" reserved_json
  validate_wireguard_key "$secret" || { err "客户端 PrivateKey 格式无效。"; return 1; }
  validate_wireguard_key "$public_key" || { err "服务端 PublicKey 格式无效。"; return 1; }
  if [[ -n "$preshared" ]] && ! validate_wireguard_key "$preshared"; then
    err "PresharedKey 必须是标准 Base64 32 字节密钥。"
    return 1
  fi
  validate_wireguard_cidr_list "$addresses" || { err "客户端地址/CIDR 无效。"; return 1; }
  validate_wireguard_cidr_list "$allowed" || { err "AllowedIPs 包含无效 CIDR。"; return 1; }
  validate_wireguard_endpoint "$endpoint" || { err "服务端 Endpoint 格式无效。"; return 1; }
  [[ "$mtu" =~ ^[0-9]+$ ]] && (( 10#$mtu >= 576 && 10#$mtu <= 9000 )) || {
    err "WireGuard MTU 必须在 576-9000 之间。"
    return 1
  }
  [[ "$keepalive" =~ ^[0-9]+$ ]] && (( 10#$keepalive <= 65535 )) || {
    err "KeepAlive 必须在 0-65535 之间。"
    return 1
  }
  [[ "$no_kernel" == "true" || "$no_kernel" == "false" ]] || return 1
  wireguard_validate_strategy "$addresses" "$strategy" || return 1
  reserved_json="$(wireguard_reserved_json "$reserved")" || return 1
  jq -cn \
    --arg tag "$tag" --arg secret "$secret" --arg endpoint "$endpoint" \
    --arg public "$public_key" --arg preshared "$preshared" --arg strategy "$strategy" \
    --argjson addresses "$(csv_to_json_array "$addresses")" \
    --argjson allowed "$(csv_to_json_array "$allowed")" \
    --argjson reserved "$reserved_json" --argjson mtu "$((10#$mtu))" \
    --argjson keepalive "$((10#$keepalive))" --argjson no_kernel "$no_kernel" '
    {
      outbounds:[{
        tag:$tag,
        protocol:"wireguard",
        settings:(
          {
            secretKey:$secret,
            address:$addresses,
            peers:[(
              {
                endpoint:$endpoint,publicKey:$public,
                allowedIPs:$allowed,keepAlive:$keepalive
              } + (if $preshared == "" then {} else {preSharedKey:$preshared} end)
            )],
            noKernelTun:$no_kernel,mtu:$mtu,domainStrategy:$strategy
          } + (if ($reserved | length) == 0 then {} else {reserved:$reserved} end)
        )
      }]
    }
  '
}

wireguard_userspace_choice() {
  local kernel
  kernel="$(ask_default \
    "使用内核 TUN（性能高，但可能受容器权限/路由表影响）y / n" "n")"
  if [[ "${kernel,,}" == "y" || "${kernel,,}" == "yes" ]]; then
    printf 'false'
  else
    printf 'true'
  fi
}

add_wireguard_outbound() {
  need_xray || return
  local tag secret addresses endpoint public_key allowed preshared reserved
  local mtu keepalive strategy no_kernel json client_public
  tag="$(ask_named_tag "出站" "warp")"
  secret="$(ask_required "客户端 PrivateKey（输入 auto 可生成并登记到自建服务端）")"
  if [[ "${secret,,}" == "auto" ]]; then
    install_wireguard_tools || { err "需要 wireguard-tools 才能生成客户端密钥。"; return 1; }
    secret="$(wg genkey)"
    client_public="$(printf '%s' "$secret" | wg pubkey)"
    info "新生成的客户端 PublicKey：$client_public"
    warn "必须先把该公钥登记到对端服务端；WARP 账号不能直接使用未注册的随机密钥。"
  elif ! validate_wireguard_key "$secret"; then
    err "客户端 PrivateKey 不是有效的 Base64 32 字节密钥。"
    return 1
  fi
  addresses="$(ask_wireguard_cidrs "客户端地址/CIDR，多个用逗号分隔" "172.16.0.2/32")"
  endpoint="$(ask_wireguard_endpoint "服务端 Endpoint" "engage.cloudflareclient.com:2408")"
  public_key="$(ask_wireguard_key "服务端 PublicKey（必须由服务端提供）")"
  preshared="$(ask_default "PresharedKey（没有请留空）" "")"
  if [[ -n "$preshared" ]] && ! validate_wireguard_key "$preshared"; then
    err "PresharedKey 不是有效的 Base64 32 字节密钥。"
    return 1
  fi
  allowed="$(ask_wireguard_cidrs "AllowedIPs，多个用逗号分隔" "0.0.0.0/0,::/0")"
  reserved="$(ask_default "Reserved 三个字节，普通 WireGuard 留空" "")"
  mtu="$(ask_wireguard_mtu "MTU" "1280")"
  keepalive="$(ask_wireguard_keepalive "KeepAlive 秒数" "0")"
  strategy="$(ask_default "域名策略 ForceIP / ForceIPv4 / ForceIPv6" "ForceIP")"
  no_kernel="$(wireguard_userspace_choice)"
  json="$(build_wireguard_outbound_json "$tag" "$secret" "$addresses" "$endpoint" \
    "$public_key" "$allowed" "$preshared" "$reserved" "$mtu" "$keepalive" \
    "$strategy" "$no_kernel")" || return 1
  safe_write_outbound "$tag" "$json"
}

wireguard_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

parse_wireguard_config() {
  local file="$1" raw line section="" key value peers=0
  WIREGUARD_IMPORTED_SECRET=""
  WIREGUARD_IMPORTED_ADDRESS=""
  WIREGUARD_IMPORTED_DNS=""
  WIREGUARD_IMPORTED_MTU=""
  WIREGUARD_IMPORTED_PUBLIC=""
  WIREGUARD_IMPORTED_PRESHARED=""
  WIREGUARD_IMPORTED_ENDPOINT=""
  WIREGUARD_IMPORTED_ALLOWED=""
  WIREGUARD_IMPORTED_KEEPALIVE="0"
  WIREGUARD_IMPORTED_RESERVED=""
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%$'\r'}"
    line="${line%%#*}"
    line="${line%%;*}"
    line="$(wireguard_trim "$line")"
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
      section="${BASH_REMATCH[1],,}"
      case "$section" in
        interface) ;;
        peer)
          peers=$((peers + 1))
          (( peers == 1 )) || {
            err "一个 Xray WireGuard 出站配置导入暂时只支持一个 [Peer]。"
            return 1
          }
          ;;
        *) err "不支持的 WireGuard 配置区段：[$section]"; return 1 ;;
      esac
      continue
    fi
    [[ "$line" == *=* && -n "$section" ]] || {
      err "WireGuard 配置行无效：$line"
      return 1
    }
    key="$(wireguard_trim "${line%%=*}")"
    value="$(wireguard_trim "${line#*=}")"
    case "${section}:${key,,}" in
      interface:privatekey) WIREGUARD_IMPORTED_SECRET="$value" ;;
      interface:address)
        if [[ -n "$WIREGUARD_IMPORTED_ADDRESS" ]]; then
          WIREGUARD_IMPORTED_ADDRESS="${WIREGUARD_IMPORTED_ADDRESS},${value}"
        else
          WIREGUARD_IMPORTED_ADDRESS="$value"
        fi
        ;;
      interface:dns) WIREGUARD_IMPORTED_DNS="$value" ;;
      interface:mtu) WIREGUARD_IMPORTED_MTU="$value" ;;
      interface:reserved|peer:reserved) WIREGUARD_IMPORTED_RESERVED="$value" ;;
      peer:publickey) WIREGUARD_IMPORTED_PUBLIC="$value" ;;
      peer:presharedkey) WIREGUARD_IMPORTED_PRESHARED="$value" ;;
      peer:endpoint) WIREGUARD_IMPORTED_ENDPOINT="$value" ;;
      peer:allowedips)
        if [[ -n "$WIREGUARD_IMPORTED_ALLOWED" ]]; then
          WIREGUARD_IMPORTED_ALLOWED="${WIREGUARD_IMPORTED_ALLOWED},${value}"
        else
          WIREGUARD_IMPORTED_ALLOWED="$value"
        fi
        ;;
      peer:persistentkeepalive|peer:keepalive) WIREGUARD_IMPORTED_KEEPALIVE="$value" ;;
      interface:listenport|interface:table|interface:fwmark|\
      interface:preup|interface:postup|interface:predown|interface:postdown|\
      interface:saveconfig) info "Xray WireGuard 出站忽略宿主机 wg-quick 字段：$key" ;;
      *) warn "未识别的 WireGuard 配置字段将被忽略：$key" ;;
    esac
  done <"$file"
  (( peers == 1 )) || { err "WireGuard 配置缺少 [Peer] 区段。"; return 1; }
  [[ -n "$WIREGUARD_IMPORTED_SECRET" ]] || { err "[Interface] 缺少 PrivateKey。"; return 1; }
  [[ -n "$WIREGUARD_IMPORTED_ADDRESS" ]] || { err "[Interface] 缺少 Address。"; return 1; }
  [[ -n "$WIREGUARD_IMPORTED_PUBLIC" ]] || { err "[Peer] 缺少 PublicKey。"; return 1; }
  [[ -n "$WIREGUARD_IMPORTED_ENDPOINT" ]] || { err "[Peer] 缺少 Endpoint。"; return 1; }
  WIREGUARD_IMPORTED_ALLOWED="${WIREGUARD_IMPORTED_ALLOWED:-0.0.0.0/0,::/0}"
  WIREGUARD_IMPORTED_MTU="${WIREGUARD_IMPORTED_MTU:-1280}"
}

import_wireguard_outbound() {
  need_xray || return
  local tag source_path tmp line strategy no_kernel reserved json
  tag="$(ask_named_tag "出站" "wireguard-import")"
  source_path="$(ask_default "WireGuard .conf 文件路径（留空后粘贴配置）" "")"
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  if [[ -n "$source_path" ]]; then
    [[ -f "$source_path" && -r "$source_path" ]] || {
      rm -f "$tmp"
      err "WireGuard 配置文件不存在或不可读取：$source_path"
      return 1
    }
    cat "$source_path" >"$tmp"
  else
    info "粘贴完整 WireGuard 配置；单独输入 END 结束。"
    while IFS= read -r line; do
      [[ "$line" != "END" ]] || break
      printf '%s\n' "$line" >>"$tmp"
    done
  fi
  if ! parse_wireguard_config "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  [[ -z "$WIREGUARD_IMPORTED_DNS" ]] || \
    info "配置中的 DNS=$WIREGUARD_IMPORTED_DNS 不会修改宿主机 DNS；Xray 使用自身 DNS 配置。"
  reserved="$(ask_default "Reserved 三个字节，普通 WireGuard 留空" \
    "$WIREGUARD_IMPORTED_RESERVED")"
  strategy="$(ask_default "域名策略 ForceIP / ForceIPv4 / ForceIPv6" "ForceIP")"
  no_kernel="$(wireguard_userspace_choice)"
  json="$(build_wireguard_outbound_json "$tag" "$WIREGUARD_IMPORTED_SECRET" \
    "$WIREGUARD_IMPORTED_ADDRESS" "$WIREGUARD_IMPORTED_ENDPOINT" \
    "$WIREGUARD_IMPORTED_PUBLIC" "$WIREGUARD_IMPORTED_ALLOWED" \
    "$WIREGUARD_IMPORTED_PRESHARED" "$reserved" "$WIREGUARD_IMPORTED_MTU" \
    "$WIREGUARD_IMPORTED_KEEPALIVE" "$strategy" "$no_kernel")" || return 1
  safe_write_outbound "$tag" "$json"
}

import_custom_outbound() {
  need_xray || return
  local tag tmp input json
  tag="$(ask_named_tag "出站" "custom-out")"
  echo
  echo '请粘贴单个 OutboundObject JSON，例如：'
  echo '{"tag":"custom","protocol":"freedom","settings":{}}'
  echo "输入完成后按 Ctrl-D："
  tmp="$(mktemp)"
  cat >"$tmp"
  input="$(cat "$tmp")"
  rm -f "$tmp"
  jq -e 'type == "object" and (.protocol | type == "string")' >/dev/null <<<"$input" || {
    err "输入不是有效的 OutboundObject。"
    return
  }
  json="$(jq -cn --argjson outbound "$input" --arg tag "$tag" '
    {outbounds:[($outbound + {tag:$tag})]}
  ')"
  safe_write_outbound "$tag" "$json"
}

show_outbound_details() {
  list_outbounds
  local tag file
  tag="$(ask_required "输入要查看的出站 Tag")"
  file="$(find_outbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到出站：$tag"; return; }
  if confirm "显示完整敏感信息（密码、WireGuard 私钥等）？"; then
    warn "请勿把完整输出粘贴到公开位置。"
    jq --arg tag "$tag" '.outbounds[]? | select(.tag == $tag)' "$file"
  else
    jq --arg tag "$tag" '
      .outbounds[]? | select(.tag == $tag) |
      walk(
        if type == "object" then
          with_entries(
            if (.key | ascii_downcase) as $key |
              ($key == "password" or $key == "pass" or $key == "secretkey" or
               $key == "presharedkey" or $key == "privatekey")
            then .value = "<redacted>" else . end
          )
        else . end
      )
    ' "$file"
  fi
}

outbound_is_referenced() {
  local tag="$1" f
  shopt -s nullglob
  for f in "$CONF_DIR"/*.json; do
    if jq -e --arg tag "$tag" '
      .. | objects |
      select(
        .outboundTag? == $tag or
        .proxySettings?.tag? == $tag or
        .streamSettings?.sockopt?.dialerProxy? == $tag
      )
    ' "$f" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

delete_outbound() {
  need_xray || return
  list_outbounds
  local tag file
  tag="$(ask_required "输入要删除的出站 Tag")"
  case "$tag" in
    direct|block)
      err "direct / block 是基础出站，不能删除。"
      return
      ;;
  esac
  file="$(find_outbound_file "$tag" || true)"
  [[ -n "$file" ]] || { err "未找到出站：$tag"; return; }
  [[ "$(basename "$file")" == 20_outbound_*_tail.json ]] || {
    err "该出站不是由新版出站管理器创建，拒绝自动删除：$file"
    return
  }
  if outbound_is_referenced "$tag"; then
    err "仍有路由或链式出站引用 $tag，请先删除相关规则。"
    return
  fi
  confirm "确认删除出站 $tag？" || return
  safe_remove_config_file "$file" "已删除出站：$tag"
}

add_outbound_menu() {
  while true; do
    clear || true
    echo "========== 添加 Xray 出站 =========="
    echo "1) Freedom 直连（自动 / 强制 IPv4 / 强制 IPv6 / 指定源 IP）"
    echo "2) SOCKS5（适合连接本机 WARP 或远程代理）"
    echo "3) HTTP Proxy（仅 TCP）"
    echo "4) WireGuard / WARP"
    echo "5) Shadowsocks"
    echo "6) 自定义 Outbound JSON"
    echo "7) 导入标准 WireGuard / WARP .conf"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) add_freedom_outbound; pause ;;
      2) add_plain_proxy_outbound "socks"; pause ;;
      3) add_plain_proxy_outbound "http"; pause ;;
      4) add_wireguard_outbound; pause ;;
      5) add_shadowsocks_outbound; pause ;;
      6) import_custom_outbound; pause ;;
      7) import_wireguard_outbound; pause ;;
      0) return ;;
    esac
  done
}

outbound_menu() {
  while true; do
    clear || true
    echo "========== 出站管理 =========="
    echo "1) 添加出站"
    echo "2) 查看出站列表"
    echo "3) 查看某出站配置"
    echo "4) 删除出站"
    echo "5) 测试完整 Xray 配置"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) add_outbound_menu ;;
      2) list_outbounds; pause ;;
      3) show_outbound_details; pause ;;
      4) delete_outbound; pause ;;
      5) test_config; pause ;;
      0) return ;;
    esac
  done
}

routing_conflict_files() {
  local f
  shopt -s nullglob
  for f in "$CONF_DIR"/*.json; do
    [[ "$f" == "$ROUTING_FILE" ]] && continue
    if jq -e 'has("routing")' "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
    fi
  done
  shopt -u nullglob
}

routing_ready() {
  local conflicts
  conflicts="$(routing_conflict_files)"
  if [[ -n "$conflicts" ]]; then
    err "检测到其他配置文件已经定义 routing，自动管理可能覆盖旧规则："
    printf '%s\n' "$conflicts" >&2
    warn "请先手动合并/移除旧 routing；本脚本不会擅自接管。"
    return 1
  fi
}

current_routing_json() {
  if [[ -f "$ROUTING_FILE" ]]; then
    cat "$ROUTING_FILE"
  else
    jq -cn '{routing:{domainStrategy:"IPIfNonMatch",rules:[]}}'
  fi
}

route_tag_exists() {
  local tag="$1"
  [[ -f "$ROUTING_FILE" ]] &&
    jq -e --arg tag "$tag" '.routing.rules[]? | select(.ruleTag == $tag)' "$ROUTING_FILE" >/dev/null 2>&1
}

ask_route_tag() {
  local default="$1" tag
  while true; do
    tag="$(ask_default "规则名称/RuleTag" "$default")"
    tag="$(sanitize_tag "$tag")"
    if ! route_tag_exists "$tag"; then
      printf '%s' "$tag"
      return
    fi
    warn "路由规则 $tag 已存在，请换一个名称。"
  done
}

write_routing_json() {
  local json="$1" message="$2"
  routing_ready || return
  safe_write_config_file "$(basename "$ROUTING_FILE")" "$json" "$message"
}

append_route_rule() {
  local rule="$1" message="$2" current next
  routing_ready || return
  current="$(current_routing_json)"
  next="$(jq -c --argjson rule "$rule" '
    .routing.rules = (
      [(.routing.rules // [])[] | select(.ruleTag != "manager-default")]
      + [$rule]
      + [(.routing.rules // [])[] | select(.ruleTag == "manager-default")]
    )
  ' <<<"$current")"
  write_routing_json "$next" "$message"
}

add_inbound_route_rule() {
  local inbound="$1" outbound="$2" rule_tag rule
  [[ "$outbound" != "direct" ]] || return 0
  rule_tag="forward-$(sanitize_tag "$inbound")"
  if route_tag_exists "$rule_tag"; then
    warn "已存在端口转发路由：$rule_tag"
    return 0
  fi
  rule="$(jq -cn \
    --arg rule_tag "$rule_tag" --arg inbound "$inbound" --arg outbound "$outbound" '
    {
      type:"field",
      ruleTag:$rule_tag,
      inboundTag:[$inbound],
      outboundTag:$outbound
    }
  ')"
  append_route_rule "$rule" "已将入站 $inbound 路由到出站 $outbound"
}

list_routing_rules() {
  routing_ready || return
  if [[ ! -f "$ROUTING_FILE" ]]; then
    echo "暂无由本脚本管理的路由规则。"
    return
  fi
  echo
  printf "%-5s %-24s %-48s %-20s\n" "序号" "RULE TAG" "MATCH" "TARGET"
  printf "%-5s %-24s %-48s %-20s\n" "-----" "------------------------" "------------------------------------------------" "--------------------"
  jq -r '
    .routing.rules // [] |
    to_entries[] |
    .key as $index | .value as $rule |
    [
      (($index + 1) | tostring),
      ($rule.ruleTag // ("rule-" + (($index + 1) | tostring))),
      (
        [
          (if $rule.inboundTag then "in=" + ($rule.inboundTag | join(",")) else empty end),
          (if $rule.domain then "domain=" + ($rule.domain | join(",")) else empty end),
          (if $rule.ip then "ip=" + ($rule.ip | join(",")) else empty end),
          (if $rule.port then "port=" + ($rule.port | tostring) else empty end),
          (if $rule.network then "net=" + $rule.network else empty end),
          (if $rule.protocol then "proto=" + ($rule.protocol | join(",")) else empty end)
        ] | join(";")
      ),
      ($rule.outboundTag // ("balancer:" + ($rule.balancerTag // "-")))
    ] | @tsv
  ' "$ROUTING_FILE" |
  while IFS=$'\t' read -r index tag match target; do
    printf "%-5s %-24s %-48s %-20s\n" "$index" "$tag" "${match:--}" "$target"
  done
  echo
  printf "Domain strategy: %s\n\n" "$(jq -r '.routing.domainStrategy // "AsIs"' "$ROUTING_FILE")"
}

add_domain_route() {
  local tag domains outbound domains_json rule
  tag="$(ask_route_tag "domain-route")"
  domains="$(ask_required "域名规则，逗号分隔（如 geosite:google,domain:example.com）")"
  domains_json="$(csv_to_json_array "$domains")"
  outbound="$(choose_outbound_tag)"
  rule="$(jq -cn \
    --arg tag "$tag" --arg outbound "$outbound" --argjson domains "$domains_json" '
    {type:"field",ruleTag:$tag,domain:$domains,outboundTag:$outbound}
  ')"
  append_route_rule "$rule" "已添加域名路由：$tag"
}

add_ip_route() {
  local tag ips outbound ips_json rule
  tag="$(ask_route_tag "ip-route")"
  ips="$(ask_required "IP/CIDR/GeoIP，逗号分隔（如 geoip:telegram,1.1.1.0/24）")"
  ips_json="$(csv_to_json_array "$ips")"
  outbound="$(choose_outbound_tag)"
  rule="$(jq -cn \
    --arg tag "$tag" --arg outbound "$outbound" --argjson ips "$ips_json" '
    {type:"field",ruleTag:$tag,ip:$ips,outboundTag:$outbound}
  ')"
  append_route_rule "$rule" "已添加 IP 路由：$tag"
}

add_inbound_route() {
  local tag inbound outbound rule
  list_inbounds
  tag="$(ask_route_tag "inbound-route")"
  inbound="$(ask_required "入站 Tag")"
  inbound_tag_exists "$inbound" || { err "未找到入站 Tag：$inbound"; return; }
  outbound="$(choose_outbound_tag)"
  rule="$(jq -cn \
    --arg tag "$tag" --arg inbound "$inbound" --arg outbound "$outbound" '
    {type:"field",ruleTag:$tag,inboundTag:[$inbound],outboundTag:$outbound}
  ')"
  append_route_rule "$rule" "已添加入站路由：$tag"
}

add_ip_family_route() {
  local family="$1" tag outbound cidr rule
  if [[ "$family" == "4" ]]; then
    tag="$(ask_route_tag "ipv4-route")"
    cidr="0.0.0.0/0"
  else
    tag="$(ask_route_tag "ipv6-route")"
    cidr="::/0"
  fi
  outbound="$(choose_outbound_tag)"
  rule="$(jq -cn \
    --arg tag "$tag" --arg cidr "$cidr" --arg outbound "$outbound" '
    {type:"field",ruleTag:$tag,ip:[$cidr],outboundTag:$outbound}
  ')"
  append_route_rule "$rule" "已添加 IPv${family} 全局路由：$tag"
}

add_china_direct_preset() {
  local current next
  routing_ready || return
  if route_tag_exists "cn-domain-direct" || route_tag_exists "cn-ip-direct"; then
    err "中国大陆直连预设已经存在。"
    return
  fi
  current="$(current_routing_json)"
  next="$(jq -c '
    .routing.rules = (
      [(.routing.rules // [])[] | select(.ruleTag != "manager-default")]
      + [
      {
        type:"field",
        ruleTag:"cn-domain-direct",
        domain:["geosite:cn"],
        outboundTag:"direct"
      },
      {
        type:"field",
        ruleTag:"cn-ip-direct",
        ip:["geoip:cn"],
        outboundTag:"direct"
      }
      ]
      + [(.routing.rules // [])[] | select(.ruleTag == "manager-default")]
    )
  ' <<<"$current")"
  write_routing_json "$next" "已添加中国大陆域名/IP直连预设"
}

add_service_route_preset() {
  local choice service geosite geoip="" outbound domain_tag ip_tag current next
  echo "1) Google"
  echo "2) Telegram（域名 + IP）"
  echo "3) OpenAI"
  echo "4) Netflix（域名 + IP）"
  echo "5) YouTube"
  choice="$(ask_default "请选择" "3")"
  case "$choice" in
    1) service="google"; geosite="geosite:google" ;;
    2) service="telegram"; geosite="geosite:telegram"; geoip="geoip:telegram" ;;
    4) service="netflix"; geosite="geosite:netflix"; geoip="geoip:netflix" ;;
    5) service="youtube"; geosite="geosite:youtube" ;;
    *) service="openai"; geosite="geosite:openai" ;;
  esac
  outbound="$(choose_outbound_tag)"
  domain_tag="service-${service}-domain"
  ip_tag="service-${service}-ip"
  if route_tag_exists "$domain_tag" || { [[ -n "$geoip" ]] && route_tag_exists "$ip_tag"; }; then
    err "${service} 预设已经存在。"
    return
  fi
  current="$(current_routing_json)"
  next="$(jq -c \
    --arg domain_tag "$domain_tag" --arg ip_tag "$ip_tag" \
    --arg geosite "$geosite" --arg geoip "$geoip" --arg outbound "$outbound" '
    .routing.rules = (
      [(.routing.rules // [])[] | select(.ruleTag != "manager-default")]
      + [{
          type:"field",
          ruleTag:$domain_tag,
          domain:[$geosite],
          outboundTag:$outbound
        }]
      + (
          if $geoip == "" then []
          else [{
            type:"field",
            ruleTag:$ip_tag,
            ip:[$geoip],
            outboundTag:$outbound
          }]
          end
        )
      + [(.routing.rules // [])[] | select(.ruleTag == "manager-default")]
    )
  ' <<<"$current")"
  write_routing_json "$next" "已添加 ${service} 分流预设 → $outbound"
}

add_block_preset() {
  local kind="$1" tag rule
  case "$kind" in
    ads)
      tag="$(ask_route_tag "block-ads")"
      rule="$(jq -cn --arg tag "$tag" '
        {type:"field",ruleTag:$tag,domain:["geosite:category-ads-all"],outboundTag:"block"}
      ')"
      ;;
    bittorrent)
      tag="$(ask_route_tag "block-bittorrent")"
      rule="$(jq -cn --arg tag "$tag" '
        {type:"field",ruleTag:$tag,protocol:["bittorrent"],outboundTag:"block"}
      ')"
      warn "BT 识别依赖入站 sniffing，且加密/混淆 BT 可能无法完全识别。"
      ;;
    *)
      return 1
      ;;
  esac
  append_route_rule "$rule" "已添加拦截规则：$tag"
}

set_default_outbound_route() {
  local outbound current next
  outbound="$(choose_outbound_tag "最终默认出站" "direct")"
  current="$(current_routing_json)"
  next="$(jq -c --arg outbound "$outbound" '
    .routing.rules = (
      [(.routing.rules // [])[] | select(.ruleTag != "manager-default")]
      + [{
          type:"field",
          ruleTag:"manager-default",
          network:"tcp,udp",
          outboundTag:$outbound
        }]
    )
  ' <<<"$current")"
  write_routing_json "$next" "已设置最终默认出站：$outbound"
}

remove_managed_route_tag() {
  local tag="$1" current next
  [[ -f "$ROUTING_FILE" ]] || return 0
  route_tag_exists "$tag" || return 0
  routing_ready || return 1
  current="$(current_routing_json)"
  next="$(jq -c --arg tag "$tag" '
    .routing.rules = [(.routing.rules // [])[] | select(.ruleTag != $tag)]
  ' <<<"$current")"
  write_routing_json "$next" "已清理关联路由：$tag"
}

import_custom_route_rule() {
  local tmp input tag rule
  tag="$(ask_route_tag "custom-route")"
  echo '请粘贴单个 RuleObject JSON，输入完成后按 Ctrl-D：'
  tmp="$(mktemp)"
  cat >"$tmp"
  input="$(cat "$tmp")"
  rm -f "$tmp"
  jq -e '
    type == "object" and
    ((.outboundTag? | type == "string") or (.balancerTag? | type == "string"))
  ' >/dev/null <<<"$input" || {
    err "规则必须是 JSON 对象，并包含 outboundTag 或 balancerTag。"
    return
  }
  rule="$(jq -c --arg tag "$tag" '. + {type:"field",ruleTag:$tag}' <<<"$input")"
  append_route_rule "$rule" "已添加自定义路由：$tag"
}

delete_routing_rule() {
  routing_ready || return
  [[ -f "$ROUTING_FILE" ]] || { warn "暂无路由规则。"; return; }
  list_routing_rules
  local number count current next name
  number="$(ask_required "要删除的规则序号")"
  [[ "$number" =~ ^[0-9]+$ ]] || { err "序号无效。"; return; }
  count="$(jq '.routing.rules | length' "$ROUTING_FILE")"
  (( number >= 1 && number <= count )) || { err "序号超出范围。"; return; }
  name="$(jq -r --argjson index "$((number - 1))" '.routing.rules[$index].ruleTag // "unnamed"' "$ROUTING_FILE")"
  confirm "确认删除路由 $name？" || return
  current="$(current_routing_json)"
  next="$(jq -c --argjson index "$((number - 1))" '
    .routing.rules |= del(.[$index])
  ' <<<"$current")"
  write_routing_json "$next" "已删除路由：$name"
}

move_routing_rule() {
  routing_ready || return
  [[ -f "$ROUTING_FILE" ]] || { warn "暂无路由规则。"; return; }
  list_routing_rules
  local number direction count index target current next
  number="$(ask_required "要移动的规则序号")"
  [[ "$number" =~ ^[0-9]+$ ]] || { err "序号无效。"; return; }
  count="$(jq '.routing.rules | length' "$ROUTING_FILE")"
  (( number >= 1 && number <= count )) || { err "序号超出范围。"; return; }
  direction="$(ask_default "方向 u=上移 / d=下移" "u")"
  index=$((number - 1))
  if [[ "${direction,,}" == "d" ]]; then
    target=$((index + 1))
  else
    target=$((index - 1))
  fi
  (( target >= 0 && target < count )) || { warn "已经在最前或最后。"; return; }
  current="$(current_routing_json)"
  next="$(jq -c --argjson index "$index" --argjson target "$target" '
    .routing.rules as $rules |
    .routing.rules[$index] = $rules[$target] |
    .routing.rules[$target] = $rules[$index]
  ' <<<"$current")"
  write_routing_json "$next" "已调整路由优先级"
}

set_routing_domain_strategy() {
  local strategy current next
  echo "1) AsIs（只按域名规则匹配，不为 IP 规则额外解析）"
  echo "2) IPIfNonMatch（域名未命中时再解析 IP，推荐）"
  echo "3) IPOnDemand（遇到 IP 规则立即解析）"
  strategy="$(ask_default "请选择" "2")"
  case "$strategy" in
    1) strategy="AsIs" ;;
    3) strategy="IPOnDemand" ;;
    *) strategy="IPIfNonMatch" ;;
  esac
  current="$(current_routing_json)"
  next="$(jq -c --arg strategy "$strategy" '.routing.domainStrategy = $strategy' <<<"$current")"
  write_routing_json "$next" "已设置路由域名策略：$strategy"
}

add_routing_rule_menu() {
  while true; do
    clear || true
    echo "========== 添加路由/分流 =========="
    echo "1) 常用服务（Google / Telegram / OpenAI / Netflix / YouTube）"
    echo "2) 域名 / GeoSite → 指定出站"
    echo "3) IP / CIDR / GeoIP → 指定出站"
    echo "4) 指定入站的全部流量 → 指定出站"
    echo "5) 所有 IPv4 目标 → 指定出站"
    echo "6) 所有 IPv6 目标 → 指定出站"
    echo "7) 中国大陆域名 + IP 直连预设"
    echo "8) 广告域名拦截预设"
    echo "9) BitTorrent 拦截预设"
    echo "10) 设置最终默认出站"
    echo "11) 自定义 RuleObject JSON"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) add_service_route_preset; pause ;;
      2) add_domain_route; pause ;;
      3) add_ip_route; pause ;;
      4) add_inbound_route; pause ;;
      5) add_ip_family_route "4"; pause ;;
      6) add_ip_family_route "6"; pause ;;
      7) add_china_direct_preset; pause ;;
      8) add_block_preset "ads"; pause ;;
      9) add_block_preset "bittorrent"; pause ;;
      10) set_default_outbound_route; pause ;;
      11) import_custom_route_rule; pause ;;
      0) return ;;
    esac
  done
}

routing_menu() {
  while true; do
    clear || true
    echo "========== 路由与分流 =========="
    echo "规则从上到下匹配，命中第一条后停止。"
    echo "1) 添加规则 / 常用预设"
    echo "2) 查看规则顺序"
    echo "3) 删除规则"
    echo "4) 上移 / 下移规则"
    echo "5) 设置 Domain Strategy"
    echo "6) 查看完整 routing JSON"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) routing_ready && add_routing_rule_menu ;;
      2) list_routing_rules; pause ;;
      3) delete_routing_rule; pause ;;
      4) move_routing_rule; pause ;;
      5) routing_ready && set_routing_domain_strategy; pause ;;
      6)
        routing_ready && {
          if [[ -f "$ROUTING_FILE" ]]; then jq . "$ROUTING_FILE"; else echo "暂无路由配置。"; fi
        }
        pause
        ;;
      0) return ;;
    esac
  done
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
  local port="$1" proto="${2:-tcp}" tag="${3:-}"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  if [[ -n "$tag" ]]; then
    managed_ufw_allow "$port" "$proto" "$tag"
  else
    ufw allow "$port/$proto" >/dev/null 2>&1 || true
  fi
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

validate_backup_archive() {
  local archive="$1" listing verbose member normalized type saw_conf=0
  listing="$(mktemp)"
  verbose="$(mktemp)"

  if ! LC_ALL=C tar -tzf "$archive" >"$listing" 2>/dev/null ||
      ! LC_ALL=C tar -tvzf "$archive" >"$verbose" 2>/dev/null; then
    rm -f "$listing" "$verbose"
    err "备份压缩包损坏或无法读取。"
    return 1
  fi

  while IFS= read -r member; do
    normalized="${member#./}"
    normalized="${normalized%/}"
    [[ -n "$normalized" && "$normalized" != "." ]] || continue

    if [[ "$normalized" == /* || "$normalized" == *\\* ]] ||
       [[ ! "$normalized" =~ ^(conf\.d|certs|wireguard)(/[A-Za-z0-9._-]+)*$ &&
          "$normalized" != "backup-manifest.json" ]]; then
      rm -f "$listing" "$verbose"
      err "备份包含不安全或未知路径：$member"
      return 1
    fi
    [[ "$normalized" == "conf.d" || "$normalized" == conf.d/* ]] && saw_conf=1
  done <"$listing"

  while IFS= read -r member; do
    type="${member:0:1}"
    case "$type" in
      -|d) ;;
      *)
        rm -f "$listing" "$verbose"
        err "备份包含不允许的链接或特殊文件。"
        return 1
        ;;
    esac
  done <"$verbose"

  rm -f "$listing" "$verbose"
  (( saw_conf )) || {
    err "备份缺少 conf.d 配置目录。"
    return 1
  }
}

rollback_restored_directories() {
  local stage_root="$1" rollback_root="$2" stage_state="$3" rollback_state="$4"
  local swapped_conf="$5" had_conf="$6" touched_certs="$7" had_certs="$8"
  local touched_wireguard="$9" had_wireguard="${10}"
  local wireguard_dir="${STATE_DIR}/wireguard"

  if (( swapped_conf )); then
    [[ ! -e "$CONF_DIR" ]] || mv "$CONF_DIR" "$stage_root/failed-conf.d"
    (( ! had_conf )) || mv "$rollback_root/conf.d" "$CONF_DIR"
  fi
  if (( touched_certs )); then
    [[ ! -e "$CERT_DIR" ]] || mv "$CERT_DIR" "$stage_root/failed-certs"
    (( ! had_certs )) || mv "$rollback_root/certs" "$CERT_DIR"
  fi
  if (( touched_wireguard )); then
    [[ ! -e "$wireguard_dir" ]] || mv "$wireguard_dir" "$stage_state/failed-wireguard"
    (( ! had_wireguard )) || mv "$rollback_state/wireguard" "$wireguard_dir"
  fi

  ensure_layout
}

restore_backup_transaction() (
  local extracted="$1"
  local conf_name cert_name wireguard_dir stage_root rollback_root stage_state rollback_state
  local swapped_conf=0 had_conf=0 touched_certs=0 had_certs=0
  local touched_wireguard=0 had_wireguard=0 rollback_needed=0 committed=0

  conf_name="$(basename "$CONF_DIR")"
  cert_name="$(basename "$CERT_DIR")"
  wireguard_dir="${STATE_DIR}/wireguard"
  ensure_layout

  stage_root="$(mktemp -d "${XRAY_ROOT}/.restore-stage.XXXXXX")"
  rollback_root="$(mktemp -d "${XRAY_ROOT}/.restore-rollback.XXXXXX")"
  stage_state="$(mktemp -d "${STATE_DIR}/.restore-stage.XXXXXX")"
  rollback_state="$(mktemp -d "${STATE_DIR}/.restore-rollback.XXXXXX")"

  cleanup_restore_transaction() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if (( rollback_needed && ! committed )); then
      err "恢复后的配置或服务异常，正在自动回滚..."
      if rollback_restored_directories \
          "$stage_root" "$rollback_root" "$stage_state" "$rollback_state" \
          "$swapped_conf" "$had_conf" "$touched_certs" "$had_certs" \
          "$touched_wireguard" "$had_wireguard" && service_restart; then
        warn "恢复失败，已自动回到操作前配置。"
      else
        err "自动回滚后 Xray 仍无法启动，请使用 VPS 控制台检查。"
        rc=2
      fi
    fi
    rm -rf "$stage_root" "$rollback_root" "$stage_state" "$rollback_state"
    exit "$rc"
  }
  trap cleanup_restore_transaction EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  cp -a "$extracted/$conf_name" "$stage_root/$conf_name"
  if [[ -d "$extracted/$cert_name" ]]; then
    cp -a "$extracted/$cert_name" "$stage_root/$cert_name"
    touched_certs=1
  fi
  touched_wireguard=1
  [[ ! -d "$extracted/wireguard" ]] || cp -a "$extracted/wireguard" "$stage_state/wireguard"

  rollback_needed=1
  if [[ -e "$CONF_DIR" ]]; then
    mv "$CONF_DIR" "$rollback_root/conf.d"
    had_conf=1
  fi
  mv "$stage_root/$conf_name" "$CONF_DIR"
  swapped_conf=1

  if (( touched_certs )); then
    if [[ -e "$CERT_DIR" ]]; then
      mv "$CERT_DIR" "$rollback_root/certs"
      had_certs=1
    fi
    mv "$stage_root/$cert_name" "$CERT_DIR"
  fi

  if [[ -e "$wireguard_dir" ]]; then
    mv "$wireguard_dir" "$rollback_state/wireguard"
    had_wireguard=1
  fi
  [[ ! -d "$stage_state/wireguard" ]] || mv "$stage_state/wireguard" "$wireguard_dir"

  ensure_layout
  if (( touched_certs )) && [[ -d "$CERT_DIR" ]]; then
    chown -R root:"$XRAY_RUN_GROUP" "$CERT_DIR" 2>/dev/null || true
    find "$CERT_DIR" -type d -exec chmod 750 {} \;
    find "$CERT_DIR" -type f -exec chmod 640 {} \;
  fi
  if [[ -d "$wireguard_dir" ]]; then
    chown -R root:root "$wireguard_dir" 2>/dev/null || true
    find "$wireguard_dir" -type d -exec chmod 700 {} \;
    find "$wireguard_dir" -type f -exec chmod 600 {} \;
  fi
  if test_config && service_restart; then
    committed=1
    ok "恢复完成。"
    return 0
  fi
  return 1
)

restore_backup() (
  need_xray || return
  local files=() f i choice selected tmp safety_backup rc
  tmp=""
  cleanup_restore_extract() {
    [[ -z "$tmp" ]] || rm -rf "$tmp"
  }
  trap cleanup_restore_extract EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

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

  validate_backup_archive "$selected" || return 1
  tmp="$(mktemp -d)"
  tar -xzf "$selected" -C "$tmp"
  [[ -d "$tmp/$(basename "$CONF_DIR")" ]] || { err "备份结构无效。"; return 1; }

  if ! test_config_dir "$tmp/$(basename "$CONF_DIR")"; then
    err "备份中的配置测试失败，拒绝恢复。"
    return 1
  fi

  confirm "确认恢复 $(basename "$selected")？当前配置会先再备份一次。" || return 0
  safety_backup="$(backup_now)" || {
    err "无法为当前配置创建安全备份，恢复已取消。"
    return 1
  }
  info "恢复前安全备份：$safety_backup"

  if restore_backup_transaction "$tmp"; then
    return 0
  else
    rc=$?
    return "$rc"
  fi
)

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

update_manager_script() {
  local launcher="${XRAY_MANAGER_LAUNCHER_PATH:-/usr/local/sbin/xraym}"

  if [[ ! -x "$launcher" ]]; then
    launcher="$(command -v xraym 2>/dev/null || true)"
  fi
  if [[ -z "$launcher" || ! -x "$launcher" ]]; then
    err "未找到 Xray Manager Launcher，无法从菜单自更新。"
    warn "请重新运行 Cloudflare 或私有 GitHub 安装入口。"
    return 1
  fi

  info "按当前安装来源更新 Xray Manager Launcher + Core..."
  "$launcher" --self-update || {
    err "Xray Manager 更新失败。"
    return 1
  }

  ok "Xray Manager 更新流程已完成。"
  if confirm "立即重新载入新版菜单？"; then
    exec "$launcher"
  fi
  warn "当前仍是更新前的菜单进程；退出后重新运行 sudo xraym 即可载入新版。"
}

inbound_management_menu() {
  while true; do
    clear || true
    echo "========== 入站管理 =========="
    echo "1) 添加入站协议"
    echo "2) 查看入站列表（支持编号选择）"
    echo "3) 入站详情 / 快捷管理"
    echo "4) 编辑入站"
    echo "5) 用户管理"
    echo "6) 分享链接 / WireGuard 客户端配置与二维码"
    echo "7) 删除入站"
    echo "8) 查看入站原始 JSON"
    echo "9) 入站健康诊断"
    echo "配置目录：$CONF_DIR"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) add_inbound_menu ;;
      2) list_inbounds; pause ;;
      3) inbound_detail_menu ;;
      4) edit_inbound; pause ;;
      5) inbound_user_management_menu ;;
      6) show_inbound_share_link; pause ;;
      7) delete_inbound; pause ;;
      8) show_inbound_raw_config; pause ;;
      9) diagnose_inbound || true; pause ;;
      0) return ;;
    esac
  done
}

list_port_forwards() {
  ensure_layout
  local found=0 f
  printf "\n%-24s %-24s %-8s %-36s %-10s\n" "TAG" "LISTEN" "PORT" "TARGET" "NETWORK"
  printf "%-24s %-24s %-8s %-36s %-10s\n" "------------------------" "------------------------" "--------" "------------------------------------" "----------"
  shopt -s nullglob
  for f in "$CONF_DIR"/10_inbound_*.json; do
    if jq -e '.inbounds[]? | select(.protocol == "tunnel")' "$f" >/dev/null 2>&1; then
      found=1
      jq -r '
        .inbounds[]? | select(.protocol == "tunnel") |
        [
          (.tag // "-"),
          (.listen // "-"),
          ((.port // "-") | tostring),
          ((.settings.rewriteAddress // "-") + ":" + ((.settings.rewritePort // "-") | tostring)),
          (.settings.allowedNetwork // "tcp")
        ] | @tsv
      ' "$f" |
      while IFS=$'\t' read -r tag listen port target network; do
        printf "%-24s %-24s %-8s %-36s %-10s\n" "$tag" "$listen" "$port" "$target" "$network"
      done
    fi
  done
  shopt -u nullglob
  (( found )) || echo "暂无端口转发。"
  echo
}

delete_port_forward() {
  list_port_forwards
  local tag file
  tag="$(ask_required "输入要删除的端口转发 Tag")"
  file="$(grep -Rl --include='10_inbound_*.json' "\"tag\"[[:space:]]*:[[:space:]]*\"$tag\"" "$CONF_DIR" 2>/dev/null | head -n 1 || true)"
  [[ -n "$file" ]] || { err "未找到端口转发：$tag"; return; }
  jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag and .protocol == "tunnel")' "$file" >/dev/null 2>&1 || {
    err "$tag 不是 Tunnel 端口转发。"
    return
  }
  delete_inbound "$tag"
}

port_forward_menu() {
  while true; do
    clear || true
    echo "========== 端口转发 =========="
    echo "1) 新增端口转发"
    echo "2) 查看端口转发列表"
    echo "3) 删除端口转发"
    echo "0) 返回"
    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) add_tunnel; pause ;;
      2) list_port_forwards; pause ;;
      3) delete_port_forward; pause ;;
      0) return ;;
    esac
  done
}

bbr_menu_action() {
  local choice
  echo "1) 启用/修复 BBR  2) 查看 BBR 状态"
  read -r -p "请选择 [1]: " choice || true
  if [[ "${choice:-1}" == "2" ]]; then
    bbr_status
  else
    enable_bbr
  fi
}

main_menu() {
  while true; do
    clear || true
    printf "${C_CYAN}${C_BOLD}Xray Manager %s${C_RESET}\n" "$SCRIPT_VERSION"
    echo "=================================================="
    echo "1) 一键安装 / 修复 Xray"
    echo "2) 入站管理"
    echo "3) 出站管理"
    echo "4) 路由与分流"
    echo "5) 端口转发"
    echo "6) 更新 Xray-core"
    echo "7) 更新 GeoIP / GeoSite"
    echo "8) Xray 服务 / 配置测试 / 日志"
    echo "9) 备份 / 恢复"
    echo "10) UFW 防火墙"
    echo "11) BBR"
    echo "12) TLS 证书管理"
    echo "13) IPv6-only / NAT64 网络助手"
    echo "14) 完全离线安装 / 导入 Xray + GeoData"
    echo "15) 系统信息"
    echo "16) 更新 Xray Manager 脚本"
    echo "0) 退出"
    echo "=================================================="

    local c
    read -r -p "请选择: " c || true
    case "$c" in
      1) with_manager_lock "安装或修复 Xray" install_or_repair_xray || true; pause ;;
      2) with_manager_lock "入站管理" inbound_management_menu || { pause; continue; } ;;
      3) with_manager_lock "出站管理" outbound_menu || { pause; continue; } ;;
      4) with_manager_lock "路由管理" routing_menu || { pause; continue; } ;;
      5) with_manager_lock "端口转发管理" port_forward_menu || { pause; continue; } ;;
      6) with_manager_lock "更新 Xray-core" update_xray || true; pause ;;
      7) with_manager_lock "更新 GeoData" update_geodata || true; pause ;;
      8) with_manager_lock "服务与配置管理" service_menu || { pause; continue; } ;;
      9) with_manager_lock "备份与恢复" backup_menu || { pause; continue; } ;;
      10) with_manager_lock "UFW 管理" ufw_menu || { pause; continue; } ;;
      11) with_manager_lock "BBR 管理" bbr_menu_action || true; pause ;;
      12) with_manager_lock "TLS 证书管理" certificate_menu || true; pause ;;
      13) with_manager_lock "IPv6-only 网络管理" ipv6_only_menu || { pause; continue; } ;;
      14) with_manager_lock "离线导入" offline_import_menu || true; pause ;;
      15) system_info; pause ;;
      16) update_manager_script; pause ;;
      0) echo "Bye."; exit 0 ;;
      *) warn "无效选择。"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  require_root
  case "${1:-}" in
    --install-dependencies)
      [[ $# -eq 1 ]] || die "--install-dependencies 不接受其他参数。"
      detect_platform
      load_network_state
      pkg_install_base
      ok "Xray Manager 基础依赖已安装。"
      ;;
    "")
      detect_platform
      load_network_state
      ensure_runtime_dependencies
      ensure_layout
      main_menu
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
fi
