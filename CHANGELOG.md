# Changelog

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
