#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="${XRAY_MANAGER_CLOUDFLARE_URL:-https://xray-manager-download.xinian5216.workers.dev}"
BASE_URL="${BASE_URL%/}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo bash $0"
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64)
    ARCH="amd64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ;;
  *)
    echo "不支持的 CPU 架构：$(uname -m)"
    exit 1
    ;;
esac

for command_name in curl tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少必要命令：$command_name"
    exit 1
  fi
done

read -rsp "安装密钥: " INSTALL_TOKEN </dev/tty
echo

if [[ -z "$INSTALL_TOKEN" ]]; then
  echo "安装密钥不能为空"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
CURL_CONFIG="$WORK_DIR/curl.conf"

cleanup() {
  rm -rf "$WORK_DIR"
  unset INSTALL_TOKEN
}
trap cleanup EXIT INT TERM

chmod 700 "$WORK_DIR"

cat > "$CURL_CONFIG" <<EOF
header = "Authorization: Bearer ${INSTALL_TOKEN}"
fail
silent
show-error
location
connect-timeout = 15
retry = 3
EOF

chmod 600 "$CURL_CONFIG"
unset INSTALL_TOKEN

PACKAGE="latest-${ARCH}.tar.gz"
CHECKSUM="${PACKAGE%.tar.gz}.sha256"

echo "正在从 Cloudflare 下载离线安装包……"

curl --config "$CURL_CONFIG" \
  "$BASE_URL/releases/$PACKAGE" \
  --output "$WORK_DIR/$PACKAGE"

curl --config "$CURL_CONFIG" \
  "$BASE_URL/releases/$CHECKSUM" \
  --output "$WORK_DIR/$CHECKSUM"

EXPECTED="$(tr -d '[:space:]' < "$WORK_DIR/$CHECKSUM")"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$WORK_DIR/$PACKAGE" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
  ACTUAL="$(openssl dgst -sha256 "$WORK_DIR/$PACKAGE" | awk '{print $NF}')"
else
  echo "无法校验安装包：缺少 sha256sum 或 openssl"
  exit 1
fi

if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "安装包 SHA256 校验失败"
  exit 1
fi

mkdir -p "$WORK_DIR/extracted"
tar -xzf "$WORK_DIR/$PACKAGE" -C "$WORK_DIR/extracted"

INSTALLER="$WORK_DIR/extracted/xray-manager/offline-install.sh"
BUNDLE_DIR="$WORK_DIR/extracted/payload"

if [[ ! -f "$INSTALLER" ]]; then
  echo "离线安装包中缺少 offline-install.sh"
  exit 1
fi

echo "校验通过，开始离线安装……"

XRAY_MANAGER_UPDATE_SOURCE=cloudflare \
XRAY_MANAGER_CLOUDFLARE_URL="$BASE_URL" \
bash "$INSTALLER" \
  --bundle-dir "$BUNDLE_DIR" \
  --run
