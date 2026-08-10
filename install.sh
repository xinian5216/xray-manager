#!/usr/bin/env bash
# Private bootstrap installer for xinian5216/xray-manager
set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY="xinian5216/xray-manager"
REF="${XRAY_MANAGER_REF:-main}"
API_BASE="https://api.github.com/repos/${REPOSITORY}/contents"
INSTALL_PATH="${XRAY_MANAGER_INSTALL_PATH:-/usr/local/sbin/xraym}"
CORE_PATH="${XRAY_MANAGER_CORE_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}"
DOWNLOAD_PROXY="${XRAY_DOWNLOAD_PROXY:-}"
RUN_AFTER_INSTALL=0

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
  优先读取 XRAY_MANAGER_GITHUB_TOKEN，其次读取 GH_TOKEN。
  两者都不存在时，会从 /dev/tty 安全提示输入。
  Token 不会被本脚本持久保存。
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

curl_private() {
  local path="$1" out="$2" token="$3"
  local args=(
    -fsSL --retry 4 --connect-timeout 12 --max-time 180
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
  else
    command -v sudo >/dev/null 2>&1 || {
      err "需要 root 写入 /usr/local，但系统没有 sudo。"
      return 1
    }
    sudo install -d -m 755 "$(dirname "$CORE_PATH")"
    sudo install -m 755 "$launcher" "$INSTALL_PATH"
    sudo install -m 755 "$core" "$CORE_PATH"
  fi
}

TOKEN="$(get_token)" || {
  err "没有 GitHub Token，无法读取 Private Repository。"
  warn "Fine-grained PAT 只需给 xray-manager 仓库 Contents: Read。"
  exit 1
}

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

install_pair "$TMP/xray-manager.sh" "$TMP/lib/xray-manager-core.sh"
ok "Xray Manager 项目版本 $VERSION 安装完成。"
echo "Launcher: $INSTALL_PATH"
echo "Core    : $CORE_PATH"
echo
echo "运行：sudo xraym"
echo "更新：sudo xraym --self-update"
echo "Token 默认不会保存。"

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
