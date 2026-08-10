# Xray Manager

一个面向常用 Linux VPS 的交互式 Xray 安装与管理脚本，重点兼顾普通 IPv4、双栈和 IPv6-only VPS。

> 当前项目版本：**v1.2.1** · 核心配置引擎：**v1.1.0**

## 私有仓库一键安装

仓库保持 **Private**。推荐给 `xray-manager` 单独创建 Fine-grained PAT，仅授权 `Contents: Read-only`。

```bash
read -rsp "GitHub Token: " GH_TOKEN; echo; export GH_TOKEN; \
curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github.raw+json" -H "X-GitHub-Api-Version: 2022-11-28" \
"https://api.github.com/repos/xinian5216/xray-manager/contents/install.sh?ref=main" -o /tmp/xray-manager-install.sh && \
bash /tmp/xray-manager-install.sh --run; rc=$?; rm -f /tmp/xray-manager-install.sh; unset GH_TOKEN; exit $rc
```

安装完成：

```bash
sudo xraym
```

自更新：

```bash
sudo xraym --self-update
```

查看版本：

```bash
xraym --version
```

## 架构

- `xray-manager.sh`：小型 Launcher / 私有仓库自更新器
- `lib/xray-manager-core.sh`：已验证的完整 Xray 管理核心
- `install.sh`：Private Repository bootstrap
- `VERSION`：项目版本
- `SHA256SUMS`：Launcher、Core 和安装器完整性校验

## 核心功能

- Xray 安装 / 修复 / 更新
- GeoIP / GeoSite 更新
- VLESS、VMess、Trojan、Shadowsocks、Hysteria2
- SOCKS、HTTP、WireGuard、Tunnel、TUN
- RAW、XHTTP、gRPC、WebSocket、HTTPUpgrade、mKCP
- REALITY、TLS、自定义 SNI / target
- UFW、BBR
- 配置测试、日志、备份恢复
- IPv6-only、NAT64、DNS64、IPv6 下载代理

详细文档见 `docs/`。

## 安全

- PAT 默认不持久化
- SOCKS / HTTP 默认只监听本机
- 防火墙启用前先放行 SSH
- 更新前执行 SHA256 与 `bash -n`
- 仓库当前不附带开源许可证
