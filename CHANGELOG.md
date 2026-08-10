# Changelog

所有值得记录的项目变化都会维护在这里。

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
