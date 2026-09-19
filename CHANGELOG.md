# Changelog

## Unreleased

### Added
- GitHub 来源下的“安装 / 修复 Xray”和“更新 Xray-core”支持版本选择：最新发布版（允许 Pre-release，默认）、最新稳定版、最近 15 个历史版本、手动输入 `vX.Y.Z`。版本选择按当前 CPU 架构过滤 Release ZIP 资产，并对 Stable / Pre-release 与发布日期做展示。
- 新增 `xray_version_*` / `xray_github_*` / `xray_install_selected_version` 等单一职责函数；`run_systemd_installer` 支持向 XTLS 官方安装器追加参数，最终执行 `install --version vX.Y.Z`，配置下载代理时仍附带 `-p PROXY`。
- Alpine/OpenRC 无法使用官方安装器的 `--version`，改为下载对应 Release 官方 ZIP，校验 GitHub API `digest` 与官方 `.dgst` 的 SHA256（两者并存时必须一致）后复用 `offline_import_xray`。
- 新增 `tests/xray-version-select.sh`，覆盖版本标准化与数字比较、Stable/Pre-release/Draft/缺资产筛选、历史版本菜单、手动输入、降级默认拒绝、API digest 校验、安装参数转发、配置/服务失败自动回滚、Alpine 校验失败拒绝与不支持架构的显式回退确认。
- 新增公开项目基础文件：`LICENSE`（MIT）、`DISCLAIMER.md`、`THIRD_PARTY_NOTICES.md`、`.github/ISSUE_TEMPLATE/`（含防泄露提醒）与 GitHub Actions 的 Dependabot 配置。
- 安装与自更新改为“公开仓库匿名访问为默认、PAT 为可选增强”：不再要求普通用户配置 GitHub Token，匿名 API 遇到速率限制或私有 fork 时才需要 Fine-grained PAT；新增匿名安装/匿名自更新的回归测试覆盖。

### Changed
- GitHub 更新 Core 前备份 `/usr/local/bin/xray` 到 `/etc/xray-manager/backups/xray-core-时间/`；安装后依次校验二进制可执行、完整配置测试和服务运行状态，任一步失败自动恢复旧 Core 并重启。
- 修复 `update_xray()` 在配置测试或服务重启失败时仍打印“Xray 更新完成”的问题；现在只有全部步骤成功才显示成功摘要（旧版本 / 新版本 / 来源 / 类型 / 配置测试 / 服务状态）。
- GitHub Releases API 不可用时提供“重试 / 手动输入版本 / 返回”，手动输入也必须通过 Release 元数据验证；所有 GitHub API 请求遵循 `XRAY_DOWNLOAD_PROXY`。
- README 重新定位为“Linux 上的 Xray-core 安装、配置、更新与服务管理工具”，补充支持环境、安全模型、卸载、第三方组件与使用说明章节；示例路径统一改为文档专用地址。
- `docs/PRIVATE_INSTALL.md` 重命名为 `docs/INSTALL.md`，改写为公开仓库安装说明。
- `SECURITY.md` 改写为公开项目的安全政策：支持版本、Private Vulnerability Reporting、Issue 禁止提交的敏感内容、依赖与下载完整性、Token 与代理安全边界。
- `install.sh` 与 Launcher 不再要求 PAT；Token 仅作为可选 `Authorization` 头，403/429 时才提示可设置 Token 提升匿名限额。

### Removed
- 移除 Cloudflare Worker + 私有 R2 离线分发体系（`cloudflare-install.sh`、`worker/`、`publish-r2.yml` 与相关测试）。
- 在线安装和更新统一使用 GitHub；删除 Cloudflare 专用自更新入口 `--self-update-cloudflare` 与 `--self-update-github`，只保留 `xraym --self-update`。
- 删除安装来源状态（`manager_update_source` / `cloudflare_url`）与相关环境变量；升级时安全忽略并尽力清理旧文件。
- 保留完全离线安装功能 `offline-install.sh` 与 XTLS 官方 Release 校验 `scripts/verify-xray-asset.sh`。

