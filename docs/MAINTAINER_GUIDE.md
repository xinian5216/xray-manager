# 维护与故障定位指南

这份文档解决两个问题：看到故障时先改哪里，以及改完至少验证什么。它面向维护者，不替代用户操作说明。

## 最快入口

不要先通读 7600 多行 Core。AI 第一次接触必须走 `--ai` 或 `docs/ai/INDEX.md`，只打开返回的行号切片。

```bash
bash scripts/maintainer-map.sh --ai "路由规则顺序"
bash scripts/maintainer-map.sh --ai "Xray 版本选择"
bash scripts/maintainer-map.sh --ai "SS2022"
```

人类也可以继续用无参数查询；它会打印区域、测试和最多 20 个候选函数：

```bash
bash scripts/maintainer-map.sh "IPv6 下载"
bash scripts/maintainer-map.sh --list
bash scripts/maintainer-map.sh --check
```

静态索引（AI 不能跑脚本时用）：

- `docs/ai/INDEX.md`：区域 → Core 切片、测试、文件体积
- `docs/ai/core-symbols.tsv`：函数名 → `file/start/end/area`，用 grep 查，不要整表读进上下文

移动函数或维护区域后必须重新生成：

```bash
bash scripts/maintainer-map.sh --write-index
```

没有命中时，再按终端中的原始错误文本搜索：

```bash
rg -n --fixed-strings '完整错误文本' .
grep -i shadowsocks docs/ai/core-symbols.tsv
```

## 故障现象到修改入口

| 现象或需求 | 首要修改入口 | 必看测试 |
| --- | --- | --- |
| `xraym` 启动、自更新、版本显示或回滚异常 | `xray-manager.sh` | `tests/atomic-release.sh`、`tests/manager-menu-update.sh` |
| Manager 版本比较、降级保护或并发锁异常 | Launcher/Core 中 `*version*`、`*manager_lock*` | `tests/version-lock.sh` |
| GitHub 私有仓库首次安装失败、依赖缺失 | `install.sh` | `tests/bootstrap-install.sh`、Bash/ShellCheck |
| 完全离线安装、架构识别、校验失败 | `offline-install.sh` | `tests/offline-install.sh` |
| 已有 Xray 被识别、迁移或服务接管异常 | `lib/xray-manager-core.sh` 中 `discover_*`、`migrate_*`、`configure_*_service` | `tests/config-migration.sh`、`tests/offline-install.sh` |
| 备份创建、归档校验、恢复或失败回滚异常 | Core 中 `backup_now`、`validate_backup_archive`、`restore_backup*` | `tests/backup-restore.sh`、`tests/wireguard-management.sh` |
| IPv6-only、DNS64/NAT64、下载代理异常 | Core 中 `load_network_state` 至 `ipv6_only_menu` | `tests/offline-install.sh`、Bash/ShellCheck |
| 入站详情、编号选择、迁移节点发现、SS 用户模式或健康诊断 | Core 中 `*inbound*`、`*shadowsocks*`、`diagnose_inbound` | `tests/inbound-management.sh`、`tests/smoke-configs.sh` |
| WireGuard 密钥、客户端 Peer、配置导出/二维码、`.conf` 导入或 WARP `Reserved` | Core 中 `*wireguard*`、`*inbound_user*`、`backup_now`、`restore_backup` | `tests/wireguard-management.sh`、`tests/smoke-configs.sh` |
| 入站传输、REALITY、TLS 或证书问题 | Core 中 `build_*_settings`、`add_*` | `tests/smoke-configs.sh` |
| 出站新增、删除或引用判断错误 | Core 中 `*_outbound*` | `tests/smoke-configs.sh` |
| 路由顺序、默认出口或冲突检测错误 | Core 中 `routing_*`、`*_route*` | `tests/smoke-configs.sh` |
| TCP/UDP 端口转发、UFW 放行或规则清理错误 | Core 中 `*_port_forward*`、`*ufw*` | `tests/inbound-management.sh`、`tests/smoke-configs.sh` |
| GitHub 安装/更新版本选择、Pre-release、降级保护或失败回滚异常 | Core 中 `xray_version_*`、`xray_github_*`、`xray_install_selected_version`、`update_xray` | `tests/xray-version-select.sh` |
| 上游 ZIP 摘要、Release 资产或更新信任链异常 | `scripts/verify-xray-asset.sh`、Core 中 `xray_verify_*`、Launcher | `tests/xray-asset-integrity.sh`、`tests/xray-version-select.sh` |
| 版本、哈希或校验和工作流失败 | `VERSION`、`XRAY_VERSION`、`SHA256SUMS`、Validate 工作流 | Validate 工作流 |

