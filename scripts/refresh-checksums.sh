#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# Emit the Git-normalized two-space format on every platform: MSYS sha256sum
# uses binary mode ("hash *file"), which breaks awk '$2==f' consumers.
sha256sum \
  xray-manager.sh \
  lib/xray-manager-core.sh \
  install.sh \
  offline-install.sh \
  | sed 's/^\([0-9a-f]*\) \*/\1  /' \
  > SHA256SUMS
echo "Updated SHA256SUMS:"
cat SHA256SUMS
