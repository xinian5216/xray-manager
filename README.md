# Xray Manager

一个面向常用 Linux VPS 的交互式 Xray 安装与管理项目，兼顾 IPv4、双栈和 IPv6-only VPS。

> 当前项目版本：**v1.3.0** · Core：**v1.3.0**

## 核心功能

- Xray-core 安装 / 修复 / 更新
- GeoIP / GeoSite 更新
- VLESS、VMess、Trojan、Shadowsocks、Hysteria2
- SOCKS5、HTTP Proxy、WireGuard Inbound、Tunnel、TUN
- RAW、XHTTP、gRPC、WebSocket、HTTPUpgrade、mKCP
- REALITY / TLS / 自定义 SNI 与 target
- REALITY 共享 CDN target 风险检测、随机化回落限速
- UFW、BBR、日志、配置测试、备份恢复
- IPv6-only、NAT64 / DNS64、IPv6 可达下载代理
- 完全离线导入 Xray ZIP、GeoIP 与 GeoSite

## 纯 IPv6 VPS：首次安装先看这里

如果 VPS 没有 IPv4、NAT64 或可用代理，`api.github.com`、XTLS 安装器及 GeoData 下载链路可能无法访问。此时普通私有仓库一键命令会在下载 `install.sh` 之前失败；Core 内部的 IPv6 检测还没有机会运行。

不要只上传 `install.sh`，因为它仍然需要访问 GitHub。根据条件选择下面一种方式。

### 方案 A：完全离线安装（推荐）

先在有网络的电脑上准备并上传到 VPS：

1. 本仓库 ZIP，并在 VPS 上解压。
2. 与 VPS CPU 架构匹配的官方 `Xray-linux-*.zip`。
3. `geoip.dat`。
4. `geosite.dat`。

先在 VPS 执行 `uname -m` 确认架构：常见的 `x86_64` 对应 `Xray-linux-64.zip`，`aarch64` 对应 `Xray-linux-arm64-v8a.zip`。

例如把三个资源文件放在 `/home/xinian/offline-bundle/`，然后进入解压后的仓库目录执行：

```bash
sudo bash offline-install.sh \
  --bundle-dir /home/xinian/offline-bundle \
  --run
```

也可以逐个指定：

```bash
sudo bash offline-install.sh \
  --xray-zip /home/xinian/Xray-linux-64.zip \
  --geoip /home/xinian/geoip.dat \
  --geosite /home/xinian/geosite.dat \
  --run
```

离线安装器会：

- 校验仓库内 Launcher 与 Core 的 SHA256。
- 使用本机已有的 `unzip`、`bsdtar` 或 Python 3 读取 ZIP，不联网安装依赖。
- 验证 Xray 能否在当前 CPU 架构运行。
- 使用上传的 GeoData 测试现有配置，通过后才写入正式路径。
- 配置 systemd / OpenRC 服务，并备份已有 Xray 与 GeoData。
- 安装 `xraym` Launcher 与 Core。

该流程不会调用 `curl`、`wget`、`apt`、`apk` 或其他网络下载。若系统连 ZIP 解压工具和 Python 3 都没有，需要把其中一种工具也提前离线安装好。

已经安装了 `xraym` 时，也可在主菜单选择：

```text
15) 完全离线安装 / 导入 Xray + GeoData
```

### 方案 B：通过双栈 VPS 建立临时 SSH SOCKS5

纯 IPv6 VPS 能访问另一台双栈 VPS 的 IPv6 时，可建立只监听本机的临时代理：

```bash
ssh -6 -fNT \
  -D 127.0.0.1:1080 \
  -o ExitOnForwardFailure=yes \
  root@双栈VPS的域名或IPv6

export XRAY_DOWNLOAD_PROXY='socks5h://127.0.0.1:1080'
```

首次下载 `install.sh` 的 `curl` 本身也必须添加：

```bash
curl -x "$XRAY_DOWNLOAD_PROXY" ...
```

下载后执行：

```bash
bash /tmp/xray-manager-install.sh --proxy "$XRAY_DOWNLOAD_PROXY"
sudo env XRAY_DOWNLOAD_PROXY="$XRAY_DOWNLOAD_PROXY" xraym
```

### NAT64 / DNS64 注意事项

DNS64 只负责合成 AAAA 记录，NAT64 才负责把 IPv6 流量转换到 IPv4。只修改 DNS、但服务商没有提供 NAT64 网关，仍然无法访问 IPv4-only 资源。优先使用服务商明确提供的 NAT64/DNS64；不要盲目修改系统 DNS。

WARP 也能提供 IPv4 出口，但会改变接口、路由和 DNS，远程操作存在 SSH 失联风险，因此不作为自动安装的默认方案。

