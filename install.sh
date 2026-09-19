#!/usr/bin/env bash
# GitHub bootstrap installer for xinian5216/xray-manager.
# Anonymous access is the default; a token is optional (rate limit / private fork).
# This is also the single migration entry for legacy Manager installs
# (GitHub Private and retired Cloudflare/R2 channels): it never invokes the
# old manager's own update commands.
set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY="xinian5216/xray-manager"
REF="${XRAY_MANAGER_REF:-main}"
API_BASE="https://api.github.com/repos/${REPOSITORY}/contents"
INSTALL_PATH="${XRAY_MANAGER_INSTALL_PATH:-/usr/local/sbin/xraym}"
CORE_PATH="${XRAY_MANAGER_CORE_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}"
STATE_DIR="${XRAY_MANAGER_STATE_DIR:-/etc/xray-manager}"
LIB_DIR="${XRAY_MANAGER_LIB_DIR:-$(dirname "$CORE_PATH")}"
RELEASES_DIR="${XRAY_MANAGER_RELEASES_DIR:-$LIB_DIR/releases}"
CURRENT_LINK="${XRAY_MANAGER_CURRENT_LINK:-$LIB_DIR/current}"
PREVIOUS_LINK="${XRAY_MANAGER_PREVIOUS_LINK:-$LIB_DIR/previous}"
UPDATE_SOURCE_FILE="${STATE_DIR}/manager_update_source"
CLOUDFLARE_URL_FILE="${STATE_DIR}/cloudflare_url"
DOWNLOAD_PROXY="${XRAY_DOWNLOAD_PROXY:-}"
RUN_AFTER_INSTALL=0

LEGACY_TYPE="fresh-install"
LEGACY_VERSION=""
LEGACY_CORE_VERSION=""
LEGACY_UPDATE_SOURCE=""
LEGACY_DETECTED=0
LEGACY_CLOUDFLARE_STATE=0
LEGACY_STATE_CLEANED=0
LEGACY_BACKUP_DIR=""

C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'

info() { printf "${C_BLUE}[i]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[✓]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*"; }
err()  { printf "${C_RED}[x]${C_RESET} %s\n" "$*" >&2; }

usage() {
  cat <<EOF
Usage: bash install.sh [options]

Options:
  --run                 安装完成后立即启动 xraym
  --ref <branch/tag>    指定 Git ref，默认 main
  --proxy <URL>         下载使用 HTTP/SOCKS5 代理
  --install-path <path> Launcher 安装路径
  --core-path <path>    Core 安装路径
  -h, --help            显示帮助

Authentication:
  公开仓库默认匿名读取，无需任何 Token。
  XRAY_MANAGER_GITHUB_TOKEN 或 GH_TOKEN 是可选的增强：
  适用于私有 fork，或需要更高 GitHub API 速率限制时。
  Token 只用于本次请求的 Authorization 头，不会持久保存。
EOF
}