完整、可由 CI 校验的映射由 `scripts/maintainer-map.sh` 保存；上表只保留最常见入口。

## 代码边界

```text
安装入口
├── install.sh                 GitHub 私有仓库下载
└── offline-install.sh         完全离线导入

运行入口
└── xray-manager.sh            Launcher、版本、自更新与 --rollback
    └── releases/<version>/    原子发布单元（Launcher + Core）
        └── lib/xray-manager-core.sh
            ├── 平台、网络、下载与迁移
            ├── 配置安全写入与服务控制
            ├── 入站、出站、路由与端口转发
            └── UFW、BBR、备份、证书与菜单

分发入口
└── .github/workflows/         语法、ShellCheck、SHA256、测试与 smoke test
```

Core 目前保持单文件，是因为 Launcher、自更新和离线安装只需把一对脚本作为同一发布单元安装。不要只为“看起来整洁”把它拆成运行时依赖；如果确实拆分，必须在同一个变更里同步安装器、自更新、离线包、`SHA256SUMS` 和相关测试。

## 修改时必须守住的约束

- 所有正式配置写入都应走“临时目录完整测试 → 备份 → 替换 → 重启 → 失败回滚”，优先复用 `safe_write_config_file`、`safe_remove_config_file` 和 `write_routing_json`。
- 管理器创建的出站保持 `20_outbound_<tag>_tail.json`，避免改变默认出口。
- 管理路由只写 `30_routing.json`；检测到其他顶层 `routing` 时不能静默覆盖。
- 最终默认路由必须位于规则末尾。
- 已有配置迁移继续保留双重确认、迁移前完整备份和切换前测试。
- 不默认接管系统默认路由，不默认将无认证 SOCKS/HTTP 代理暴露公网，不因 IPv6-only 自动启用 WARP。
- WireGuard 客户端私钥只能进入 root-only 的 `${STATE_DIR}/wireguard/<tag>/` 和权限为 `600` 的备份；不能打印服务端私钥，也不能为仅导入公钥的 Peer 伪造客户端私钥。
- 上游 Xray ZIP 必须通过 URL/Tag/资产名与 SHA256 digest（或 `.dgst`）校验后才能安装；缺失、冲突或校验失败时 fail closed，保留旧 Core 并自动回滚。
- GitHub 在线安装/更新的版本选择必须保留严格 `vX.Y.Z` 校验、当前架构资产确认、API digest / `.dgst` 交叉校验、降级默认拒绝、更新前备份与失败自动回滚；只有全部检查成功后才报告“更新完成”。
- `XRAY_VERSION` 只是 CI 使用的 Xray Core 测试基准版本，不限制 GitHub 在线安装用户能选择的版本。

## 测试选择

| 改动区域 | 最小验证 |
| --- | --- |
| 任意 Bash 文件 | `bash -n <file>`；`shellcheck -S warning <file>` |
| Core 配置生成 | 使用固定 Xray 执行 `tests/smoke-configs.sh` |
| 安装、依赖或迁移 | 对应的 bootstrap/offline/config-migration 测试 |
| 版本或发布 | `scripts/refresh-checksums.sh` 后执行完整 Validate |
| 维护映射 | `bash scripts/maintainer-map.sh --check` |

Core 被测试脚本 `source` 后会重绑定路径和服务函数。新增会在加载阶段直接执行的代码，会同时破坏测试隔离和真实安装，请把副作用留在显式函数或 `main_menu` 调用路径中。

## 新增功能的落点

1. 先给功能归入一个现有维护区域；没有合适区域时，先给 `MAP_ROWS` 新增一行。
2. 在 Core 中复用已有安全写入、备份、服务和输入校验函数，避免建立第二套实现。
3. 为配置生成补 `tests/smoke-configs.sh`；为安装、更新或迁移补独立测试。
4. 更新用户文档、`CHANGELOG.md`；功能性发布按 `CONTRIBUTING.md` 同步版本和校验和。
5. 运行 `bash scripts/maintainer-map.sh --check`，保证后续维护者仍能从现象找到入口。

## 提交问题时应保留的信息

- `xraym --version` 输出和安装方式（在线 GitHub / 完全离线）。
- 系统、CPU 架构、IPv4/IPv6 状态及所用 init 系统。
- 完整错误文本、触发菜单路径和可重复步骤。
- `systemctl status xray --no-pager`、`systemctl cat xray` 或对应 OpenRC 信息。
- Xray 配置测试结果和最近日志，但先删除 UUID、密码、私钥、证书私钥、Token 与真实域名/IP 等敏感值。

不要只提交“不能用”的截图；可搜索的原始文本才能稳定关联到函数、文件和测试。