### Docs
- README / USAGE / MAINTAINER_GUIDE / SECURITY 说明 Latest Published 与 Latest Stable 的区别、GitHub 默认可能安装 Pre-release、降级确认与失败回滚行为，以及 `XRAY_VERSION` 只是 CI 的 Xray Core 测试基准版本。
- AI / 维护者第一次接触改为分层索引：`AGENTS.md` 只做路由，`scripts/maintainer-map.sh --ai` 与生成的 `docs/ai/` 按函数行号切片，避免把 7600 行 Core 读进上下文。

## v1.8.4 / Core v1.8.4 - 2026-08-26

### Security
- R2 发布工作流在打包前用 GitHub Release API `digest`（`sha256:<64hex>`）校验 Xray ZIP；缺失或异常时回退到官方 `.dgst` 的 `SHA2-256=`，仍失败则中止且不覆盖 R2。
- 拒绝错误域名、错误 Tag、错误架构、重复资产、格式错误或互相冲突的摘要，不再静默降级为“只测试 ZIP”。
- 离线包内写入 `release-manifest.json`（Manager / Xray / GeoData 版本与各架构 Xray ZIP 摘要）；R2 另存覆盖写入的 `releases/manifest.json`（含包 SHA256 与构建时间）。
- Cloudflare 安装与自更新在 sidecar 摘要、发布清单或 VERSION 任一不匹配时 fail closed。
- acme.sh 改为下载固定 Commit 并校验脚本 SHA256 后再执行；无法校验时要求预装，不再 `curl | sh`。
- `actions/checkout` 与 `actions/setup-node` 固定到完整 Commit SHA。

### Tests
- 新增 `tests/xray-asset-integrity.sh`，覆盖 API digest、`.dgst` 回退、哈希不匹配、摘要缺失/畸形、重复资产、冲突 dgst、非预期域名、错误 Tag/架构，以及 list-API 不可用时的延迟发布回退。

### Changed
- Worker 允许鉴权读取 `releases/manifest.json`；R2 固定对象从五个增至六个，仍原位覆盖。

## v1.8.3 / Core v1.8.3 - 2026-08-26

### Changed
- Launcher 与 Core 作为同一发布单元安装到 `releases/<version>/`，校验通过后原子切换 `current`，并保留 `previous` 供快速回滚。
- `/usr/local/sbin/xraym` 与兼容 Core 路径改为指向 `current` 的稳定入口，避免更新中途留下新旧文件错配。
- GitHub bootstrap、离线安装和两条自更新路径复用同一套事务安装函数。

### Added
- `xraym --rollback` 只切换到已校验的本地上一版本；连续执行会在 current/previous 之间切换。
- 首次更新会把旧的固定路径安装无损迁移到发布目录，并保留原有配置、更新来源和 Cloudflare URL。

### Tests
- 新增原子发布回归测试，覆盖旧布局迁移、正常升级、同版本重装、Launcher/Core 写入失败、切换前失败、自检回滚、手动回滚、权限和 Token 不落盘。

## v1.8.2 / Core v1.8.2 - 2026-08-26

### Security
- 自更新严格解析并逐段比较 `MAJOR.MINOR.PATCH`，拒绝歧义版本；降级默认禁止，只有显式传入 `--allow-downgrade` 才会执行。
- Launcher 自更新和 Core 中修改系统状态的主菜单操作共用 root-only 原子目录锁，防止并发写入；仅在持锁进程已退出且锁目录结构安全时清理失效锁。

### Tests
- 新增版本策略与操作锁回归测试，覆盖升级、重装、降级保护、并发冲突、安全失效锁恢复和 Core 锁封装。

## v1.8.1 / Core v1.8.1 - 2026-08-26

### Fixed
- 备份恢复改为事务化目录切换；切换后配置测试或 Xray 重启失败时自动恢复操作前的配置、证书和 WireGuard 客户端资料。
- 恢复前拒绝绝对路径、未知顶层目录、符号链接及特殊文件，避免危险或结构异常的 tar 包触碰正式目录。
- 新备份使用带随机后缀的唯一文件名，避免同一秒内连续操作覆盖已有备份。