完全离线机器以后执行 `xraym --self-update` 仍然需要 GitHub 网络或代理；没有网络时，请上传新版仓库 ZIP，重新运行 `offline-install.sh`。

## 安装方式一：私有仓库一键安装

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

## 安装方式二：手动下载和运行

如果不想执行一键安装脚本，永久安装最少只需要下面两个文件：

| 文件 | 用途 | 是否必需 |
| --- | --- | --- |
| **xray-manager.sh** | Launcher、自更新和版本显示 | 永久安装必需 |
| **lib/xray-manager-core.sh** | 完整交互菜单和 Xray 管理功能 | 必需 |
| **SHA256SUMS** | 校验文件是否完整 | 推荐 |
| **VERSION** | 查看仓库项目版本 | 可选 |
| **install.sh** | 私有仓库一键安装器 | 手动安装不需要 |
| **offline-install.sh** | Xray + GeoData 完全离线安装器 | 纯离线首次安装必需 |

### 1. 下载文件

仓库是 Private，推荐先登录 GitHub，然后在仓库页面选择 **Code → Download ZIP**，上传到 VPS 后解压；也可以在已经配置 GitHub SSH Key 的机器上执行：

~~~bash
git clone git@github.com:xinian5216/xray-manager.git
cd xray-manager
~~~

如果只下载单个文件，请保持 **lib/xray-manager-core.sh** 的目录结构，不要把两个脚本混在同一目录。

### 2. 校验文件

在项目根目录执行：

~~~bash
grep -E ' (xray-manager.sh|lib/xray-manager-core.sh)$' SHA256SUMS | sha256sum -c -
~~~

两项均显示 **OK** 后再继续。若系统没有 **sha256sum**，可以先安装 **coreutils**。

### 3. 完整手动安装

~~~bash
sudo install -d -m 755 /usr/local/lib/xray-manager
sudo install -m 755 xray-manager.sh /usr/local/sbin/xraym
sudo install -m 755 lib/xray-manager-core.sh \
  /usr/local/lib/xray-manager/xray-manager-core.sh
sudo xraym
~~~

首次进入菜单后选择 **1) 一键安装 / 修复 Xray**。这里的“一键”只负责安装官方 Xray-core 和系统服务，不会重新下载 Xray Manager 项目。

### 4. 只临时运行 Core

不安装 Launcher 也可以直接运行：

~~~bash
sudo bash lib/xray-manager-core.sh
~~~

这种方式可以使用完整管理菜单，但不能直接使用 **xraym --self-update**。以后手动更新时应同时替换 Launcher 和 Core，避免两个文件版本不一致。

## 更新

自更新：

```bash
sudo xraym --self-update
```

查看项目 / Core 版本：

```bash
xraym --version
```

## REALITY 回落流量保护

REALITY 会把未通过认证的连接转发到 `target` 以维持正常 TLS 站点的外观。因此即使攻击者没有 UUID，仍可能通过扫描消耗 VPS 与 `target` 之间的回落流量；共享 CDN target 的风险尤其高。

项目创建 REALITY 入站时会：

1. 检查常见共享 CDN 域名、CNAME 和 HTTPS 响应头；发现高风险目标时要求再次确认。
2. 提供随机化的 `limitFallbackUpload` / `limitFallbackDownload`“流量保护”和“隐蔽平衡”两档，也允许选择完全不限速。
3. 查看入站详情时默认隐藏 UUID、Short ID、密码和 REALITY 密钥。
4. 将 `/etc/xray-manager` 与其中备份限制为 root-only。

检测属于启发式判断，不能保证识别所有套了 CDN 的自定义域名。最稳妥的方案仍是自己的域名配合本机 Web 服务，或者同 ASN、非共享 CDN、资源体积较小的普通目标站。如果采用“偷自己”，应让本机 Web 服务监听另一个端口（例如 `127.0.0.1:8443`）并提供自有域名证书；不要让 target 再指回 Xray 正在监听的同一个公网端口，否则会形成回环。

回落限速按单连接生效，攻击者可以通过并发连接部分绕过；限速行为本身也可能形成额外特征。因此它是止损措施，不能替代安全的 target 选择。即使 target 被判定为高风险，用户仍可在阅读警告并再次确认后关闭限速，最终选择权由用户保留。

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
├── tests/
│   └── smoke-configs.sh
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
3. 确认 Core 使用独立安装路径，不覆盖 `/usr/local/sbin/xraym`；安装器仍保留对旧版 Core 的兼容补丁。
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

GitHub Actions 还会执行版本一致性、SHA256、Bash 语法与 ShellCheck 检查，同时会下载固定版本的官方 Xray，对主要协议和传输生成结果执行真实配置测试。

## License

当前仓库未附加开源许可证，按私有自用项目维护。
