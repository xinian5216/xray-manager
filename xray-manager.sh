#!/usr/bin/env bash
# Xray Manager private launcher / updater
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_VERSION="1.4.2"
CORE_VERSION="1.4.2"
REPOSITORY="xinian5216/xray-manager"
REF="${XRAY_MANAGER_REF:-main}"
API_BASE="https://api.github.com/repos/${REPOSITORY}/contents"
INSTALL_PATH="${XRAY_MANAGER_INSTALL_PATH:-/usr/local/sbin/xraym}"
CORE_PATH="${XRAY_MANAGER_CORE_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}"
DOWNLOAD_PROXY="${XRAY_DOWNLOAD_PROXY:-}"
CLOUDFLARE_BASE_DEFAULT="https://xray-manager-download.xinian5216.workers.dev"
CLOUDFLARE_BASE="${XRAY_MANAGER_CLOUDFLARE_URL:-}"
UPDATE_SOURCE="${XRAY_MANAGER_UPDATE_SOURCE:-}"
UPDATE_SOURCE_FILE="${XRAY_MANAGER_UPDATE_SOURCE_FILE:-/etc/xray-manager/manager_update_source}"
CLOUDFLARE_URL_FILE="${XRAY_MANAGER_CLOUDFLARE_URL_FILE:-/etc/xray-manager/cloudflare_url}"

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
  xraym --self-update       按安装来源更新 Launcher + Core
  xraym --self-update-cloudflare  强制从 Cloudflare 私有分发更新
  xraym --self-update-github      强制从私有 GitHub 仓库更新
  xraym --version           查看项目与核心版本
  xraym --help              查看帮助

Environment:
  XRAY_MANAGER_GITHUB_TOKEN 私有仓库 Fine-grained PAT
  GH_TOKEN                  兼容 GitHub Token 环境变量
  XRAY_MANAGER_INSTALL_TOKEN Cloudflare Worker 安装密钥
  XRAY_MANAGER_UPDATE_SOURCE cloudflare 或 github
  XRAY_MANAGER_CLOUDFLARE_URL Cloudflare Worker 基础 URL
  XRAY_DOWNLOAD_PROXY       HTTP/SOCKS5 下载代理
  XRAY_MANAGER_REF          Git 分支/标签，默认 main
EOF
}

load_update_channel() {
  if [[ -z "$UPDATE_SOURCE" && -r "$UPDATE_SOURCE_FILE" ]]; then
    UPDATE_SOURCE="$(tr -d '[:space:]' <"$UPDATE_SOURCE_FILE")"
  fi
  if [[ -z "$CLOUDFLARE_BASE" && -r "$CLOUDFLARE_URL_FILE" ]]; then
    CLOUDFLARE_BASE="$(tr -d '[:space:]' <"$CLOUDFLARE_URL_FILE")"
  fi
  CLOUDFLARE_BASE="${CLOUDFLARE_BASE:-$CLOUDFLARE_BASE_DEFAULT}"
  UPDATE_SOURCE="${UPDATE_SOURCE:-github}"
}

