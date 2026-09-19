#!/usr/bin/env bash
# Xray Manager launcher / updater (GitHub, anonymous by default).
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_VERSION="1.8.4"
CORE_VERSION="1.8.4"
REPOSITORY="xinian5216/xray-manager"
REF="${XRAY_MANAGER_REF:-main}"
API_BASE="https://api.github.com/repos/${REPOSITORY}/contents"
INSTALL_PATH="${XRAY_MANAGER_INSTALL_PATH:-/usr/local/sbin/xraym}"
CORE_PATH="${XRAY_MANAGER_CORE_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}"
LIB_DIR="${XRAY_MANAGER_LIB_DIR:-}"
RELEASES_DIR="${XRAY_MANAGER_RELEASES_DIR:-}"
CURRENT_LINK="${XRAY_MANAGER_CURRENT_LINK:-}"
PREVIOUS_LINK="${XRAY_MANAGER_PREVIOUS_LINK:-}"
DOWNLOAD_PROXY="${XRAY_DOWNLOAD_PROXY:-}"
LOCK_DIR="${XRAY_MANAGER_LOCK_DIR:-/run/xray-manager.lock}"
ALLOW_DOWNGRADE=0
MANAGER_LOCK_HELD=0

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
Xray Manager Launcher ${PROJECT_VERSION}

Usage:
  xraym                     启动 Xray Manager 核心菜单
  xraym --self-update       从 GitHub 仓库更新 Launcher + Core
  xraym --self-update [--allow-downgrade]
  xraym --rollback          切换到已校验的本地上一版本
  xraym --version           查看项目与核心版本
  xraym --help              查看帮助

Environment:
  XRAY_MANAGER_GITHUB_TOKEN 可选：Fine-grained PAT（私有 fork / 提升 API 限额）
  GH_TOKEN                  可选：GitHub Token 环境变量
  XRAY_DOWNLOAD_PROXY       HTTP/SOCKS5 下载代理
  XRAY_MANAGER_REF          Git 分支/标签，默认 main
  XRAY_MANAGER_LOCK_DIR     全局操作锁目录，默认 /run/xray-manager.lock
EOF
}

