# Security Policy

## 支持的版本

| 版本 | 状态 |
| --- | --- |
| `main` 分支与最新发布版本 | 接收安全修复 |
| 更早的版本 | 建议先升级到最新版本再复现问题 |

## 报告漏洞

请使用 GitHub 的 **Private Vulnerability Reporting** 私下报告：

```text
仓库页面 → Security → Report a vulnerability
```

- 不要在公开 Issue、Discussion 或聊天群中公开 0-day、利用代码或完整复现脚本。
- 报告请包含：项目版本（`xraym --version`）、发行版与架构、init 系统、复现步骤、实际影响，以及你已做的脱敏处理。
- 维护者会尽快确认收到并评估；这是个人维护项目，不承诺 SLA。修复会进入新的发布版本与 `CHANGELOG.md`。
- 我们不会在修复发布前公开细节；也请你在修复发布前保持私下沟通。

## 不要在 Issue 中提交

无论公开或私下报告，都不要粘贴：

- GitHub Token / PAT、Cloudflare 或任何 API Token
- 服务器 root 密码、SSH 私钥
- VLESS / VMess UUID、REALITY PrivateKey 与 Short ID
- Shadowsocks / Trojan / Hysteria2 密码、SOCKS / HTTP 账号
- 完整订阅、分享链接、二维码
- 真实服务器 IP、域名、主机名、邮箱或控制台凭据

需要提供配置或日志时，请先删除上述字段，只保留结构与错误文本。

## 支持范围与边界

本项目是服务器本机运维工具，不提供代理节点、订阅或接入服务，也不提供针对滥用场景的定制支持。

如果请求涉及诈骗、恶意软件控制、未经授权访问、逃避执法追踪、隐藏恶意流量或黑灰产基础设施，项目不会提供针对性支持。正常的隐私保护、网络代理技术研究与合规部署不属于上述范围。

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

请勿把 `/usr/local/etc/xray/`、`/etc/xray-manager/` 或完整配置输出提交到公开仓库或 Issue。

不要提交到仓库的内容：

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

## 更新信任链

安装与更新路径 fail closed，发现摘要或来源异常时停止，不覆盖本机上一次已验证的内容。

1. **Manager**：`install.sh` 和 `xraym --self-update` 通过 GitHub API 读取 `SHA256SUMS`、`xray-manager.sh` 与 `lib/xray-manager-core.sh`，校验 SHA256 后再写入同一 `releases/<version>/` 目录并原子切换 `current`；失败保留原 current，可用 `xraym --rollback` 回退。
2. **Xray Core**：在线安装/更新（包括用户显式选择的 Pre-release）只接受 `https://github.com/XTLS/Xray-core/releases/download/<tag>/Xray-linux-(64|arm64-v8a).zip`。优先使用 GitHub Release API 的 `digest`（`sha256:` + 64 位十六进制），缺失或需交叉核验时读取同名 `.dgst` 的 `SHA2-256=`；两者并存且冲突时拒绝安装。旧 Core 会在安装前备份到 `/etc/xray-manager/backups/`，安装后配置测试或服务启动失败时自动恢复。
3. **GeoData**：更新走 XTLS 官方安装器或完全离线导入；离线导入会先用候选 Xray 测试完整配置，失败不写入。
4. **完全离线安装**：`offline-install.sh` 校验仓库内 `SHA256SUMS`、验证 Xray 架构与当前配置、必要时配置服务，全程不访问网络。
5. **acme.sh**：证书签发下载固定 Commit 的上游归档，校验 `acme.sh` 脚本 SHA256 后再执行；无法下载或哈希不符时要求预装受信任副本，不再 `curl | sh`。
6. **GitHub Actions**：`actions/checkout` 固定到完整 Commit SHA；工作流默认声明 `contents: read`，日志只输出版本和摘要，不打印 Token 或 Secret。

不在支持范围内的做法：不校验下载、使用任意第三方二进制、HTTP 明文下载、`--insecure`、用 `curl | bash` 安装未经验证的二进制。

`SHA256SUMS` 可以发现传输损坏和部分上传，但不能单独抵御“发布源写权限被攻破且攻击者同时改写文件与校验和”的情况。

## GitHub Token 与下载代理

- `XRAY_MANAGER_GITHUB_TOKEN` / `GH_TOKEN` 是可选增强：公开仓库默认匿名访问，只有私有 fork 或需要更高 API 速率限制时才需要。
- Token 只通过 `Authorization` 头发送给 `api.github.com`；不会写入磁盘、不会出现在日志、不会拼进 URL、也不会默认发送给第三方 URL 前缀型镜像。
- `XRAY_DOWNLOAD_PROXY` 是用户自行配置的传输层（HTTP/SOCKS5/SOCKS5H），不是项目的信任根；第三方 GitHub 镜像可能看到你的请求内容，不要通过不可信镜像发送带 PAT 的私有请求。

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