### Added
- 新备份内置格式版本、创建时间、Manager/Xray 版本和包含内容清单；旧版无清单备份保持兼容。
- 新增独立备份恢复回归测试，覆盖正常恢复、服务失败回滚、配置预检、危险归档、旧版备份及私钥权限。

## v1.8.0 / Core v1.8.0 - 2026-08-24

### Added
- WireGuard 入站支持自动生成服务端与客户端配对密钥，也可以安全导入已有客户端公钥；默认只为单个客户端分配独立的 `10.66.66.x/32` 隧道地址。
- WireGuard Peer 纳入统一入站详情和用户管理，支持自动分配地址、客户端增删、重命名、修改地址、重复公钥与地址冲突检查。
- 自动生成完整 WireGuard `[Interface]` / `[Peer]` 客户端配置，可在明确确认后重新查看，并通过可选 `qrencode` 导出手机扫码二维码。
- 出站管理新增标准 WireGuard / WARP `.conf` 文件及粘贴导入，支持 `PresharedKey`、IPv4/IPv6 地址、`PersistentKeepalive`、MTU 和 WARP `Reserved`。
- 入站诊断新增 WireGuard 服务端私钥、客户端公钥、Peer 数量、重复公钥和客户端 CIDR 检查。

### Security
- 不再直接打印 WireGuard 服务端私钥；客户端私钥与配置资料只保存在 `/etc/xray-manager/wireguard/<tag>/`，目录权限 `700`、文件权限 `600`。
- WireGuard 客户端资料纳入已有 root-only 配置备份与恢复；删除入站或客户端时同步清理对应资料。
- 对 WireGuard Base64 密钥、IPv4/IPv6 CIDR、Endpoint、MTU、KeepAlive、Reserved 和地址族/解析策略进行提前校验；WARP 出站不会伪造服务端公钥或默认生成未注册的账号密钥。

### Tests
- 新增独立 WireGuard 管理回归测试，覆盖自动/手动密钥、完整配置导出、IPv6、多个客户端、地址冲突、私钥隐藏、预共享密钥、标准 `.conf` 导入、root-only 权限及备份。
- 更新真实 Xray 配置冒烟测试与 GitHub Actions，验证收紧后的 WireGuard 入站默认地址及手动出站向导。

## v1.7.0 / Core v1.7.0 - 2026-08-24

### Added
- 入站列表新增编号、用户模式/数量和配置来源，迁移或外部 JSON 中的入站可安全只读查看。
- 新增人类可读的入站详情中心：协议、监听、网络、加密、用户模式、REALITY/TLS、默认出站、关联路由和运行状态。
- 详情中心支持一次选择后直接查看用户、分享链接、编辑入站、管理用户、查看路由、诊断、查看原始 JSON 和删除。
- 所有入站相关操作支持输入编号或 Tag；迁移/外部配置保持只读，不会被管理器静默改写。
- 新增入站健康诊断：完整配置、服务/监听状态、SS2022 密钥、NTP、路由引用、TLS 证书和 UFW 规则。
- 管理器新建的 UFW 规则使用入站 Tag 独立标识，修改端口或删除入站时仅清理由本项目创建的对应规则。

### Fixed
- Shadowsocks 单用户和多用户模式明确区分；多用户时 Server PSK 不再显示或分享为虚假的 INDEX 0 用户。
- 切换 Shadowsocks 单/多用户前会说明旧链接失效并要求确认；SS2022 多用户链接保持 ServerPassword:UserPassword。
- 提前拒绝 `2022-blake3-chacha20-poly1305` 多用户配置；当前 Xray 只支持 AES-128/AES-256 的 SS2022 多用户。
- 原始配置查看只输出所选入站，默认脱敏密码、UUID、私钥和 SOCKS/HTTP 密码，避免暴露同文件中的其他节点。

### Tests
- 增加入站编号、外部配置发现、详情脱敏、SS2022 单/多用户切换、无效主密码链接和 Chacha20 多用户限制回归测试。

