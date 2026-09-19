# AI index (generated)

Do not hand-edit. Regenerate with `bash scripts/maintainer-map.sh --write-index`.
First contact: read [AGENTS.md](../../AGENTS.md), then this file or `--ai`. Never open `lib/xray-manager-core.sh` in full.

## File budget

| file | bytes | lines | first contact |
| --- | ---: | ---: | --- |
| AGENTS.md | 3629 | 52 | always |
| docs/ai/INDEX.md | generated | generated | always |
| docs/ai/core-symbols.tsv | generated | generated | grep function names |
| lib/xray-manager-core.sh | 258444 | 7606 | **never whole** — slices only |
| xray-manager.sh | 21174 | 710 | launcher/self-update only |
| README.md | 26458 | 505 | user-doc edits only |
| CHANGELOG.md | 20266 | 280 | release notes only |
| tests/smoke-configs.sh | 14943 | 421 | config-generation tests |

Cap: about 500 lines of Core per turn. Prefer `bash scripts/maintainer-map.sh --ai "<task>"`.

## Areas

| area | core slice | lines | tests | when |
| --- | --- | ---: | --- | --- |
| `launcher` | xray-manager.sh:33-710 | 678 | tests/bootstrap-install.sh,tests/manager-menu-update.sh,tests/version-lock.sh,tests/atomic-release.sh | launcher / 启动器 / 自更新 / self-update / 菜单更新 / 版本 / 降级 / downgrade |
| `install-migrate` | lib/xray-manager-core.sh:624-1543 | 920 | tests/bootstrap-install.sh,tests/offline-install.sh,tests/config-migration.sh,tests/smoke-configs.sh | 安装 / 依赖 / dependency / jq / 修复 / 迁移 / migration / systemd |
| `network-ipv6` | lib/xray-manager-core.sh:186-623 | 438 | tests/offline-install.sh | 网络 / ipv4 / ipv6 / only-v6 / NAT64 / DNS64 / 下载代理 / proxy |
| `inbound-transport` | lib/xray-manager-core.sh:1804-4997 | 3194 | tests/inbound-management.sh,tests/wireguard-management.sh,tests/smoke-configs.sh,tests/manager-menu-update.sh | 入站 / inbound / 详情 / detail / 编号 / index / 诊断 / diagnose |
| `outbound` | lib/xray-manager-core.sh:4998-5615 | 618 | tests/wireguard-management.sh,tests/smoke-configs.sh | 出站 / outbound / freedom / socks / http / shadowsocks / wireguard / warp |
| `routing` | lib/xray-manager-core.sh:5616-6077 | 462 | tests/smoke-configs.sh | 路由 / routing / 分流 / rule / geosite / geoip / CIDR / 默认出口 |
| `port-forward` | lib/xray-manager-core.sh:7464-7524 | 61 | tests/smoke-configs.sh | 端口转发 / forwarding / forward / TCP / UDP / 监听 / 目标端口 |
| `config-safety` | lib/xray-manager-core.sh:1544-1754,lib/xray-manager-core.sh:7117-7341 | 436 | tests/smoke-configs.sh,tests/config-migration.sh,tests/backup-restore.sh | 配置 / 写入 / 回滚 / backup / restore / test / config / conf.d |
| `xray-geodata` | lib/xray-manager-core.sh:6078-6955 | 878 | tests/xray-version-select.sh,tests/xray-asset-integrity.sh,tests/smoke-configs.sh | Xray-core / core / geodata / geoip / geosite / 更新 / release / digest |
| `firewall-bbr` | lib/xray-manager-core.sh:6956-7116 | 161 | tests/inbound-management.sh,tests/smoke-configs.sh | UFW / 防火墙 / SSH / BBR / sysctl / 端口放行 / 规则清理 |
| `release` | — | 0 | scripts/maintainer-map.sh,.github/workflows/shellcheck.yml,tests/xray-asset-integrity.sh | 发版 / version / checksum / SHA256 / changelog / release / 打包 / 清单 |
| `ci-tests` | — | 0 | tests/inbound-management.sh,tests/maintainer-map.sh,tests/bootstrap-install.sh,tests/offline-install.sh,tests/config-migration.sh,tests/backup-restore.sh,tests/version-lock.sh,tests/manager-menu-update.sh,tests/atomic-release.sh,tests/xray-version-select.sh,tests/xray-asset-integrity.sh | CI / Actions / ShellCheck / test / smoke / 测试失败 / workflow |

## How to slice

```bash
bash scripts/maintainer-map.sh --ai "SS2022 用户"
grep -i shadowsocks docs/ai/core-symbols.tsv
sed -n '2565,2628p' lib/xray-manager-core.sh
```

If the cluster is larger than 500 lines (`inbound-transport` is ~3000), do not read the cluster. Grep the TSV or pass a protocol/function keyword to `--ai`.

