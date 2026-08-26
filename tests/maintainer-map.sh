#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP="$ROOT_DIR/scripts/maintainer-map.sh"

bash "$MAP" --check >/dev/null

routing="$(bash "$MAP" "路由规则顺序")"
grep -Fq 'lib/xray-manager-core.sh' <<<"$routing"
grep -Fq 'tests/smoke-configs.sh' <<<"$routing"

inbound="$(bash "$MAP" "SS2022 详情")"
grep -Fq '[inbound-transport]' <<<"$inbound"
grep -Fq 'tests/inbound-management.sh' <<<"$inbound"

wireguard="$(bash "$MAP" "WireGuard 公钥")"
grep -Fq 'tests/wireguard-management.sh' <<<"$wireguard"
grep -Fq 'lib/xray-manager-core.sh' <<<"$wireguard"

worker="$(bash "$MAP" "Worker 401")"
grep -Fq 'worker/src/index.ts' <<<"$worker"
grep -Fq 'worker/test/index.spec.ts' <<<"$worker"

ipv6="$(bash "$MAP" "IPv6 下载")"
grep -Fq '[network-ipv6]' <<<"$ipv6"
grep -Fq 'tests/cloudflare-core-download.sh' <<<"$ipv6"

integrity="$(bash "$MAP" "digest")"
grep -Fq '[xray-geodata]' <<<"$integrity"
grep -Fq 'scripts/verify-xray-asset.sh' <<<"$integrity"
grep -Fq 'tests/xray-asset-integrity.sh' <<<"$integrity"

if bash "$MAP" "definitely-unknown-area" >/dev/null 2>&1; then
  echo "unknown query unexpectedly succeeded" >&2
  exit 1
fi

echo "Maintainer navigation tests passed."
