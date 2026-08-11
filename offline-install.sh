#!/usr/bin/env bash
# Fully offline bootstrap for Xray Manager + Xray-core + GeoData.
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$ROOT_DIR"
XRAY_ZIP=""
GEOIP_FILE=""
GEOSITE_FILE=""
RUN_AFTER_INSTALL=0
INSTALL_PATH="${XRAY_MANAGER_INSTALL_PATH:-/usr/local/sbin/xraym}"
CORE_PATH="${XRAY_MANAGER_CORE_PATH:-/usr/local/lib/xray-manager/xray-manager-core.sh}"

err() { printf '[x] %s\n' "$*" >&2; }
ok() { printf '[✓] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash offline-install.sh --bundle-dir /path/to/bundle [--run]
  sudo bash offline-install.sh --xray-zip FILE --geoip FILE --geosite FILE [--run]

The bundle directory must contain exactly one Xray-linux-*.zip, geoip.dat and
geosite.dat. This installer never downloads packages or contacts the network.
It requires one local ZIP reader: unzip, bsdtar, or python3.
EOF
}

while (($#)); do
  case "$1" in
    --bundle-dir) BUNDLE_DIR="${2:?--bundle-dir requires a path}"; shift 2 ;;
    --xray-zip) XRAY_ZIP="${2:?--xray-zip requires a file}"; shift 2 ;;
    --geoip) GEOIP_FILE="${2:?--geoip requires a file}"; shift 2 ;;
    --geosite) GEOSITE_FILE="${2:?--geosite requires a file}"; shift 2 ;;
    --run) RUN_AFTER_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || {
  err "Please run as root: sudo bash offline-install.sh ..."
  exit 1
}

for file in xray-manager.sh lib/xray-manager-core.sh offline-install.sh SHA256SUMS; do
  [[ -f "$ROOT_DIR/$file" ]] || { err "Repository file is missing: $file"; exit 1; }
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 1
  fi
}

verify_repo_file() {
  local file="$1" expected actual
  expected="$(awk -v f="$file" '$2==f {print $1; exit}' "$ROOT_DIR/SHA256SUMS")"
  actual="$(sha256_file "$ROOT_DIR/$file" 2>/dev/null || true)"
  [[ -n "$expected" && "$actual" == "$expected" ]] || {
    err "Repository SHA256 verification failed: $file"
    return 1
  }
}

verify_repo_file xray-manager.sh
verify_repo_file lib/xray-manager-core.sh
verify_repo_file offline-install.sh

if [[ -z "$XRAY_ZIP" ]]; then
  shopt -s nullglob
  candidates=("$BUNDLE_DIR"/Xray-linux-*.zip)
  shopt -u nullglob
  (( ${#candidates[@]} == 1 )) || {
    err "Bundle directory must contain exactly one Xray-linux-*.zip: $BUNDLE_DIR"
    exit 1
  }
  XRAY_ZIP="${candidates[0]}"
fi
GEOIP_FILE="${GEOIP_FILE:-$BUNDLE_DIR/geoip.dat}"
GEOSITE_FILE="${GEOSITE_FILE:-$BUNDLE_DIR/geosite.dat}"

bash -n "$ROOT_DIR/xray-manager.sh"
bash -n "$ROOT_DIR/lib/xray-manager-core.sh"

# shellcheck source=lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"
offline_import_xray "$XRAY_ZIP" "$GEOIP_FILE" "$GEOSITE_FILE"

install -d -m 755 "$(dirname "$CORE_PATH")"
install -m 755 "$ROOT_DIR/xray-manager.sh" "$INSTALL_PATH"
install -m 755 "$ROOT_DIR/lib/xray-manager-core.sh" "$CORE_PATH"
ok "Xray Manager has been installed without network access."
echo "Launcher: $INSTALL_PATH"
echo "Core    : $CORE_PATH"

if (( RUN_AFTER_INSTALL )); then
  exec "$INSTALL_PATH"
fi
