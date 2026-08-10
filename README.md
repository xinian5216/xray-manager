# Xray Manager

一个面向常用 Linux VPS 的交互式 Xray 安装与管理项目，兼顾 IPv4、双栈和 IPv6-only VPS。

> 当前项目版本：**v1.2.2** · Core：**v1.1.0**

## 核心功能

- Xray-core 安装 / 修复 / 更新
- GeoIP / GeoSite 更新
- VLESS、VMess、Trojan、Shadowsocks、Hysteria2
- SOCKS5、HTTP Proxy、WireGuard Inbound、Tunnel、TUN
- RAW、XHTTP、gRPC、WebSocket、HTTPUpgrade、mKCP
- REALITY / TLS / 自定义 SNI 与 target
- UFW、BBR、日志、配置测试、备份恢复
- IPv6-only、NAT64 / DNS64、IPv6 可达下载代理

## 私有仓库一键安装

仓库保持 **Private**。建议创建只针对 `xray-manager` 的 Fine-grained PAT，并只授予 `Contents: Read-only`。

```bash
read -rsp "GitHub Token: " GH_TOKEN; echo; export GH_TOKEN; \
curl -fsSL \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github.raw+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/xinian5216/xray-manager/contents/install.sh?ref=main" \
  -o /tmp/xray-manager-install.sh && \
bash /tmp/xray-manager-install.sh --run; \
rc=$?; rm -f /tmp/xray-manager-install.sh; unset GH_TOKEN; (exit $rc)
```

安装完成后：

```bash
sudo xraym
```

自更新：

```bash
sudo xraym --self-update
```

查看项目 / Core 版本：

```bash
xraym --version
```

## 架构

```text
xray-manager.sh
    ↓ Launcher / Private Repo Updater
lib/xray-manager-core.sh
    ↓ 完整 Xray 管理核心
Xray-core / UFW / BBR / 配置文件
```

项目文件：

```text
.
├── xray-manager.sh
├── install.sh
├── VERSION
├── SHA256SUMS
├── lib/
│   └── xray-manager-core.sh
├── docs/
│   ├── USAGE.md
│   ├── IPV6_ONLY.md
│   └── PRIVATE_INSTALL.md
├── scripts/
│   └── refresh-checksums.sh
├── .github/workflows/shellcheck.yml
├── README.md
├── CHANGELOG.md
├── SECURITY.md
├── CONTRIBUTING.md
└── .gitignore
```

## 安装与更新安全

1. 先下载 `SHA256SUMS`、Launcher 与原始 Core。
2. 校验 SHA256。
3. 对原始 Core 在本机应用一个确定性的 Launcher 兼容补丁，使 Core 后续执行“安装 / 修复 Xray”时只更新自己的 Core 路径，不覆盖 `/usr/local/sbin/xraym`。
4. 对 Launcher 与补丁后的 Core 执行 `bash -n`。
5. 全部通过后才安装。

GitHub Token 默认不会写入配置文件；交互输入完成后仅用于本次私有仓库下载。

## IPv6-only

Core 可自动检查 IPv6-only、NAT64 / DNS64；bootstrap 本身还支持：

```bash
bash /tmp/xray-manager-install.sh --proxy 'socks5h://[IPv6地址]:1080' --run
```

或预设：

```bash
export XRAY_DOWNLOAD_PROXY='http://[IPv6地址]:8080'
```

## 校验

本地：

```bash
bash -n xray-manager.sh
bash -n lib/xray-manager-core.sh
bash -n install.sh
sha256sum -c SHA256SUMS
```

GitHub Actions 还会执行版本一致性、SHA256、Bash 语法与 ShellCheck 检查。

## License

当前仓库未附加开源许可证，按私有自用项目维护。
