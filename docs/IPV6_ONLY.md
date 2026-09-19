# IPv6-only VPS

## 为什么需要单独处理

Xray-core 本身可以正常监听和使用 IPv6。

真正容易失败的是安装阶段，例如：

- 系统软件源只有 IPv4
- GitHub 某条访问链路不可达
- GeoData 下载依赖 IPv4
- ACME 或第三方资源只能通过特定网络访问

所以 IPv6-only 的核心问题是“下载与上游访问”，而不是 Xray 协议本身。

## 自动判断

脚本会检查：

- 是否存在全局 IPv4
- 是否存在全局 IPv6
- IPv4 Internet 是否可达
- IPv6 Internet 是否可达
- XTLS 官方安装脚本是否可达
- IPv4-only 目标是否可达
- 是否已设置下载代理

## NAT64 与 DNS64

两者不是同一个东西。

### DNS64

DNS64 会把 IPv4-only 域名的 A 记录转换 / 合成为 AAAA 地址。

### NAT64

NAT64 才是真正把 IPv6 流量转换到 IPv4 网络的网关。

因此：

```text
只有 DNS64 + 没有 NAT64
```

不能让 IPv6-only VPS 访问 IPv4 Internet。

脚本会先测试 NAT64 可用性，再决定是否建议启用 Cloudflare DNS64。

## Cloudflare DNS64

脚本使用的 IPv6 DNS64 地址：

```text
2606:4700:4700::64
2606:4700:4700::6400
```

如果检测成功，可以选择临时 / 持久使用。

脚本会保存修改前状态，以便恢复。

## 没有 NAT64 怎么办

### IPv6 可达代理（推荐）

如果 VPS 能通过 IPv6 访问一台可以访问 IPv4 的代理，设置 `XRAY_DOWNLOAD_PROXY` 即可让安装、自更新、Xray 更新和 GeoData 更新统一走代理：

```bash
export XRAY_DOWNLOAD_PROXY='socks5h://[2001:db8::10]:1080'
```

主菜单 `13) IPv6-only / NAT64 网络助手` 也可以交互设置并保存这个代理。

如果机器原先已经安装 Xray，菜单 1 和离线安装流程会先识别 systemd / OpenRC 当前使用的配置。发现旧 `config.json` 或旧配置目录时，必须连续确认两次才会迁移；任意一次取消都不会覆盖配置或服务。迁移前备份保存到 `/etc/xray-manager/backups/pre-migration-时间/`，旧配置本身不会删除，且新目录必须通过 Xray 配置测试后才会切换。

### IPv6 可达代理

可以设置一个 IPv6 可达、同时能够访问 IPv4 网络的 HTTP 或 SOCKS5 代理。

例如：

```text
http://[2001:db8::10]:8080
```

或：

```text
socks5h://[2001:db8::10]:1080
```

带认证：

```text
http://user:password@[2001:db8::10]:8080
```

该代理用于所有 GitHub / XTLS / GeoData 在线请求：

- GitHub 私有仓库安装与 `xraym --self-update`
- Xray 安装 / 更新
- GeoData 更新
- XTLS 官方安装器下载

### 完全手动离线安装

没有 NAT64、代理或 WARP 时，可以上传仓库 ZIP、官方 Xray ZIP、`geoip.dat` 和 `geosite.dat`，解压仓库后运行：

```bash
sudo bash offline-install.sh --bundle-dir /path/to/offline-bundle --run
```

离线安装器不会调用网络下载或包管理器。它会校验仓库脚本、验证 Xray 架构和当前配置、安装 GeoData、配置 systemd / OpenRC 服务并安装 `xraym`。

本机必须预先具备 `jq`、OpenSSL、`iproute2`、`procps`、`tar`、`gzip`、`coreutils`，以及 `unzip`、`bsdtar` 或 Python 3 中的至少一种。离线安装器发现缺失命令时会直接列出并停止，不会偷偷访问软件源。

## IPv6-only 入站监听

普通 VPS 默认公网监听：

```text
0.0.0.0
```

纯 IPv6 VPS 默认改为：

```text
::
```

SOCKS / HTTP 本地代理仍默认：

```text
127.0.0.1
```

避免无加密代理直接暴露公网。

## TLS 证书

IPv6-only VPS 使用 HTTP-01 时需要：

- 域名存在 AAAA 记录
- AAAA 指向 VPS IPv6
- TCP 80 从公网可达
- 80 端口没有被其他服务占用

脚本会在 IPv6-only 环境中尝试让 acme.sh standalone 显式监听 IPv6。

## UFW

如果系统使用 `/etc/default/ufw`，脚本发现 IPv6 网络后会检查：

```text
IPV6=yes
```

避免只配置 IPv4 防火墙规则。

## 不自动安装 WARP 的原因

WARP 会创建虚拟网络接口，并可能影响：

- 路由表
- 默认出口
- DNS
- 防火墙
- SSH 回程

在远程 VPS 上自动改这些内容存在失联风险。

因此脚本优先顺序是：

```text
原生 IPv6 可达的 GitHub 上游
→ 已有 NAT64/DNS64
→ 可用 NAT64 + DNS64
→ IPv6 可达下载代理（XRAY_DOWNLOAD_PROXY）
→ 手动完整离线导入（offline-install.sh）
→ 用户自行决定是否配置 WARP
```
