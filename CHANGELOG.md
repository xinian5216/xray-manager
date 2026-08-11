# Changelog

## Unreleased

### Added
- 将 Cloudflare 下载 Worker 的 TypeScript 源码、Wrangler 配置和依赖锁文件纳入仓库，可由现有 Worker 直接连接 GitHub 构建部署。
- 明确 R2 发布工作流固定覆盖五个对象键，不按日期或版本累积对象。

### Security and tests
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