## v1.6.1 / Core v1.6.1 - 2026-08-13

### Fixed
- 修复 R2 发布工作流无法从每日重建、没有旧提交历史的上游 `release` 分支解析 7 天前 GeoData，导致 v1.4.0 后离线包持续停止更新的问题。
- GeoData 延迟策略改为按 GitHub Releases 的 `published_at` 选择完整历史版本，并验证四个必需资产与 SHA256。
- GitHub 与 Cloudflare 在线引导现在会通过系统软件源一并安装 `jq`、OpenSSL、`unzip`、`iproute2` 等运行依赖；完全离线入口会明确列出缺失命令。
- 修复 `/var/log/xray` 目录仍为 `root:root` 且权限为 `750`，导致以 `nobody` 或现有 systemd 服务账号运行的 Xray 无法打开 `access.log` / `error.log` 的问题。
- 日志与配置权限改为跟随 systemd 实际 `User` / `Group`，每次启动和写配置前都会自愈旧安装权限。
- GitHub 下载失败现在显示目标文件与 HTTP 状态；文档明确 Private Repository 的无权限请求返回 `404`，以及 PAT 的正确授权范围。

### Tests
- SS2022 入站与新增用户统一复用密码生成器，并验证随机密钥不会重复、解码长度正确；末尾 `=` / `==` 明确标注为 Base64 填充。
- 新增在线 bootstrap 依赖安装回归测试，并校验日志目录和文件权限。

## v1.6.0 / Core v1.6.0 - 2026-08-11

### Added
- 入站管理新增监听端口、监听地址和完整单个 `InboundObject` JSON 编辑；修改前显示差异并保持 Tag 不变。
- 新增 VLESS、VMess、Trojan、Shadowsocks/SS2022、Hysteria2、SOCKS5 与 HTTP 用户增删改查。
- 新增按用户生成 VLESS、VMess、Trojan、Shadowsocks、Hysteria2、SOCKS/HTTP 分享链接及 `qrencode` 终端二维码。
- 新增可搜索的维护导航：可从故障现象定位到实现文件、候选 Bash 函数、回归测试和关联文档。
- 新增维护者指南与仓库级 `AGENTS.md`，记录模块边界、配置写入/迁移/路由/R2 等不可破坏的约束。
- Validate 工作流校验维护映射引用的路径，并运行常见中文/英文查询回归测试，防止代码增长后导航失效。
- 将 Cloudflare 下载 Worker 的 TypeScript 源码、Wrangler 配置和依赖锁文件纳入仓库，可由现有 Worker 直接连接 GitHub 构建部署。
- 明确 R2 发布工作流固定覆盖五个对象键，不按日期或版本累积对象。

### Security and tests
- 所有入站编辑和用户操作继续复用完整配置预检、自动备份、服务重启失败回滚；拒绝删除认证协议的最后一个用户。
- 分享链接只在明确确认后显示；REALITY 仅推导客户端公钥，不把服务端私钥写进链接，并正确处理 IPv6 方括号和 URL 转义。
- 新增用户生命周期、REALITY 分享参数、IPv6 链接和菜单入口回归测试。
- `INSTALL_TOKEN` 只声明 Secret 名称，不提交 Secret 值；Worker 使用固定时间哈希比较并限制可读取的 R2 路径。
- 新增 Workers 运行时测试、TypeScript 检查和 GitHub Actions Worker 校验任务。

## v1.5.0 / Core v1.5.0 - 2026-08-11

### Added
- 新增出站管理中心：Freedom IPv4/IPv6/指定源地址、SOCKS5、HTTP、Shadowsocks、WireGuard/WARP 和自定义 Outbound JSON。
- 新增路由与分流中心：常用服务、GeoSite、GeoIP、CIDR、入站 Tag、IPv4/IPv6、直连/拦截及最终默认出口。
- 新增路由列表、规则删除、上下移动、Domain Strategy 和自定义 RuleObject。
- 新增主菜单端口转发中心，可查看、添加和删除 TCP、UDP、TCP+UDP 转发，并选择公网/本机监听和目标出站。

