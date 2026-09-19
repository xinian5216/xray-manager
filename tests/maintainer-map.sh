#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP="$ROOT_DIR/scripts/maintainer-map.sh"

must_contain() {
  local haystack="$1" needle="$2"
  if ! printf '%s\n' "$haystack" | grep -Fq "$needle"; then
    printf 'missing %q\n' "$needle" >&2
    return 1
  fi
}

bash "$MAP" --write-index >/dev/null
bash "$MAP" --check >/dev/null

routing="$(bash "$MAP" "路由规则顺序")"
must_contain "$routing" 'lib/xray-manager-core.sh'
must_contain "$routing" 'tests/smoke-configs.sh'

inbound="$(bash "$MAP" "SS2022 详情")"
must_contain "$inbound" '[inbound-transport]'
must_contain "$inbound" 'tests/inbound-management.sh'

wireguard="$(bash "$MAP" "WireGuard 公钥")"
must_contain "$wireguard" 'tests/wireguard-management.sh'
must_contain "$wireguard" 'lib/xray-manager-core.sh'

ipv6="$(bash "$MAP" "IPv6 下载")"
must_contain "$ipv6" '[network-ipv6]'
must_contain "$ipv6" 'tests/offline-install.sh'

integrity="$(bash "$MAP" "digest")"
must_contain "$integrity" '[xray-geodata]'
must_contain "$integrity" 'scripts/verify-xray-asset.sh'
must_contain "$integrity" 'tests/xray-asset-integrity.sh'

if bash "$MAP" "definitely-unknown-area" >/dev/null 2>&1; then
  echo "unknown query unexpectedly succeeded" >&2
  exit 1
fi

ai_routing="$(bash "$MAP" --ai "路由规则顺序")"
must_contain "$ai_routing" 'area: routing'
must_contain "$ai_routing" '5616,6077p'
must_contain "$ai_routing" 'tests/smoke-configs.sh'
must_contain "$ai_routing" 'skip: README.md'

ai_ss="$(bash "$MAP" --ai "SS2022")"
must_contain "$ai_ss" 'area: inbound-transport'
must_contain "$ai_ss" 'add_shadowsocks'
must_contain "$ai_ss" 'validate_shadowsocks_2022_secret'
if printf '%s\n' "$ai_ss" | grep -q '1804,4997p'; then
  echo "SS2022 --ai dumped the whole inbound cluster" >&2
  exit 1
fi

ai_backup="$(bash "$MAP" --ai "备份恢复")"
must_contain "$ai_backup" 'area: config-safety'
must_contain "$ai_backup" 'backup_now'
must_contain "$ai_backup" 'tests/backup-restore.sh'

if bash "$MAP" --ai "Cloudflare Worker R2" >/dev/null 2>&1; then
  echo "retired worker-r2 area unexpectedly matched" >&2
  exit 1
fi

if bash "$MAP" --ai "definitely-unknown-area" >/dev/null 2>&1; then
  echo "unknown --ai query unexpectedly succeeded" >&2
  exit 1
fi

grep -Eq $'\tsafe_write_config_file\t' "$ROOT_DIR/docs/ai/core-symbols.tsv"
grep -Fq '`routing`' "$ROOT_DIR/docs/ai/INDEX.md"
grep -Fq 'never whole' "$ROOT_DIR/docs/ai/INDEX.md"

echo "Maintainer navigation tests passed."