while (($#)); do
  case "$1" in
    --run) RUN_AFTER_INSTALL=1; shift ;;
    --ref)
      [[ $# -ge 2 ]] || { err "--ref 缺少参数"; exit 2; }
      REF="$2"; shift 2
      ;;
    --proxy)
      [[ $# -ge 2 ]] || { err "--proxy 缺少参数"; exit 2; }
      DOWNLOAD_PROXY="$2"; shift 2
      ;;
    --install-path)
      [[ $# -ge 2 ]] || { err "--install-path 缺少参数"; exit 2; }
      INSTALL_PATH="$2"; shift 2
      ;;
    --core-path)
      [[ $# -ge 2 ]] || { err "--core-path 缺少参数"; exit 2; }
      CORE_PATH="$2"; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || {
  err "缺少 curl。请先通过系统软件源安装 curl。"
  exit 1
}

# Optional token. The repository is public by default, so anonymous access is
# the normal path; a token only raises GitHub API rate limits or unlocks forks.
get_token() {
  local token="${XRAY_MANAGER_GITHUB_TOKEN:-${GH_TOKEN:-}}"
  printf '%s' "$token"
}

curl_private() {
  local path="$1" out="$2" token="$3" http_code rc
  local args=(
    -fsSL --retry 4 --connect-timeout 12 --max-time 180
    -H "Accept: application/vnd.github.raw+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  # Never send a token anywhere except the GitHub API itself.
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi
  args+=("${API_BASE}/${path}?ref=${REF}" -o "$out" -w "%{http_code}")

  if [[ -n "$DOWNLOAD_PROXY" ]]; then
    if http_code="$(curl -x "$DOWNLOAD_PROXY" "${args[@]}")"; then
      rc=0
    else
      rc=$?
    fi
  else
    if http_code="$(curl "${args[@]}")"; then
      rc=0
    else
      rc=$?
    fi
  fi

  if (( rc != 0 )); then
    err "GitHub API 下载失败：$path（HTTP ${http_code:-未知}）"
    case "$http_code" in
      404)
        warn "仓库或 ref 不存在，或当前为无法读取的私有 fork。"
        warn "公开仓库请确认 ref 名称；私有 fork 请提供 Contents: Read-only 的 Fine-grained PAT。"
        ;;
      403|429)
        warn "可能是匿名 GitHub API 速率限制（每小时 60 次）。"
        warn "可设置 XRAY_MANAGER_GITHUB_TOKEN 或 GH_TOKEN 提升限额后重试。"
        ;;
    esac
    return "$rc"
  fi
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 1
  fi
}

verify_payload() {
  local checksums="$1" base="$2" file expected actual
  shift 2
  for file in "$@"; do
    expected="$(awk -v f="$file" '$2==f {print $1; exit}' "$checksums")"
    actual="$(sha256_file "$base/$file" 2>/dev/null || true)"
    [[ -n "$expected" && -n "$actual" && "$expected" == "$actual" ]] || {
      err "SHA256 校验失败：$file"
      return 1
    }
  done
}

patch_core_for_launcher() {
  local file="$1"
  local old='install -m 755 "$self" /usr/local/sbin/xraym'
  local new='install -m 755 "$self" "${XRAY_MANAGER_CORE_INSTALL_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}"'

  if grep -Fq "$old" "$file"; then
    sed -i "s|$old|$new|" "$file"
  elif grep -Fq 'XRAY_MANAGER_CORE_INSTALL_PATH' "$file"; then
    :
  else
    err "无法应用 Core/Launcher 兼容补丁，拒绝安装。"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Legacy installation detection (single migration entry: this installer).
# ---------------------------------------------------------------------------
read_marker_version() {
  local file="$1" marker="$2" version
  [[ -f "$file" ]] || return 1
  version="$(sed -n "s/^${marker}=\"\([^\"]*\)\".*/\1/p" "$file" | head -n1)"
  [[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || return 1
  printf '%s' "$version"
}

can_write_path() {
  local dir="$1"
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
  [[ -e "$dir" ]] || dir="$(dirname "$dir")"
  while [[ ! -e "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    dir="$(dirname "$dir")"
  done
  [[ -w "$dir" ]]
}

privileged() {
  local target="$1"
  shift
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] || can_write_path "$target"; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || {
      err "需要 root 权限写入 $target，但系统没有 sudo。"
      return 1
    }
    sudo "$@"
  fi
}

detect_legacy_installation() {
  local fixed_launcher="" fixed_core="" atomic_dir="" atomic_version=""

  if [[ -f "$INSTALL_PATH" && ! -L "$INSTALL_PATH" ]]; then
    fixed_launcher="$INSTALL_PATH"
  fi
  if [[ -f "$CORE_PATH" && ! -L "$CORE_PATH" ]]; then
    fixed_core="$CORE_PATH"
  fi

  if [[ -L "$CURRENT_LINK" ]]; then
    atomic_dir="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
    if [[ -n "$atomic_dir" && -d "$atomic_dir" \
       && -f "$atomic_dir/xray-manager.sh" && -f "$atomic_dir/xray-manager-core.sh" ]]; then
      atomic_version="$(read_marker_version "$atomic_dir/xray-manager.sh" PROJECT_VERSION || true)"
    else
      atomic_dir=""
    fi
  fi

  if [[ -r "$STATE_DIR/manager_update_source" ]]; then
    LEGACY_UPDATE_SOURCE="$(tr -d '[:space:]' <"$STATE_DIR/manager_update_source" 2>/dev/null || true)"
  fi
  if [[ -r "$CLOUDFLARE_URL_FILE" ]]; then
    LEGACY_CLOUDFLARE_STATE=1
    [[ -n "$LEGACY_UPDATE_SOURCE" ]] || LEGACY_UPDATE_SOURCE="cloudflare"
  fi

  if [[ -n "$atomic_dir" ]]; then
    LEGACY_VERSION="$atomic_version"
    LEGACY_CORE_VERSION="$(read_marker_version "$atomic_dir/xray-manager-core.sh" SCRIPT_VERSION || true)"
    case "$LEGACY_UPDATE_SOURCE" in
      cloudflare) LEGACY_TYPE="legacy-cloudflare-r2" ;;
      github)     LEGACY_TYPE="legacy-github" ;;
      *)          LEGACY_TYPE="atomic-release-layout" ;;
    esac
  elif [[ -n "$fixed_launcher" || -n "$fixed_core" ]]; then
    LEGACY_VERSION="$(read_marker_version "$fixed_launcher" PROJECT_VERSION || true)"
    [[ -n "$LEGACY_VERSION" ]] || LEGACY_VERSION="$(read_marker_version "$fixed_launcher" SCRIPT_VERSION || true)"
    LEGACY_CORE_VERSION="$(read_marker_version "$fixed_core" SCRIPT_VERSION || true)"
    if [[ -z "$LEGACY_VERSION" && -z "$LEGACY_CORE_VERSION" ]]; then
      LEGACY_TYPE="unknown-legacy"
    else
      case "$LEGACY_UPDATE_SOURCE" in
        cloudflare) LEGACY_TYPE="legacy-cloudflare-r2" ;;
        github)     LEGACY_TYPE="legacy-github" ;;
        *)          LEGACY_TYPE="legacy-fixed-layout" ;;
      esac
    fi
  elif [[ -d "$RELEASES_DIR" || -L "$CURRENT_LINK" \
       || -f "$STATE_DIR/manager_update_source" || -f "$CLOUDFLARE_URL_FILE" ]]; then
    LEGACY_TYPE="unknown-legacy"
  fi

  if [[ "$LEGACY_TYPE" != "fresh-install" ]]; then
    LEGACY_DETECTED=1
  fi
}

report_legacy_installation() {
  local version="未知"
  [[ -n "$LEGACY_VERSION" ]] && version="$LEGACY_VERSION"
  case "$LEGACY_TYPE" in
    legacy-cloudflare-r2)
      warn "检测到旧版 Cloudflare/R2 安装。"
      echo "旧版本：v$version"
      echo "旧更新源：Cloudflare/R2（已退役）"
      echo "迁移目标：GitHub Public"
      ;;
    legacy-github)
      warn "检测到旧版 GitHub Private 安装。"
      echo "旧版本：v$version"
      echo "迁移目标：GitHub Public"
      echo "以后默认无需 PAT。"
      ;;
    legacy-fixed-layout)
      warn "检测到旧版固定路径安装。"
      echo "旧版本：v$version"
      echo "将迁移到 releases/<version> + current/previous 原子布局。"
      ;;
    unknown-legacy)
      warn "检测到无法完整识别版本的旧 Xray Manager 安装。"
      echo "将按旧布局进行兼容迁移。"
      ;;
    atomic-release-layout)
      info "检测到旧版原子发布布局安装（当前版本 v${version}）。"
      ;;
    current-install)
      info "当前已是仓库版本 v$version，将执行重装。"
      ;;
    fresh-install)
      info "未检测到旧版 Xray Manager，将执行全新安装。"
      ;;
  esac
  echo "迁移方式：重新下载最新版 Launcher + Core 并事务安装；不会调用旧版 self-update。"
  echo "Xray 配置、证书、WireGuard 与备份保持不变。"
}

