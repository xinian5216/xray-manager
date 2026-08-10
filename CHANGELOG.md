# Changelog

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
