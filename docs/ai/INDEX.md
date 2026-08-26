# AI index (generated)

Do not hand-edit. Regenerate with `bash scripts/maintainer-map.sh --write-index`.
First contact: read [AGENTS.md](../../AGENTS.md), then this file or `--ai`. Never open `lib/xray-manager-core.sh` in full.

## File budget

| file | bytes | lines | first contact |
| --- | ---: | ---: | --- |
| AGENTS.md | 3824 | 54 | always |
| docs/ai/INDEX.md | generated | generated | always |
| docs/ai/core-symbols.tsv | generated | generated | grep function names |
| lib/xray-manager-core.sh | 232048 | 6825 | **never whole** — slices only |
| xray-manager.sh | 26473 | 875 | launcher/self-update only |
| README.md | 29053 | 560 | user-doc edits only |
| CHANGELOG.md | 17601 | 262 | release notes only |
| tests/smoke-configs.sh | 14943 | 421 | config-generation tests |

Cap: about 500 lines of Core per turn. Prefer `bash scripts/maintainer-map.sh --ai "<task>"`.

## Areas

| area | core slice | lines | tests | when |
| --- | --- | ---: | --- | --- |
| `launcher` | xray-manager.sh:38-875 | 838 | tests/bootstrap-install.sh,tests/cloudflare-update.sh,tests/manager-menu-update.sh,tests/version-lock.sh,tests/atomic-release.sh | launcher / 启动器 / 自更新 / self-update / 菜单更新 / 版本 / 降级 / downgrade |
| `install-migrate` | lib/xray-manager-core.sh:642-1574 | 933 | tests/bootstrap-install.sh,tests/offline-install.sh,tests/config-migration.sh,tests/cloudflare-core-download.sh,tests/smoke-configs.sh | 安装 / 依赖 / dependency / jq / 修复 / 迁移 / migration / systemd |
| `network-ipv6` | lib/xray-manager-core.sh:191-641 | 451 | tests/cloudflare-core-download.sh,tests/offline-install.sh | 网络 / ipv4 / ipv6 / only-v6 / NAT64 / DNS64 / 下载代理 / proxy |
| `inbound-transport` | lib/xray-manager-core.sh:1835-5028 | 3194 | tests/inbound-management.sh,tests/wireguard-management.sh,tests/smoke-configs.sh,tests/manager-menu-update.sh | 入站 / inbound / 详情 / detail / 编号 / index / 诊断 / diagnose |
| `outbound` | lib/xray-manager-core.sh:5029-5646 | 618 | tests/wireguard-management.sh,tests/smoke-configs.sh | 出站 / outbound / freedom / socks / http / shadowsocks / wireguard / warp |
| `routing` | lib/xray-manager-core.sh:5647-6108 | 462 | tests/smoke-configs.sh | 路由 / routing / 分流 / rule / geosite / geoip / CIDR / 默认出口 |
| `port-forward` | lib/xray-manager-core.sh:6683-6743 | 61 | tests/smoke-configs.sh | 端口转发 / forwarding / forward / TCP / UDP / 监听 / 目标端口 |
| `config-safety` | lib/xray-manager-core.sh:1575-1785,lib/xray-manager-core.sh:6336-6560 | 436 | tests/smoke-configs.sh,tests/config-migration.sh,tests/backup-restore.sh | 配置 / 写入 / 回滚 / backup / restore / test / config / conf.d |
| `xray-geodata` | lib/xray-manager-core.sh:6109-6174 | 66 | tests/xray-release-delay.sh,tests/geodata-release-delay.sh,tests/xray-asset-integrity.sh,tests/smoke-configs.sh | Xray-core / core / geodata / geoip / geosite / 更新 / 延迟 / release |
| `worker-r2` | worker/src/index.ts (whole) | 137 | worker/test/index.spec.ts,worker/package.json,tests/cloudflare-update.sh | Cloudflare / Worker / R2 / 401 / 403 / 404 / Bearer / token |
| `firewall-bbr` | lib/xray-manager-core.sh:6175-6335 | 161 | tests/inbound-management.sh,tests/smoke-configs.sh | UFW / 防火墙 / SSH / BBR / sysctl / 端口放行 / 规则清理 |
| `release` | — | 0 | scripts/maintainer-map.sh,.github/workflows/shellcheck.yml,tests/xray-asset-integrity.sh | 发版 / version / checksum / SHA256 / changelog / release / bundle / 打包 |
| `ci-tests` | — | 0 | tests/inbound-management.sh,tests/maintainer-map.sh,tests/bootstrap-install.sh,tests/offline-install.sh,tests/cloudflare-update.sh,tests/cloudflare-core-download.sh,tests/config-migration.sh,tests/backup-restore.sh,tests/version-lock.sh,tests/manager-menu-update.sh,tests/atomic-release.sh,tests/xray-release-delay.sh,tests/geodata-release-delay.sh,tests/xray-asset-integrity.sh | CI / Actions / ShellCheck / test / smoke / 测试失败 / workflow |

## How to slice

```bash
bash scripts/maintainer-map.sh --ai "SS2022 用户"
grep -i shadowsocks docs/ai/core-symbols.tsv
sed -n '2565,2628p' lib/xray-manager-core.sh
```

If the cluster is larger than 500 lines (`inbound-transport` is ~3000), do not read the cluster. Grep the TSV or pass a protocol/function keyword to `--ai`.

