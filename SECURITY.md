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

## 更新信任链

安装与发布路径 fail closed，发现摘要或来源异常时停止，不覆盖本机或 R2 上一次已验证的内容。

1. **上游 Xray**：R2 发布工作流只接受 `https://github.com/XTLS/Xray-core/releases/download/<tag>/Xray-linux-(64|arm64-v8a).zip`。优先使用 GitHub Release API 的 `digest`（`sha256:` + 64 位十六进制）；缺失或需交叉核验时读取同名 `.dgst` 的 `SHA2-256=`。摘要缺失、格式错误、重复资产、URL/Tag/架构不匹配或哈希不一致时，工作流失败且不上传。
2. **内嵌清单**：每个离线 tar 含 `release-manifest.json`，记录 Manager / Xray / GeoData 版本以及各架构 Xray ZIP 的 SHA256。该文件无法包含自身 tar 的哈希（写入后哈希会变）。
3. **外层清单**：R2 的 `releases/manifest.json` 在打包完成后写入，包含内嵌清单字段、`built_at` 以及 `latest-amd64.tar.gz` / `latest-arm64.tar.gz` 的 SHA256。Worker 只允许这一固定对象名。
4. **VPS**：Cloudflare 引导与自更新先核对 sidecar `.sha256` 与外层清单中的包摘要，解压后再要求内嵌清单的 `manager_version` 与 `VERSION` 一致。GitHub 路径继续用仓库 `SHA256SUMS` 校验 Launcher/Core。任一环节失败都拒绝安装或更新。
5. **acme.sh**：证书签发下载固定 Commit 的上游归档，校验 `acme.sh` 脚本 SHA256 后再执行；无法下载或哈希不符时要求预装受信任副本，不再 `curl | sh`。
6. **GitHub Actions**：`actions/checkout` 与 `actions/setup-node` 固定到完整 Commit SHA。工作流日志只输出版本和摘要，不打印 Token 或 Secret。

`SHA256SUMS`、R2 sidecar `.sha256` 和清单可以发现传输损坏和部分上传，但不能单独抵御“发布源写权限被攻破且攻击者同时改写包与清单”的情况。

## 发布签名（未在本版本启用）

评估过用 minisign 或 cosign 为 `releases/manifest.json` 签名，并把公钥固定在已安装 Launcher 中。这能在 R2 写密钥泄露时提供额外保护，但私钥必须与 R2 Access Key、Worker `INSTALL_TOKEN` 分离，且不能放进同一个 GitHub Actions 作业里自动签名。当前仓库没有独立的离线签名密钥，因此本版本不引入签名文件或验证逻辑；在具备专用签名密钥之前，继续依赖上游 digest、清单交叉核验和 fail closed。

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
