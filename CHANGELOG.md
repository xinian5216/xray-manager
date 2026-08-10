# Changelog

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