### Safety
- 脚本创建的出站统一使用 `20_outbound_<tag>_tail.json`，避免 Xray 多文件合并把新出站变成默认出口。
- 路由统一写入 `30_routing.json`；发现其他文件已有顶层 `routing` 时拒绝自动接管。
- 出站删除前检查路由、链式代理和 `dialerProxy` 引用。
- 通用配置写入在临时目录中测试完整配置，正式写入前备份，服务重启失败时恢复原文件。
- 最终默认路由固定保留在规则末尾，新规则自动插入其前方。

### Fixed
- 端口转发默认不再隐藏在入站高级选项中，并修复 UDP/TCP+UDP 转发只放行 TCP UFW 端口的问题。
- 删除端口转发时同步清理管理器创建的关联路由。

### Tests and docs
- 新增 Freedom、SOCKS5、WireGuard/WARP、路由顺序及指定出站端口转发配置测试。
- README 和使用说明补充出站、路由与端口转发操作及限制。

## v1.4.3 / Core v1.4.3 - 2026-08-11

### Added
- 主菜单新增 `16) 更新 Xray Manager 脚本`，复用 Launcher 已记录的 GitHub / Cloudflare 更新来源，更新后可立即重新载入菜单。
- R2 发布工作流每天检查 Xray 稳定版和 Xray 官方采用的 GeoIP / GeoSite 数据源。

### Safety and tests
- 不采用 Xray Pre-release；新稳定版经过 14 天观察期，GeoData 快照经过 7 天观察期，上游 API 不可用时 Core 回退到仓库 `XRAY_VERSION` 基线。
- GeoData 下载校验上游 SHA256，待发布 Xray 必须同时通过现有配置和 GeoData 解析测试后才覆盖 R2。
- 新增菜单自更新调用测试，并将其加入 Bash 语法和 ShellCheck 校验。

## v1.4.2 / Core v1.4.2 - 2026-08-11

### Fixed
- 菜单 1 与离线安装在覆盖服务启动参数前，自动识别并迁移已有 Xray 单文件配置或配置目录。
- 从 systemd / OpenRC 识别当前实际 Xray 二进制，兼容 `/usr/bin/xray` 等非 Manager 安装路径。
- 兼容恢复被 v1.4.0 / v1.4.1 systemd drop-in 暂时隐藏的旧 `config.json`。

### Safety and tests
- 迁移覆盖前必须连续确认两次；任意一次取消都会中止安装/修复且不修改配置和服务。
- 迁移前备份旧配置、当前 Manager 配置、Xray 可执行文件以及 systemd / OpenRC 服务状态；原始配置不删除。
- 暂存配置必须先通过当前 Xray 的 `-test`，成功后才切换到 Manager `conf.d`，并新增单文件、配置目录、取消迁移和旧 drop-in 恢复测试。

## v1.4.1 / Core v1.4.1 - 2026-08-11

### Fixed
- 修复通过 Cloudflare 安装后，主菜单安装/修复 Xray、更新 Xray-core 与更新 GeoData 仍强制访问 GitHub/XTLS 的问题。
- Core 现在读取已保存的 Cloudflare 更新来源，自动下载对应架构的 R2 离线包并校验 SHA256。
- GeoData 更新只替换 GeoIP / GeoSite，不会把用户自行安装的较新 Xray 降级到 R2 固定版本。

### Security and tests
- 安装密钥仍只存在于当次进程与权限为 600 的临时 curl 配置，操作完成后立即删除。
- 解压前拒绝绝对路径和 `..` 路径，并新增测试保证 Cloudflare 通道不会访问 GitHub/XTLS。

## v1.4.0 / Core v1.4.0 - 2026-08-11

### Added
- 新增 Cloudflare Worker + 私有 R2 的 IPv4 / IPv6 一键安装入口。
- GitHub Actions 自动构建 AMD64 / ARM64 完整离线包，上传并验证五个 R2 对象。
- Cloudflare 安装会记录管理器更新来源，`xraym --self-update` 可继续通过 Worker 鉴权更新 Launcher 与 Core。
- 新增 `--self-update-cloudflare` 与 `--self-update-github` 强制更新选项。

