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

INSTALL_TOKEN="${XRAY_MANAGER_INSTALL_TOKEN:-}"
if [[ -z "$INSTALL_TOKEN" ]]; then
  read -rsp "安装密钥: " INSTALL_TOKEN </dev/tty
  echo
fi

if [[ -z "$INSTALL_TOKEN" ]]; then
  echo "安装密钥不能为空"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
CURL_CONFIG="$WORK_DIR/curl.conf"

cleanup() {
  rm -rf "$WORK_DIR"
  unset INSTALL_TOKEN XRAY_MANAGER_INSTALL_TOKEN
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
unset INSTALL_TOKEN XRAY_MANAGER_INSTALL_TOKEN

PACKAGE="latest-${ARCH}.tar.gz"
CHECKSUM="${PACKAGE%.tar.gz}.sha256"

echo "正在从 Cloudflare 下载离线安装包……"

curl --config "$CURL_CONFIG" \
  "$BASE_URL/releases/$PACKAGE" \
  --output "$WORK_DIR/$PACKAGE"

curl --config "$CURL_CONFIG" \
  "$BASE_URL/releases/$CHECKSUM" \
  --output "$WORK_DIR/$CHECKSUM"

curl --config "$CURL_CONFIG" \
  "$BASE_URL/releases/manifest.json" \
  --output "$WORK_DIR/manifest.json"

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

if [[ ! -f "$WORK_DIR/manifest.json" ]]; then
  echo "未能下载发布清单，拒绝安装"
  exit 1
fi
if ! grep -Eq "\"file\"[[:space:]]*:[[:space:]]*\"${PACKAGE}\"" "$WORK_DIR/manifest.json"; then
  echo "发布清单缺少当前架构安装包，拒绝安装"
  exit 1
fi
if ! grep -Eq "\"sha256\"[[:space:]]*:[[:space:]]*\"${ACTUAL}\"" "$WORK_DIR/manifest.json"; then
  echo "发布清单与安装包摘要不一致，拒绝安装"
  exit 1
fi

mkdir -p "$WORK_DIR/extracted"
tar -xzf "$WORK_DIR/$PACKAGE" -C "$WORK_DIR/extracted"

INSTALLER="$WORK_DIR/extracted/xray-manager/offline-install.sh"
CORE="$WORK_DIR/extracted/xray-manager/lib/xray-manager-core.sh"
BUNDLE_DIR="$WORK_DIR/extracted/payload"
MANIFEST="$WORK_DIR/extracted/xray-manager/release-manifest.json"
MANAGER_VERSION_FILE="$WORK_DIR/extracted/xray-manager/VERSION"

if [[ ! -f "$INSTALLER" || ! -f "$CORE" ]]; then
  echo "离线安装包中缺少 offline-install.sh 或 Core"
  exit 1
fi

if [[ ! -f "$MANIFEST" || ! -f "$MANAGER_VERSION_FILE" ]]; then
  echo "安装包缺少发布清单或 VERSION，拒绝安装"
  exit 1
fi

MANAGER_VERSION="$(tr -d '[:space:]' < "$MANAGER_VERSION_FILE")"
if [[ ! "$MANAGER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "安装包 VERSION 无效"
  exit 1
fi
if ! grep -Eq "\"manager_version\"[[:space:]]*:[[:space:]]*\"${MANAGER_VERSION}\"" "$MANIFEST"; then
  echo "发布清单与 VERSION 不一致，拒绝安装"
  exit 1
fi

echo "安装 Xray Manager 运行依赖（含 jq、OpenSSL、iproute2）……"
bash "$CORE" --install-dependencies

echo "校验通过，开始离线安装……"

XRAY_MANAGER_UPDATE_SOURCE=cloudflare \
XRAY_MANAGER_CLOUDFLARE_URL="$BASE_URL" \
bash "$INSTALLER" \
  --bundle-dir "$BUNDLE_DIR" \
  --run
