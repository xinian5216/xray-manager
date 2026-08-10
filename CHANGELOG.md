# Changelog

所有值得记录的项目变化都会维护在这里。

## v1.2.0 - 2026-08-10

### Added

- Private Repository 一键 bootstrap：`install.sh`
- `VERSION`
- `SHA256SUMS`
- 安装前 SHA256 完整性校验
- 安装前 `bash -n` 校验
- `xraym` 私有仓库自更新菜单
- Fine-grained PAT 临时认证，不默认保存 Token
- IPv6-only bootstrap 下载代理支持
- `docs/PRIVATE_INSTALL.md`
- `scripts/refresh-checksums.sh`
- GitHub Actions 中的版本与 SHA256 校验

### Changed

- 项目版本升级到 v1.2.0
- README 增加私有仓库一键安装说明
- CI 不再依赖第三方 ShellCheck Action 的 `master` 分支

## v1.1.0 - 2026-08-10

### Added

- IPv6-only VPS 自动检测
- NAT64 / DNS64 检测
- Cloudflare DNS64 辅助
- DNS 修改备份与恢复
- IPv6 可达 HTTP / SOCKS5 下载代理
- IPv6-only 公网入站默认监听 `::`
- IPv6-only ACME standalone 处理
- UFW IPv6 检查
- 网络栈诊断菜单

### Changed

- Xray 安装和更新统一复用网络预检
- GeoData 更新统一复用网络预检
- 下载动作支持配置代理

## v1.0.0 - 2026-08-10

### Added

- Xray 安装 / 修复
- VLESS / VMess / Trojan
- Shadowsocks
- Hysteria2
- SOCKS / HTTP
- WireGuard Inbound
- Tunnel / TUN
- RAW / XHTTP / gRPC / WebSocket / HTTPUpgrade / mKCP
- REALITY / TLS
- acme.sh
- UFW
- BBR
- GeoData 更新
- 配置测试
- 日志
- 备份 / 恢复
- 多文件 confdir 管理
