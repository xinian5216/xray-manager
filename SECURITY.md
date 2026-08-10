# Security Policy

## 敏感数据

使用本项目生成的配置可能包含：

- VLESS / VMess UUID
- Trojan 密码
- Shadowsocks 密钥
- Hysteria2 auth
- REALITY PrivateKey
- WireGuard PrivateKey
- TLS 私钥
- 下载代理账号密码

请勿把 `/usr/local/etc/xray/`、`/etc/xray-manager/` 或完整配置输出提交到公开仓库。

## GitHub 仓库

本仓库设计为私有仓库使用。

不要提交：

```text
*.key
*.pem
*.crt
*.p12
*.pfx
.env
secrets/
backups/
```

## 漏洞处理

如果未来将项目公开，请避免直接在公开 Issue 中粘贴：

- 私钥
- Token
- 服务器 IP 与完整管理凭据
- SSH 登录信息
- API Key

## VPS 安全

修改以下项目之前建议保留云厂商控制台：

- UFW
- nftables / iptables
- TUN
- 默认路由
- DNS
- WARP
- SSH 端口

## REALITY target 与回落流量

REALITY 会把未通过认证的连接转发到 `target`。不要把 Cloudflare、CloudFront、Fastly、Akamai 等共享 CDN 作为默认 target，否则服务器可能被扫描后当作受限 CDN 转发节点使用。

优先使用自己的域名与本机 Web 服务，或同 ASN 的非 CDN 小站。项目提供的 `limitFallbackUpload` / `limitFallbackDownload` 只能限制单个回落连接，不能完全阻止分布式或并发滥用。

脚本包含部分回滚机制，但不能覆盖所有云厂商和异常情况。