backup_legacy_manager() {
  local stamp dir info_file target
  (( LEGACY_DETECTED )) || return 0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$LIB_DIR/migration-backup/$stamp"
  info_file="$dir/migration.info"
  privileged "$LIB_DIR" install -d -m 700 "$dir" || {
    warn "迁移前备份目录创建失败：$dir（继续安装，但旧文件不做额外备份）"
    return 0
  }
  LEGACY_BACKUP_DIR="$dir"
  if [[ -f "$INSTALL_PATH" && ! -L "$INSTALL_PATH" ]]; then
    privileged "$dir" install -m 600 "$INSTALL_PATH" "$dir/xraym" 2>/dev/null || true
  fi
  if [[ -f "$CORE_PATH" && ! -L "$CORE_PATH" ]]; then
    privileged "$dir" install -m 600 "$CORE_PATH" "$dir/xray-manager-core.sh" 2>/dev/null || true
  fi
  {
    echo "type=$LEGACY_TYPE"
    echo "old_version=${LEGACY_VERSION:-unknown}"
    echo "old_core_version=${LEGACY_CORE_VERSION:-unknown}"
    echo "update_source=${LEGACY_UPDATE_SOURCE:-none}"
    echo "current=$(readlink -f "$CURRENT_LINK" 2>/dev/null || printf none)"
    echo "previous=$(readlink -f "$PREVIOUS_LINK" 2>/dev/null || printf none)"
    if [[ -r "$UPDATE_SOURCE_FILE" ]]; then
      echo "manager_update_source=$(tr -d '[:space:]' <"$UPDATE_SOURCE_FILE")"
    fi
    if [[ -r "$CLOUDFLARE_URL_FILE" ]]; then
      echo "cloudflare_url=$(head -n 1 "$CLOUDFLARE_URL_FILE" 2>/dev/null || true)"
    fi
  } >"$info_file"
  info "旧 Manager 已备份到：$dir"
}