manager_version_action() {
  local current="${1#v}" target="${2#v}" current_part target_part index
  local -a current_parts target_parts
  [[ "$current" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || {
    err "本机 VERSION 格式无效：$1"
    return 1
  }
  [[ "$target" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || {
    err "目标 VERSION 格式无效：$2"
    return 1
  }
  IFS=. read -r -a current_parts <<<"$current"
  IFS=. read -r -a target_parts <<<"$target"
  for index in 0 1 2; do
    current_part="${current_parts[$index]}"
    target_part="${target_parts[$index]}"
    if (( 10#$target_part > 10#$current_part )); then
      printf 'upgrade'
      return 0
    elif (( 10#$target_part < 10#$current_part )); then
      printf 'downgrade'
      return 0
    fi
  done
  printf 'reinstall'
}

approve_target_version() {
  local target="$1" action ans
  action="$(manager_version_action "$PROJECT_VERSION" "$target")" || return 1
  case "$action" in
    upgrade)
      info "版本判定：upgrade（$PROJECT_VERSION -> $target）"
      ;;
    reinstall)
      info "版本判定：reinstall（$PROJECT_VERSION -> $target）"
      printf "当前已是该版本，仍强制重新安装？ [y/N]: "
      read -r ans || true
      [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || return 10
      ;;
    downgrade)
      warn "版本判定：downgrade（$PROJECT_VERSION -> $target）"
      if (( ! ALLOW_DOWNGRADE )); then
        err "默认拒绝降级；确认需要回退时请显式添加 --allow-downgrade。"
        return 1
      fi
      warn "已显式允许降级，现有新版功能或配置可能不被旧版识别。"
      ;;
  esac
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

cleanup_legacy_update_state() {
  # The Cloudflare/R2 update source no longer exists. Old installs may still
  # carry these marker files; delete them best-effort and never block updates.
  rm -f /etc/xray-manager/manager_update_source \
        /etc/xray-manager/cloudflare_url 2>/dev/null || true
}

# Optional token. The repository is public by default, so anonymous access is
# the normal path; a token only raises GitHub API rate limits or unlocks forks.
get_token() {
  local token="${XRAY_MANAGER_GITHUB_TOKEN:-${GH_TOKEN:-}}"
  printf '%s' "$token"
}

curl_private() {
  local path="$1" out="$2" token="$3"
  local args=(
    -fsSL
    --retry 4
    --connect-timeout 12
    --max-time 180
    -H "Accept: application/vnd.github.raw+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  # Never send a token anywhere except the GitHub API itself.
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi
  args+=("${API_BASE}/${path}?ref=${REF}" -o "$out")

  if [[ -n "$DOWNLOAD_PROXY" ]]; then
    curl -x "$DOWNLOAD_PROXY" "${args[@]}"
  else
    curl "${args[@]}"
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

manager_layout_paths() {
  INSTALL_PATH="${XRAY_MANAGER_INSTALL_PATH:-${INSTALL_PATH:-/usr/local/sbin/xraym}}"
  CORE_PATH="${XRAY_MANAGER_CORE_PATH:-${CORE_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}}"
  LIB_DIR="${XRAY_MANAGER_LIB_DIR:-$(dirname "$CORE_PATH")}"
  RELEASES_DIR="${XRAY_MANAGER_RELEASES_DIR:-$LIB_DIR/releases}"
  CURRENT_LINK="${XRAY_MANAGER_CURRENT_LINK:-$LIB_DIR/current}"
  PREVIOUS_LINK="${XRAY_MANAGER_PREVIOUS_LINK:-$LIB_DIR/previous}"
}

manager_can_write() {
  local path="$1" dir="$1"
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
  [[ -e "$dir" ]] || dir="$(dirname "$dir")"
  while [[ ! -e "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    dir="$(dirname "$dir")"
  done
  [[ -w "$dir" ]]
}

manager_needs_sudo() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 1
  manager_layout_paths
  manager_can_write "$LIB_DIR" && manager_can_write "$(dirname "$INSTALL_PATH")" && return 1
  return 0
}

run_priv() {
  if manager_needs_sudo; then
    command -v sudo >/dev/null 2>&1 || {
      err "需要 root 权限写入 /usr/local，但系统没有 sudo。"
      return 1
    }
    sudo "$@"
  else
    "$@"
  fi
}

read_project_version() {
  local file="$1" version
  [[ -f "$file" ]] || return 1
  version="$(sed -n 's/^PROJECT_VERSION="\([^"]*\)".*/\1/p' "$file" | head -n1)"
  [[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || return 1
  printf '%s' "$version"
}

read_core_version() {
  local file="$1" version
  [[ -f "$file" ]] || return 1
  version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$file" | head -n1)"
  [[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || return 1
  printf '%s' "$version"
}

resolve_link() {
  local link="$1"
  if [[ -L "$link" || -d "$link" ]]; then
    readlink -f "$link" 2>/dev/null || true
  fi
}

verify_release_dir() {
  local dir="$1" launcher core
  launcher="$dir/xray-manager.sh"
  core="$dir/xray-manager-core.sh"
  [[ -f "$launcher" && -f "$core" ]] || return 1
  [[ -x "$launcher" && -x "$core" ]] || return 1
  bash -n "$launcher" || return 1
  bash -n "$core" || return 1
  read_project_version "$launcher" >/dev/null || return 1
  read_core_version "$core" >/dev/null || return 1
}

selfcheck_current_release() {
  local dir version core_ver
  if [[ "${XRAY_MANAGER_FAIL_STEP:-}" == "selfcheck" ]]; then
    return 1
  fi
  dir="$(resolve_link "$CURRENT_LINK")"
  [[ -n "$dir" ]] || return 1
  verify_release_dir "$dir" || return 1
  version="$(read_project_version "$dir/xray-manager.sh")" || return 1
  core_ver="$(read_core_version "$dir/xray-manager-core.sh")" || return 1
  [[ "$version" == "$core_ver" ]] || {
    err "Launcher/Core 版本不一致：$version vs $core_ver"
    return 1
  }
  bash -c 'source "$1"; [[ -n "${PROJECT_VERSION:-}" ]]' _ "$dir/xray-manager.sh" || return 1
  bash -c 'source "$1"; [[ -n "${SCRIPT_VERSION:-}" ]]' _ "$dir/xray-manager-core.sh" || return 1
}

atomic_symlink() {
  local target="$1" link="$2" tmp
  tmp="${link}.tmp.$$"
  if [[ -e "$link" && ! -L "$link" ]]; then
    err "拒绝覆盖非符号链接：$link"
    return 1
  fi
  run_priv ln -sfn "$target" "$tmp" || return 1
  if run_priv mv -fT "$tmp" "$link" 2>/dev/null; then
    return 0
  fi
  # BusyBox/non-GNU mv has no -T; ln -sfn replaces the link in place.
  if run_priv ln -sfn "$target" "$link"; then
    run_priv rm -f "$tmp"
    return 0
  fi
  run_priv rm -f "$tmp"
  return 1
}

install_release_file() {
  run_priv install -m 755 "$1" "$2"
}

replace_with_symlink() {
  local target="$1" link="$2" backup
  if [[ -L "$link" ]]; then
    atomic_symlink "$target" "$link"
    return
  fi
  if [[ -e "$link" ]]; then
    backup="${link}.legacy.$$"
    run_priv mv -f "$link" "$backup" || return 1
    if ! atomic_symlink "$target" "$link"; then
      run_priv mv -f "$backup" "$link"
      return 1
    fi
    run_priv rm -f "$backup"
    return 0
  fi
  run_priv install -d -m 755 "$(dirname "$link")" || return 1
  atomic_symlink "$target" "$link"
}

ensure_compat_links() {
  local current_dir
  current_dir="$(resolve_link "$CURRENT_LINK")"
  [[ -n "$current_dir" ]] || return 1
  replace_with_symlink "$current_dir/xray-manager.sh" "$INSTALL_PATH" || return 1
  if [[ "$CORE_PATH" != "$current_dir/xray-manager-core.sh" ]]; then
    replace_with_symlink "$current_dir/xray-manager-core.sh" "$CORE_PATH" || return 1
  fi
}

choose_release_dir() {
  local version="$1" dest live prev
  dest="$RELEASES_DIR/$version"
  live="$(resolve_link "$CURRENT_LINK")"
  prev="$(resolve_link "$PREVIOUS_LINK")"
  if [[ -n "$live" && "$dest" == "$live" ]] || [[ -n "$prev" && "$dest" == "$prev" ]]; then
    dest="$RELEASES_DIR/${version}.reinstall.$$"
  fi
  printf '%s' "$dest"
}

prune_old_releases() {
  local keep_current keep_previous entry
  keep_current="$(resolve_link "$CURRENT_LINK")"
  keep_previous="$(resolve_link "$PREVIOUS_LINK")"
  [[ -d "$RELEASES_DIR" ]] || return 0
  shopt -s nullglob
  for entry in "$RELEASES_DIR"/* "$RELEASES_DIR"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    [[ "$entry" == "$keep_current" || "$entry" == "$keep_previous" ]] && continue
    run_priv rm -rf "$entry"
  done
  shopt -u nullglob
}

migrate_legacy_layout() {
  local launcher_src="" core_src="" version dest
  manager_layout_paths

  if [[ -L "$CURRENT_LINK" ]] && verify_release_dir "$CURRENT_LINK"; then
    return 0
  fi

  if [[ -f "$INSTALL_PATH" && ! -L "$INSTALL_PATH" ]]; then
    launcher_src="$INSTALL_PATH"
  fi
  if [[ -f "$CORE_PATH" && ! -L "$CORE_PATH" ]]; then
    core_src="$CORE_PATH"
  fi

  if [[ -z "$launcher_src" && -z "$core_src" ]]; then
    return 0
  fi
  if [[ -z "$launcher_src" || -z "$core_src" ]]; then
    warn "旧安装不完整（缺少 Launcher 或 Core），跳过布局迁移。"
    return 0
  fi

  version="$(read_project_version "$launcher_src" || true)"
  version="${version:-0.0.0}"

  run_priv install -d -m 755 "$LIB_DIR" "$RELEASES_DIR" || return 1
  dest="$RELEASES_DIR/$version"
  if [[ -e "$dest" ]]; then
    dest="$RELEASES_DIR/${version}.migrated.$$"
  fi
  run_priv install -d -m 755 "$dest" || return 1
  install_release_file "$launcher_src" "$dest/xray-manager.sh" || return 1
  install_release_file "$core_src" "$dest/xray-manager-core.sh" || return 1
  if ! verify_release_dir "$dest"; then
    err "旧安装迁移后校验失败，保留原文件。"
    run_priv rm -rf "$dest"
    return 1
  fi
  atomic_symlink "$dest" "$CURRENT_LINK" || return 1
  ensure_compat_links || return 1
  info "已将固定路径安装迁移为发布目录：$version"
}

restore_current_link() {
  local live="$1"
  if [[ -n "$live" ]]; then
    atomic_symlink "$live" "$CURRENT_LINK" || true
    ensure_compat_links || true
  else
    run_priv rm -f "$CURRENT_LINK"
  fi
}

install_pair() {
  local launcher="$1" core="$2"
  local stage dest version live

  manager_layout_paths

  [[ -f "$launcher" && -f "$core" ]] || {
    err "安装源文件缺失。"
    return 1
  }

  version="$(read_project_version "$launcher")" || {
    err "无法从 Launcher 读取有效 VERSION。"
    return 1
  }

  migrate_legacy_layout || return 1

  live="$(resolve_link "$CURRENT_LINK")"
  run_priv install -d -m 755 "$LIB_DIR" "$RELEASES_DIR" || return 1

  stage="$RELEASES_DIR/.stage.$$"
  run_priv rm -rf "$stage"
  run_priv install -d -m 755 "$stage" || return 1

  if [[ "${XRAY_MANAGER_FAIL_STEP:-}" == "launcher" ]]; then
    run_priv rm -rf "$stage"
    err "Launcher 写入失败，当前版本未改变。"
    return 1
  fi
  if ! install_release_file "$launcher" "$stage/xray-manager.sh"; then
    run_priv rm -rf "$stage"
    err "Launcher 写入失败，当前版本未改变。"
    return 1
  fi

  if [[ "${XRAY_MANAGER_FAIL_STEP:-}" == "core" ]]; then
    run_priv rm -rf "$stage"
    err "Core 写入失败，当前版本未改变。"
    return 1
  fi
  if ! install_release_file "$core" "$stage/xray-manager-core.sh"; then
    run_priv rm -rf "$stage"
    err "Core 写入失败，当前版本未改变。"
    return 1
  fi

  if ! verify_release_dir "$stage"; then
    run_priv rm -rf "$stage"
    err "暂存发布校验失败，当前版本未改变。"
    return 1
  fi

  dest="$(choose_release_dir "$version")"
  if [[ -n "$live" && "$dest" == "$live" ]]; then
    run_priv rm -rf "$stage"
    err "拒绝覆盖正在使用的发布目录。"
    return 1
  fi

  run_priv rm -rf "$dest"
  if [[ "${XRAY_MANAGER_FAIL_STEP:-}" == "switch" ]]; then
    run_priv rm -rf "$stage"
    err "原子切换前失败，当前版本未改变。"
    return 1
  fi
  if ! run_priv mv "$stage" "$dest"; then
    run_priv rm -rf "$stage" "$dest"
    err "原子切换前失败，当前版本未改变。"
    return 1
  fi

  if ! atomic_symlink "$dest" "$CURRENT_LINK"; then
    run_priv rm -rf "$dest"
    restore_current_link "$live"
    err "原子切换 current 失败，当前版本未改变。"
    return 1
  fi

  if ! selfcheck_current_release; then
    err "新版本自检失败，正在恢复上一可用版本。"
    restore_current_link "$live"
    run_priv rm -rf "$dest"
    return 1
  fi

  if [[ -n "$live" && "$live" != "$dest" ]]; then
    atomic_symlink "$live" "$PREVIOUS_LINK" || warn "未能记录 previous 链接。"
  fi

  prune_old_releases
  if ! ensure_compat_links; then
    err "稳定入口更新失败，正在恢复上一可用版本。"
    restore_current_link "$live"
    return 1
  fi
}

rollback_manager() {
  local prev curr prev_ver
  manager_layout_paths
  migrate_legacy_layout || true

  prev="$(resolve_link "$PREVIOUS_LINK")"
  curr="$(resolve_link "$CURRENT_LINK")"
  if [[ -z "$prev" || ! -d "$prev" ]]; then
    err "没有可回滚的上一版本。"
    return 1
  fi
  if [[ "$prev" == "$curr" ]]; then
    err "previous 与 current 指向同一目录，拒绝回滚。"
    return 1
  fi
  if ! verify_release_dir "$prev"; then
    err "上一版本未通过校验，拒绝回滚。"
    return 1
  fi
  prev_ver="$(read_project_version "$prev/xray-manager.sh")" || return 1
  info "准备回滚到 $prev_ver"
  atomic_symlink "$prev" "$CURRENT_LINK" || return 1
  if ! selfcheck_current_release; then
    err "回滚后自检失败，正在恢复。"
    restore_current_link "$curr"
    return 1
  fi
  if [[ -n "$curr" && -d "$curr" ]]; then
    atomic_symlink "$curr" "$PREVIOUS_LINK" || warn "未能更新 previous 链接。"
  fi
  ensure_compat_links || return 1
  ok "已回滚到 $prev_ver"
}

self_update_github() {
  command -v curl >/dev/null 2>&1 || {
    err "缺少 curl，无法更新。"
    return 1
  }

  local token tmp latest
  token="$(get_token)"
  if [[ -n "$token" ]]; then
    info "使用可选的 GitHub Token（仅用于提高 API 速率限制）。"
  else
    info "未提供 GitHub Token，将匿名读取公开仓库。"
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  info "读取仓库版本..."
  curl_private "VERSION" "$tmp/VERSION" "$token"
  latest="$(tr -d '[:space:]' <"$tmp/VERSION")"

  echo "本机项目版本：$PROJECT_VERSION"
  echo "仓库项目版本：$latest"

  if approve_target_version "$latest"; then
    :
  else
    local version_rc=$?
    (( version_rc == 10 )) && return 0
    return "$version_rc"
  fi

  info "下载 Launcher、Core 与校验文件..."
  curl_private "SHA256SUMS" "$tmp/SHA256SUMS" "$token"
  curl_private "xray-manager.sh" "$tmp/xray-manager.sh" "$token"
  mkdir -p "$tmp/lib"
  curl_private "lib/xray-manager-core.sh" "$tmp/lib/xray-manager-core.sh" "$token"

  verify_payload "$tmp/SHA256SUMS" "$tmp" \
    "xray-manager.sh" "lib/xray-manager-core.sh" || return 1

  patch_core_for_launcher "$tmp/lib/xray-manager-core.sh" || return 1
  bash -n "$tmp/xray-manager.sh"
  bash -n "$tmp/lib/xray-manager-core.sh"

  install_pair "$tmp/xray-manager.sh" "$tmp/lib/xray-manager-core.sh"
  ok "Xray Manager 已更新到项目版本：$latest"
  info "重新运行 sudo xraym 即可。"

  rm -rf "$tmp"
  trap - RETURN
}

self_update() {
  cleanup_legacy_update_state
  self_update_github
}

print_version() {
  local current_dir previous_dir current_ver previous_ver
  manager_layout_paths
  echo "Xray Manager project: $PROJECT_VERSION"
  echo "Xray Manager core   : $CORE_VERSION"
  current_dir="$(resolve_link "$CURRENT_LINK")"
  previous_dir="$(resolve_link "$PREVIOUS_LINK")"
  if [[ -n "$current_dir" ]]; then
    current_ver="$(read_project_version "$current_dir/xray-manager.sh" || printf unknown)"
    echo "Installed current   : $current_ver"
  fi
  if [[ -n "$previous_dir" ]]; then
    previous_ver="$(read_project_version "$previous_dir/xray-manager.sh" || printf unknown)"
    echo "Installed previous  : $previous_ver"
  fi
}

run_core() {
  local self_dir
  manager_layout_paths
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$self_dir/xray-manager-core.sh" ]]; then
    CORE_PATH="$self_dir/xray-manager-core.sh"
  elif [[ -L "$CURRENT_LINK" && -f "$CURRENT_LINK/xray-manager-core.sh" ]]; then
    CORE_PATH="$CURRENT_LINK/xray-manager-core.sh"
  fi
  if [[ ! -f "$CORE_PATH" ]]; then
    err "未找到核心脚本：$CORE_PATH"
    warn "请重新运行 install.sh 或 offline-install.sh 安装入口。"
    exit 1
  fi
  export XRAY_MANAGER_CORE_INSTALL_PATH="$CORE_PATH"
  exec "$CORE_PATH" "$@"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

case "${2:-}" in
  "") ;;
  --allow-downgrade) ALLOW_DOWNGRADE=1 ;;
  *) err "未知参数：$2"; usage; exit 2 ;;
esac

case "${1:-}" in
  --self-update|update-manager)
    with_manager_lock "Manager 自更新" self_update
    ;;
  --rollback)
    with_manager_lock "Manager 回滚" rollback_manager
    ;;
  --version|-V)
    print_version
    ;;
  --help|-h)
    usage
    ;;
  "")
    run_core
    ;;
  *)
    run_core "$@"
    ;;
esac