### Security and release
- Worker 安装密钥、R2 写入密钥与 GitHub PAT 完全分离，不持久保存安装密钥。
- 将 `cloudflare-install.sh` 纳入 SHA256、Bash 语法与 ShellCheck 校验。
- R2 发布固定使用经过冒烟测试的 Xray v26.3.27，避免未经验证的最新版自动进入分发。

### Docs
- README、IPv6-only、Private Install 与 Security 文档补充 Cloudflare 分发、备用方式和密钥管理说明。

## v1.3.0 / Core v1.3.0 - 2026-08-10

### Added
- 新增 `offline-install.sh`，可从本地仓库、Xray ZIP、`geoip.dat` 与 `geosite.dat` 完成完全离线安装。
- 主菜单新增“完全离线安装 / 导入 Xray + GeoData”，适用于没有 NAT64 的 IPv6-only VPS。
- 离线导入会校验仓库 SHA256、Xray 可执行性与现有配置，全程不调用网络下载或包管理器。
- 新增 systemd / OpenRC 离线服务配置、旧 payload 备份和离线导入测试。

### Docs
- README 增加纯 IPv6 首次引导、手动上传、SSH SOCKS5 与 NAT64/DNS64 说明。

## v1.2.4 / Core v1.2.0 - 2026-08-10

### Security
- 创建 REALITY 入站时检测常见共享 CDN 域名、CNAME 与响应头，高风险 target 需要二次确认。
- 提供随机化的 REALITY fallback 上下行限速，并允许用户在警告确认后自由关闭。
- 入站详情默认脱敏 UUID、Short ID、密码与 REALITY 密钥，完整输出需要明确确认。
- `/etc/xray-manager` 与备份目录改为 root-only，并设置更严格的默认 umask。

### Tests and docs
- 新增共享 CDN 域名识别和 fallback 限速配置测试。
- README 补充 REALITY 回落机制、限速局限与安全 target 建议。

## v1.2.3 / Core v1.1.1 - 2026-08-10

### Fixed
- 修复 VLESS、VMess、Trojan 向导输出污染导致 jq --argjson 失败。
- 修复命令替换子进程造成的传输类型、路径和 REALITY 客户端信息丢失。
- 恢复 RAW + REALITY 的 Vision 选择，并修复 mKCP 的 UFW 协议判断。
- 修复输入重试时警告文字污染端口、Tag、路径或密钥。
- Core 原生支持独立安装路径，手动安装不再可能覆盖 Launcher。

### Tests and docs
- 新增基于 Xray v26.3.27 的主要协议与传输配置冒烟测试。
- README 新增手动下载、校验、安装与直接运行说明。

## v1.2.2 - 2026-08-10

### Fixed
- 防止 Core 的 `install_manager_command` 覆盖 `/usr/local/sbin/xraym` Launcher。
- 安装 / 自更新在 SHA256 校验后应用确定性的 Core 兼容补丁。
- README 一键命令不再退出当前 SSH / Shell 会话。

### Security
- 原始 Core 先通过仓库 SHA256 校验，再执行本地兼容转换与 Bash 语法检查。
- PAT 继续只做临时私有仓库读取，不默认持久保存。

## v1.2.1 - 2026-08-10

### Fixed
- 将项目改为 Launcher + Core 两层结构，避免大型 Core 在 Git Data 文本写入中出现编码风险。
- Core 使用此前已验证的 v1.1.0 完整脚本。
- 安装和更新同时校验 Launcher 与 Core。

## v1.2.0 - 2026-08-10
- 增加 Private Repository bootstrap、VERSION、SHA256SUMS 与自更新设计。

## v1.1.0 - 2026-08-10
- 增加 IPv6-only、NAT64 / DNS64、IPv6 下载代理和 UFW IPv6 处理。

## v1.0.0 - 2026-08-10
- 初始 Xray 多协议交互式管理版本。
