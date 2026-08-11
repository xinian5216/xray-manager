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

## Cloudflare 与 GitHub Actions 密钥

三类密钥必须分离：

- Worker `INSTALL_TOKEN`：只用于 VPS 下载私有离线包。
- R2 Access Key ID / Secret Access Key：只用于 GitHub Actions 写入指定 Bucket。
- GitHub Fine-grained PAT：只用于直接读取 Private Repository。

`worker/wrangler.jsonc` 只声明 `INSTALL_TOKEN` 这个 Secret 名称和 `BUNDLES` R2 绑定，不保存任何 Secret 值。连接 GitHub 自动构建时，继续复用 Cloudflare 控制台中现有的 `INSTALL_TOKEN`，不要把它添加为仓库变量、构建变量或普通 `vars`。

R2 API Token 应限制为 `xray-manager-private` Bucket 的 Object Read & Write，不要授予无关账户权限。R2 密钥只能保存为 GitHub Actions Secrets；Cloudflare Account ID 可以保存为普通 Repository Variable。

不要把任何密钥写入 README、工作流 YAML、命令行 URL、Issue 或 Actions 日志。发现泄露后应立即轮换对应密钥；只更换 Worker `INSTALL_TOKEN` 不会影响 R2 上传密钥，反之亦然。

Cloudflare 引导脚本将安装密钥写入权限为 600 的临时 curl 配置，任务结束后删除；管理器后续更新仍会重新提示，不持久保存安装密钥。

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