get_token() {
  local token="${XRAY_MANAGER_GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -z "$token" && -r /dev/tty ]]; then
    printf "GitHub Fine-grained PAT（xray-manager / Contents: Read）: " >/dev/tty
    IFS= read -r -s token </dev/tty || true
    printf "\n" >/dev/tty
  fi
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

get_install_token() {
  local token="${XRAY_MANAGER_INSTALL_TOKEN:-}"
  if [[ -z "$token" && -r /dev/tty ]]; then
    printf "Cloudflare 安装密钥: " >/dev/tty
    IFS= read -r -s token </dev/tty || true
    printf "\n" >/dev/tty
  fi
  [[ -n "$token" ]] || return 1
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
    -H "Authorization: Bearer $token"
    -H "X-GitHub-Api-Version: 2022-11-28"
    "${API_BASE}/${path}?ref=${REF}"
    -o "$out"
  )

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

install_pair() {
  local launcher="$1" core="$2"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    install -d -m 755 "$(dirname "$CORE_PATH")"
    install -m 755 "$launcher" "$INSTALL_PATH"
    install -m 755 "$core" "$CORE_PATH"
    return 0
  fi

  command -v sudo >/dev/null 2>&1 || {
    err "需要 root 权限写入 /usr/local，但系统没有 sudo。"
    return 1
  }

  sudo install -d -m 755 "$(dirname "$CORE_PATH")"
  sudo install -m 755 "$launcher" "$INSTALL_PATH"
  sudo install -m 755 "$core" "$CORE_PATH"
}

self_update_github() {
  command -v curl >/dev/null 2>&1 || {
    err "缺少 curl，无法更新。"
    return 1
  }

  local token tmp latest
  token="$(get_token)" || {
    err "没有 GitHub Token。"
    warn "Fine-grained PAT 只需要该仓库 Contents: Read。"
    return 1
  }

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  info "读取 Private Repository 版本..."
  curl_private "VERSION" "$tmp/VERSION" "$token"
  latest="$(tr -d '[:space:]' <"$tmp/VERSION")"

  echo "本机项目版本：$PROJECT_VERSION"
  echo "仓库项目版本：$latest"

  if [[ "$latest" == "$PROJECT_VERSION" ]]; then
    ok "当前已是仓库版本。"
    printf "仍强制重新安装？ [y/N]: "
    local ans
    read -r ans || true
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || {
      rm -rf "$tmp"
      trap - RETURN
      return 0
    }
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

self_update_cloudflare() {
  command -v curl >/dev/null 2>&1 || {
    err "缺少 curl，无法更新。"
    return 1
  }
  command -v tar >/dev/null 2>&1 || {
    err "缺少 tar，无法解压更新包。"
    return 1
  }

  load_update_channel

  local token tmp config arch package checksum expected actual manager latest ans
  token="$(get_install_token)" || {
    err "没有 Cloudflare 安装密钥。"
    return 1
  }

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) err "Cloudflare 更新暂不支持当前架构：$(uname -m)"; return 1 ;;
  esac

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  chmod 700 "$tmp"
  config="$tmp/curl.conf"
  package="latest-${arch}.tar.gz"
  checksum="latest-${arch}.sha256"

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

  info "从 Cloudflare 私有分发下载更新包..."
  curl --config "$config" \
    "$CLOUDFLARE_BASE/releases/$package" \
    -o "$tmp/$package"
  curl --config "$config" \
    "$CLOUDFLARE_BASE/releases/$checksum" \
    -o "$tmp/$checksum"

  expected="$(tr -d '[:space:]' <"$tmp/$checksum")"
  actual="$(sha256_file "$tmp/$package" 2>/dev/null || true)"
  [[ -n "$expected" && "$expected" == "$actual" ]] || {
    err "Cloudflare 更新包 SHA256 校验失败。"
    return 1
  }

  mkdir -p "$tmp/extracted"
  tar -xzf "$tmp/$package" -C "$tmp/extracted"
  manager="$tmp/extracted/xray-manager"

  for file in VERSION SHA256SUMS xray-manager.sh lib/xray-manager-core.sh; do
    [[ -f "$manager/$file" ]] || {
      err "更新包缺少文件：$file"
      return 1
    }
  done

  latest="$(tr -d '[:space:]' <"$manager/VERSION")"
  echo "本机项目版本：$PROJECT_VERSION"
  echo "分发项目版本：$latest"

  if [[ "$latest" == "$PROJECT_VERSION" ]]; then
    ok "当前已是分发版本。"
    printf "仍强制重新安装？ [y/N]: "
    read -r ans || true
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || {
      rm -rf "$tmp"
      trap - RETURN
      return 0
    }
  fi

  verify_payload "$manager/SHA256SUMS" "$manager" \
    "xray-manager.sh" "lib/xray-manager-core.sh" || return 1
  patch_core_for_launcher "$manager/lib/xray-manager-core.sh" || return 1
  bash -n "$manager/xray-manager.sh"
  bash -n "$manager/lib/xray-manager-core.sh"
  install_pair "$manager/xray-manager.sh" "$manager/lib/xray-manager-core.sh"

  ok "Xray Manager 已通过 Cloudflare 更新到：$latest"
  info "重新运行 sudo xraym 即可。"

  rm -rf "$tmp"
  trap - RETURN
}

self_update() {
  load_update_channel
  case "$UPDATE_SOURCE" in
    cloudflare) self_update_cloudflare ;;
    github) self_update_github ;;
    *)
      err "未知更新来源：$UPDATE_SOURCE"
      warn "可设置 XRAY_MANAGER_UPDATE_SOURCE=cloudflare 或 github。"
      return 1
      ;;
  esac
}

run_core() {
  if [[ ! -f "$CORE_PATH" ]]; then
    err "未找到核心脚本：$CORE_PATH"
    warn "请重新运行 Cloudflare 或私有 GitHub 安装入口。"
    exit 1
  fi
  export XRAY_MANAGER_CORE_INSTALL_PATH="$CORE_PATH"
  exec "$CORE_PATH" "$@"
}

case "${1:-}" in
  --self-update|update-manager)
    self_update
    ;;
  --self-update-cloudflare)
    self_update_cloudflare
    ;;
  --self-update-github)
    self_update_github
    ;;
  --version|-V)
    echo "Xray Manager project: $PROJECT_VERSION"
    echo "Xray Manager core   : $CORE_VERSION"
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
