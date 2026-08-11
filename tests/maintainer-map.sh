#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP="$ROOT_DIR/scripts/maintainer-map.sh"

bash "$MAP" --check >/dev/null

routing="$(bash "$MAP" "路由规则顺序")"
grep -Fq 'lib/xray-manager-core.sh' <<<"$routing"
grep -Fq 'tests/smoke-configs.sh' <<<"$routing"

worker="$(bash "$MAP" "Worker 401")"
grep -Fq 'worker/src/index.ts' <<<"$worker"
grep -Fq 'worker/test/index.spec.ts' <<<"$worker"

ipv6="$(bash "$MAP" "IPv6 下载")"
grep -Fq '[network-ipv6]' <<<"$ipv6"
grep -Fq 'tests/cloudflare-core-download.sh' <<<"$ipv6"

if bash "$MAP" "definitely-unknown-area" >/dev/null 2>&1; then
  echo "unknown query unexpectedly succeeded" >&2
  exit 1
fi

echo "Maintainer navigation tests passed."
