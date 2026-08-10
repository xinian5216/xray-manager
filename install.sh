#!/usr/bin/env bash
# Private bootstrap installer for xinian5216/xray-manager
set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY="xinian5216/xray-manager"
REF="${XRAY_MANAGER_REF:-main}"
API_BASE="https://api.github.com/repos/${REPOSITORY}/contents"
INSTALL_PATH="${XRAY_MANAGER_INSTALL_PATH:-/usr/local/sbin/xraym}"
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
  --run                 安装完成后立即 sudo 运行 xraym
  --ref <branch/tag>    指定 Git ref，默认 main
  --proxy <URL>         下载使用 HTTP/SOCKS5 代理
  --install-path <path> 安装路径，默认 /usr/local/sbin/xraym
  -h, --help            显示帮助

Authentication:
  优先读取 XRAY_MANAGER_GITHUB_TOKEN，其次读取 GH_TOKEN。
  两者都不存在时，会从 /dev/tty 安全提示输入。
  Token 不会由本脚本持久保存。
EOF
}

while (($#)); do
  case "$1" in
    --run)
      RUN_AFTER_INSTALL=1
      shift
      ;;
    --ref)
      [[ $# -ge 2 ]] || { err "--ref 缺少参数"; exit 2; }
      REF="$2"
      shift 2
      ;;
    --proxy)
      [[ $# -ge 2 ]] || { err "--proxy 缺少参数"; exit 2; }
      DOWNLOAD_PROXY="$2"
      shift 2
      ;;
    --install-path)
      [[ $# -ge 2 ]] || { err "--install-path 缺少参数"; exit 2; }
      INSTALL_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "未知参数：$1"
      usage
      exit 2
      ;;
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

install_payload() {
  local src="$1"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    install -m 755 "$src" "$INSTALL_PATH"
    return 0
  fi

  command -v sudo >/dev/null 2>&1 || {
    err "需要 root 写入 $INSTALL_PATH，但系统没有 sudo。请切换 root 后重试。"
    return 1
  }

  sudo install -m 755 "$src" "$INSTALL_PATH"
}

run_manager() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    exec "$INSTALL_PATH"
  fi
  exec sudo "$INSTALL_PATH"
}

TOKEN="$(get_token)" || {
  err "没有 GitHub Token，无法读取 Private Repository。"
  warn "建议使用 Fine-grained PAT，仅授权 xray-manager 仓库的 Contents: Read。"
  exit 1
}

TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
  unset TOKEN GH_TOKEN XRAY_MANAGER_GITHUB_TOKEN 2>/dev/null || true
}
trap cleanup EXIT INT TERM

info "从 Private Repository 获取 VERSION..."
curl_private "VERSION" "$TMP/VERSION" "$TOKEN"
VERSION="$(tr -d '[:space:]' <"$TMP/VERSION")"
[[ -n "$VERSION" ]] || { err "VERSION 为空。"; exit 1; }

info "下载 xray-manager.sh 与 SHA256SUMS..."
curl_private "SHA256SUMS" "$TMP/SHA256SUMS" "$TOKEN"
curl_private "xray-manager.sh" "$TMP/xray-manager.sh" "$TOKEN"

EXPECTED="$(awk '$2=="xray-manager.sh" {print $1; exit}' "$TMP/SHA256SUMS")"
ACTUAL="$(sha256_file "$TMP/xray-manager.sh" 2>/dev/null || true)"

[[ -n "$EXPECTED" && -n "$ACTUAL" ]] || {
  err "无法取得 SHA256 校验信息。"
  exit 1
}

if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  err "SHA256 校验失败。"
  echo "Expected: $EXPECTED" >&2
  echo "Actual  : $ACTUAL" >&2
  exit 1
fi

bash -n "$TMP/xray-manager.sh" || {
  err "Bash 语法检查失败。"
  exit 1
}

install_payload "$TMP/xray-manager.sh"
ok "Xray Manager $VERSION 已安装到：$INSTALL_PATH"

echo
echo "以后运行："
echo "  sudo xraym"
echo
echo "脚本不会保存你的 GitHub PAT。"

if (( RUN_AFTER_INSTALL )); then
  trap - EXIT INT TERM
  rm -rf "$TMP"
  unset TOKEN GH_TOKEN XRAY_MANAGER_GITHUB_TOKEN 2>/dev/null || true
  run_manager
fi
