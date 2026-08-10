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

该代理主要用于：

- Xray 安装
- Xray 更新
- GeoData 更新
- GitHub / XTLS 下载

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
原生 IPv6
→ 已有 NAT64/DNS64
→ 可用 NAT64 + DNS64
→ IPv6 可达下载代理
→ 用户自行决定是否配置 WARP
```