verify_new_xraym() {
  local version
  [[ -x "$INSTALL_PATH" ]] || {
    err "新 Launcher 未就绪：$INSTALL_PATH"
    return 1
  }
  "$INSTALL_PATH" --version >/dev/null 2>&1 || {
    err "新 Launcher 无法执行：$INSTALL_PATH"
    return 1
  }
  version="$(read_marker_version "$INSTALL_PATH" PROJECT_VERSION || true)"
  [[ "$version" == "$VERSION" ]] || {
    err "安装后版本校验失败：$version != $VERSION"
    return 1
  }
}

cleanup_retired_state_files() {
  if [[ ! -f "$UPDATE_SOURCE_FILE" && ! -f "$CLOUDFLARE_URL_FILE" ]]; then
    return 0
  fi
  if privileged "$STATE_DIR" rm -f "$UPDATE_SOURCE_FILE" "$CLOUDFLARE_URL_FILE" 2>/dev/null; then
    LEGACY_STATE_CLEANED=1
  else
    warn "旧更新源状态文件清理失败（不影响新版本使用）：$STATE_DIR"
  fi
}

print_migration_summary() {
  local layout
  (( LEGACY_DETECTED )) || return 0
  case "$LEGACY_TYPE" in
    legacy-cloudflare-r2) layout="Cloudflare/R2（已退役）" ;;
    legacy-github)        layout="GitHub Private" ;;
    legacy-fixed-layout)  layout="旧固定路径布局" ;;
    unknown-legacy)       layout="未知旧布局" ;;
    atomic-release-layout) layout="原子发布旧版本" ;;
    current-install)      layout="当前版本重装" ;;
    *)                    layout="$LEGACY_TYPE" ;;
  esac
  echo
  echo "================ Xray Manager 迁移完成 ================"
  echo "旧版本：${LEGACY_VERSION:-未知}"
  echo "旧布局：$layout"
  echo "新版本：$VERSION"
  echo "在线更新源：GitHub Public"
  echo "Manager 原子布局：已启用"
  if (( LEGACY_CLOUDFLARE_STATE )); then
    if (( LEGACY_STATE_CLEANED )); then
      echo "旧 Cloudflare 状态：已清理"
    else
      echo "旧 Cloudflare 状态：清理失败（可手动删除 $STATE_DIR 下的 manager_update_source 与 cloudflare_url）"
    fi
  else
    echo "旧 Cloudflare 状态：无需清理"
  fi
  echo
  echo "Xray 配置：保持不变"
  echo "证书：保持不变"
  echo "WireGuard：保持不变"
  echo "备份：保持不变"
  if [[ -n "$LEGACY_BACKUP_DIR" ]]; then
    echo "迁移前备份：$LEGACY_BACKUP_DIR"
  fi
  echo
  echo "以后更新："
  echo "sudo xraym --self-update"
}

