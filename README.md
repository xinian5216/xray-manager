# Xray Manager

一个面向常用 Linux VPS 的交互式 Xray 安装与管理脚本，重点兼顾普通 IPv4、双栈和 IPv6-only VPS。

> 当前脚本版本：**v1.2.0**

## 功能

- 一键安装 / 修复 Xray-core
- 更新 Xray-core
- 更新 GeoIP / GeoSite
- 多入站配置与独立 JSON 管理
- VLESS
- VMess
- Trojan
- Shadowsocks 2022 / AEAD
- Hysteria2
- SOCKS5
- HTTP Proxy
- WireGuard Inbound
- Tunnel
- TUN
- 自定义 Inbound JSON
- RAW / XHTTP / gRPC / WebSocket / HTTPUpgrade / mKCP
- REALITY
- TLS 证书导入
- acme.sh + Let's Encrypt
- 自定义 REALITY SNI / target
- UFW 防火墙管理
- BBR
- 配置测试
- 服务与日志管理
- 配置自动备份与恢复
- IPv6-only / NAT64 / DNS64 检测与辅助
- IPv6-only 下载代理支持

## 支持环境

主要面向以下常见 VPS 系统：

- Debian
- Ubuntu
- CentOS
- Rocky Linux
- AlmaLinux
- RHEL
- Fedora
- openSUSE
- Arch Linux
- Alpine Linux

初始化系统：

- systemd
- Alpine Linux OpenRC

> 不同云厂商可能修改内核、DNS、路由、防火墙或软件源，因此无法保证所有定制系统均可自动处理。

## 私有仓库一键安装

这个仓库保持 **Private**，所以一键下载需要 GitHub Fine-grained PAT。

Token 建议只授权：

```text
xray-manager
Contents: Read-only
```

一次粘贴版：

```bash
read -rsp "GitHub Token: " GH_TOKEN; echo; export GH_TOKEN; \
curl -fsSL \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github.raw+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/xinian5216/xray-manager/contents/install.sh?ref=main" \
  -o /tmp/xray-manager-install.sh && \
bash /tmp/xray-manager-install.sh --run; \
rc=$?; rm -f /tmp/xray-manager-install.sh; unset GH_TOKEN; exit $rc
```

安装器会验证 `SHA256SUMS` 和 Bash 语法，再安装为：

```text
/usr/local/sbin/xraym
```

详细说明：

- [`docs/PRIVATE_INSTALL.md`](docs/PRIVATE_INSTALL.md)

## 本地快速开始

```bash
chmod +x xray-manager.sh
sudo ./xray-manager.sh
```

首次运行建议先选择：

```text
1) 一键安装 / 修复 Xray
```

安装完成后，脚本会尝试安装管理命令：

```bash
sudo xraym
```

## IPv6-only VPS

脚本会识别只有 IPv6 出口的 VPS，并针对以下情况分别处理：

1. GitHub / XTLS 可直接通过 IPv6 访问  
2. 系统已经具有可用 DNS64 + NAT64  
3. VPS 有 NAT64，但当前 DNS 不提供 DNS64  
4. VPS 没有 NAT64，需要 IPv6 可达的 HTTP / SOCKS5 下载代理  

脚本不会把“修改 DNS”当作万能 IPv4 出口。DNS64 只能合成 AAAA 记录，真正访问 IPv4 网络仍需要 NAT64 网关。

详细说明见：

- [`docs/IPV6_ONLY.md`](docs/IPV6_ONLY.md)

## 推荐使用方式

公网代理一般优先考虑：

```text
VLESS + RAW + REALITY + Vision
```

或：

```text
VLESS + XHTTP + REALITY
```

其他协议和传输主要用于兼容、特殊网络环境或实验用途。

## 配置目录

默认目录：

```text
/usr/local/etc/xray/
```

多文件配置：

```text
/usr/local/etc/xray/conf.d/
```

每个由脚本管理的入站使用独立 JSON 文件，便于增加、删除、测试和回滚。

GeoData：

```text
/usr/local/share/xray/
```

日志：

```text
/var/log/xray/
```

脚本状态与备份：

```text
/etc/xray-manager/
```

## 安全说明

- SOCKS5 和 HTTP Proxy 默认仅监听 `127.0.0.1`
- 启用 UFW 前会优先放行当前 SSH 端口
- 对配置变更执行 Xray 配置测试
- 重要操作前自动备份
- 服务重启失败时尽量自动回滚
- REALITY 私钥、UUID、密码等属于敏感信息，请勿公开
- 不建议在生产 VPS 上盲目开启 TUN 全局路由
- 不自动替换 VPS 内核以启用 BBR

## TLS

支持：

- 导入已有证书
- acme.sh + Let's Encrypt standalone HTTP-01

IPv6-only 环境下会尝试使用 IPv6 standalone 监听。

使用 HTTP-01 前，请确认：

- 域名 DNS 已正确解析到 VPS
- TCP 80 可访问
- 80 端口没有被其他程序占用

## UFW

启用 UFW 时脚本会优先检测当前 SSH 端口并放行，然后再启用防火墙。

即使如此，建议始终保留云厂商控制台 / VNC / Serial Console 等应急登录方式。

## BBR

脚本会检测当前内核是否提供 BBR。

只有检测到内核支持时才配置：

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

不会为了启用 BBR 自动更换内核。

## 更新

进入主菜单：

```text
6) 更新 Xray-core
7) 更新 GeoIP / GeoSite
```

IPv6-only VPS 更新时仍会复用 NAT64 / DNS64 / 下载代理检测逻辑。

## 项目结构

```text
.
├── xray-manager.sh
├── install.sh
├── VERSION
├── SHA256SUMS
├── README.md
├── CHANGELOG.md
├── SECURITY.md
├── CONTRIBUTING.md
├── .gitignore
├── docs
│   ├── USAGE.md
│   ├── IPV6_ONLY.md
│   └── PRIVATE_INSTALL.md
├── scripts
│   └── refresh-checksums.sh
└── .github
    └── workflows
        └── shellcheck.yml
```

## 验证

至少可以先执行：

```bash
bash -n xray-manager.sh
```

仓库还包含 GitHub Actions ShellCheck 工作流，用于提交后自动做 Shell 静态检查。

## 上游项目

本项目依赖或调用：

- XTLS/Xray-core
- XTLS/Xray-install
- acme.sh
- Let's Encrypt

请以各上游项目的官方文档和许可证为准。

## License

当前仓库**未附加开源许可证**。

这意味着代码不会因为放到 GitHub 就自动授予第三方开源许可。若未来希望公开仓库，再根据需要选择 MIT、Apache-2.0、GPL 等许可证。

## Disclaimer

本脚本用于服务器管理和网络技术学习。使用者应自行确保用途符合所在地法律、服务商条款和网络管理要求。修改防火墙、路由、DNS、证书或代理配置均可能导致服务中断，请在重要服务器上提前准备快照和应急登录方式。

## Xray Manager 自更新

安装后的 `xraym` 主菜单包含：

```text
15) 检查 / 更新 Xray Manager（私有仓库）
```

更新时会：

1. 安全提示输入 GitHub Token
2. 对比 `VERSION`
3. 下载 `SHA256SUMS`
4. 下载新脚本
5. 校验 SHA256
6. 执行 `bash -n`
7. 更新 `/usr/local/sbin/xraym`

Token 默认不持久化。
