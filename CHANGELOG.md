# Changelog

## v1.2.1 - 2026-08-10

### Fixed
- 避免通过单个超长 Git Data 文本请求重写核心脚本导致 UTF-8 损坏
- 改为 Launcher + Core 两层结构
- Core 使用此前已验证的 v1.1.0 完整脚本
- 安装与更新同时校验 Launcher 和 Core 的 SHA256
- 自更新使用 `sudo xraym --self-update`

### Security
- PAT 仅临时使用，不默认持久保存
- 更新前执行 SHA256 与 Bash 语法检查

## v1.2.0 - 2026-08-10
- 增加 Private Repository bootstrap、VERSION、SHA256SUMS 与自更新设计

## v1.1.0 - 2026-08-10
- 增加 IPv6-only、NAT64/DNS64、IPv6 下载代理和 UFW IPv6 处理

## v1.0.0 - 2026-08-10
- 初始 Xray 多协议交互式管理版本
