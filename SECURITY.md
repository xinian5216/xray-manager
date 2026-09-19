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

## GitHub 密钥

在线安装与自更新只需要一种凭据：

- GitHub Fine-grained PAT：只用于以 Contents: Read 读取 Private Repository。

PAT 只在当次交互中使用：不会写入配置文件、不会输出到日志、不会拼进 URL，也不会默认发送给第三方反向代理。需要网络加速时，请使用 `XRAY_DOWNLOAD_PROXY` 一类的 HTTP/SOCKS5 代理；不要把 `Authorization` 交给不可信的 URL 前缀型镜像。

不要把任何密钥写入 README、工作流 YAML、命令行 URL、Issue 或 Actions 日志。发现泄露后应立即在 GitHub 撤销并轮换该 PAT。

## 更新信任链

安装与更新路径 fail closed，发现摘要或来源异常时停止，不覆盖本机上一次已验证的内容。

1. **Manager**：`install.sh` 和 `xraym --self-update` 通过 GitHub API 读取 `SHA256SUMS`、`xray-manager.sh` 与 `lib/xray-manager-core.sh`，校验 SHA256 后再写入同一 `releases/<version>/` 目录并原子切换 `current`；失败保留原 current，可用 `xraym --rollback` 回退。
2. **Xray Core**：在线安装/更新（包括用户显式选择的 Pre-release）只接受 `https://github.com/XTLS/Xray-core/releases/download/<tag>/Xray-linux-(64|arm64-v8a).zip`。优先使用 GitHub Release API 的 `digest`（`sha256:` + 64 位十六进制），缺失或需交叉核验时读取同名 `.dgst` 的 `SHA2-256=`；两者并存且冲突时拒绝安装。旧 Core 会在安装前备份到 `/etc/xray-manager/backups/`，安装后配置测试或服务启动失败时自动恢复。
3. **GeoData**：更新走 XTLS 官方安装器或完全离线导入；离线导入会先用候选 Xray 测试完整配置，失败不写入。
4. **完全离线安装**：`offline-install.sh` 校验仓库内 `SHA256SUMS`、验证 Xray 架构与当前配置、必要时配置服务，全程不访问网络。
5. **acme.sh**：证书签发下载固定 Commit 的上游归档，校验 `acme.sh` 脚本 SHA256 后再执行；无法下载或哈希不符时要求预装受信任副本，不再 `curl | sh`。
6. **GitHub Actions**：`actions/checkout` 固定到完整 Commit SHA；工作流日志只输出版本和摘要，不打印 Token 或 Secret。

`SHA256SUMS` 可以发现传输损坏和部分上传，但不能单独抵御“发布源写权限被攻破且攻击者同时改写文件与校验和”的情况。

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
