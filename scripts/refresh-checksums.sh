#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
sha256sum xray-manager.sh lib/xray-manager-core.sh install.sh offline-install.sh > SHA256SUMS
echo "Updated SHA256SUMS:"
cat SHA256SUMS