install_release_pair() {
  export XRAY_MANAGER_INSTALL_PATH="$INSTALL_PATH"
  export XRAY_MANAGER_CORE_PATH="$CORE_PATH"
  # 使用刚下载的 Launcher 事务安装函数，与后续自更新共用同一发布布局。
  # shellcheck source=/dev/null
  source "$1"
  install_pair "$1" "$2"
}

install_runtime_dependencies() {
  local core="$1"
  local -a command=(bash "$core" --install-dependencies)

  if [[ -n "$DOWNLOAD_PROXY" ]]; then
    command=(env "XRAY_DOWNLOAD_PROXY=$DOWNLOAD_PROXY" "${command[@]}")
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "${command[@]}"
  else
    command -v sudo >/dev/null 2>&1 || {
      err "安装基础依赖需要 root，但系统没有 sudo。"
      return 1
    }
    sudo "${command[@]}"
  fi
}

TOKEN="$(get_token)"
if [[ -n "$TOKEN" ]]; then
  info "使用可选的 GitHub Token（仅用于提高 API 速率限制）。"
else
  info "未提供 GitHub Token，将匿名读取公开仓库（可选 Token 只用于提速）。"
fi

detect_legacy_installation

TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
  unset TOKEN GH_TOKEN XRAY_MANAGER_GITHUB_TOKEN 2>/dev/null || true
}
trap cleanup EXIT INT TERM

info "读取仓库 VERSION..."
curl_private "VERSION" "$TMP/VERSION" "$TOKEN"
VERSION="$(tr -d '[:space:]' <"$TMP/VERSION")"
[[ -n "$VERSION" ]] || { err "VERSION 为空。"; exit 1; }

if [[ "$LEGACY_TYPE" == "atomic-release-layout" && "$LEGACY_VERSION" == "$VERSION" ]]; then
  LEGACY_TYPE="current-install"
  LEGACY_DETECTED=0
fi

report_legacy_installation

info "下载 Launcher、Core 与 SHA256SUMS..."
curl_private "SHA256SUMS" "$TMP/SHA256SUMS" "$TOKEN"
curl_private "xray-manager.sh" "$TMP/xray-manager.sh" "$TOKEN"
mkdir -p "$TMP/lib"
curl_private "lib/xray-manager-core.sh" "$TMP/lib/xray-manager-core.sh" "$TOKEN"

verify_payload "$TMP/SHA256SUMS" "$TMP" \
  "xray-manager.sh" "lib/xray-manager-core.sh"

patch_core_for_launcher "$TMP/lib/xray-manager-core.sh"
bash -n "$TMP/xray-manager.sh"
bash -n "$TMP/lib/xray-manager-core.sh"

backup_legacy_manager
info "安装 Xray Manager 运行依赖（含 jq、OpenSSL、iproute2）..."
install_runtime_dependencies "$TMP/lib/xray-manager-core.sh"
install_release_pair "$TMP/xray-manager.sh" "$TMP/lib/xray-manager-core.sh"
verify_new_xraym
cleanup_retired_state_files
print_migration_summary
ok "Xray Manager 项目版本 $VERSION 安装完成。"
echo "Launcher: $INSTALL_PATH"
echo "Core    : $CORE_PATH"
echo
echo "当前仓库已公开，后续普通更新不需要 GitHub Token。"
echo "Token 仅用于提高 API 限额或访问 Private fork，默认不会保存。"
echo
echo "运行：sudo xraym"
echo "更新：sudo xraym --self-update"

if (( RUN_AFTER_INSTALL )); then
  trap - EXIT INT TERM
  rm -rf "$TMP"
  unset TOKEN GH_TOKEN XRAY_MANAGER_GITHUB_TOKEN 2>/dev/null || true
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    exec "$INSTALL_PATH"
  else
    exec sudo "$INSTALL_PATH"
  fi
fi
