# Xray Manager

一个面向常用 Linux VPS 的交互式 Xray 安装与管理项目，兼顾 IPv4、双栈和 IPv6-only VPS。

> 当前项目版本：**v1.4.2** · Core：**v1.4.2**

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
- Cloudflare Worker + 私有 R2 的 IPv4 / IPv6 一键安装与后续自更新
- 完全离线导入 Xray ZIP、GeoIP 与 GeoSite
- 已有 Xray 配置安全迁移、双重确认和迁移前完整备份

## 快速安装

### 方式一：Cloudflare Worker + 私有 R2（纯 IPv6 首选）

这是没有 NAT64 的 IPv6-only VPS 的推荐入口，也适用于 IPv4 和双栈机器：

```bash
curl -fsSLo /tmp/xray-manager-install.sh \
  https://xray-manager-download.xinian5216.workers.dev/install.sh &&
sudo bash /tmp/xray-manager-install.sh
```

按提示输入独立的 Cloudflare 安装密钥。它不是 GitHub PAT，不要把密钥写进命令、README 或仓库。

当前分发支持：

| VPS 架构 | 离线包 |
| --- | --- |
| `x86_64` / `amd64` | `latest-amd64.tar.gz` |
| `aarch64` / `arm64` | `latest-arm64.tar.gz` |

VPS 需要预先具备 `curl`、`tar`，以及 `unzip`、`bsdtar`、Python 3 中至少一种 ZIP 读取工具。引导脚本会：

1. 通过 Cloudflare 的 IPv4 / IPv6 边缘获取公开入口。
2. 使用 Bearer 安装密钥访问 Worker 后的私有 R2 对象。
3. 根据 CPU 架构下载完整离线包与 SHA256。
4. 校验压缩包，解压仓库、Xray 和 GeoData。
5. 调用 `offline-install.sh` 完成本地安装，安装阶段不再访问其他外网。
6. 记录 Cloudflare 更新来源，以后管理器、Xray-core 和 GeoData 更新继续使用同一通道。

通过该入口安装后，主菜单中的 `1) 安装 / 修复 Xray`、`6) 更新 Xray-core` 和 `7) 更新 GeoData` 会自动从 Worker 后的私有 R2 获取离线包，不再探测或访问 GitHub/XTLS，也不需要 NAT64、WARP 或下载代理。每次下载会安全提示输入安装密钥，密钥不会持久保存。

GitHub Actions 会在相关文件合并到 `main` 后，使用经过配置冒烟测试的固定 Xray 版本重新构建两个架构的包，并覆盖 R2 中的五个对象。R2 保持私有，只有 `public/install.sh` 通过 Worker 公开读取；安装包必须通过 Worker 密钥访问。

测试公开入口：

```bash
curl -6I \
  https://xray-manager-download.xinian5216.workers.dev/install.sh
```

不带密钥访问 `/releases/latest-amd64.tar.gz` 返回 `401` 属于正常保护行为。

### 方式二：私有 GitHub 一键安装

GitHub API 可达时，也可以从 Private Repository 安装。创建只针对 `xray-manager`、仅授予 `Contents: Read-only` 的 Fine-grained PAT：

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

这种方式的安装和后续 `xraym --self-update` 都需要能够访问 `api.github.com`，或者设置 `XRAY_DOWNLOAD_PROXY`。

## 纯 IPv6 VPS：其他备用方式

如果 Worker 入口也无法访问，可以使用真正的手动离线导入，或借助另一台双栈 VPS 建立临时代理。

### 完全手动离线导入

先在有网络的电脑上准备并上传：

1. 本仓库 ZIP，并在 VPS 上解压。
2. 与 VPS 架构匹配的官方 `Xray-linux-*.zip`。
3. `geoip.dat`。
4. `geosite.dat`。

例如将资源放在 `/home/xinian/offline-bundle/`：

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

该流程不会调用网络下载或包管理器。已经安装 `xraym` 时，也可在主菜单选择：

```text
15) 完全离线安装 / 导入 Xray + GeoData
```

### 临时 SSH SOCKS5

纯 IPv6 VPS 能访问另一台双栈 VPS 的 IPv6 时：

```bash
ssh -6 -fNT \
  -D 127.0.0.1:1080 \
  -o ExitOnForwardFailure=yes \
  root@双栈VPS的域名或IPv6

export XRAY_DOWNLOAD_PROXY='socks5h://127.0.0.1:1080'
```

首次获取 GitHub 引导脚本的 `curl` 也必须使用 `-x "$XRAY_DOWNLOAD_PROXY"`。

### NAT64 / DNS64 与 WARP

DNS64 只负责合成 AAAA，NAT64 才负责把 IPv6 流量转换到 IPv4。服务商没有 NAT64 网关时，只改 DNS 仍然不能访问 IPv4-only 资源。

WARP 可以提供 IPv4 出口，但会修改接口、路由和 DNS，远程操作存在 SSH 失联风险，因此不作为自动安装默认方案。

## 安装方式二：手动下载和运行

如果不想执行一键安装脚本，永久安装最少只需要下面两个文件：

| 文件 | 用途 | 是否必需 |
| --- | --- | --- |
| **xray-manager.sh** | Launcher、自更新和版本显示 | 永久安装必需 |
| **lib/xray-manager-core.sh** | 完整交互菜单和 Xray 管理功能 | 必需 |
| **SHA256SUMS** | 校验文件是否完整 | 推荐 |
| **VERSION** | 查看仓库项目版本 | 可选 |
| **XRAY_VERSION** | R2 与测试共同使用的 Xray 固定版本 | 发布维护 |
| **install.sh** | 私有仓库一键安装器 | 手动安装不需要 |
| **offline-install.sh** | Xray + GeoData 完全离线安装器 | 纯离线首次安装必需 |
| **cloudflare-install.sh** | Worker + 私有 R2 引导脚本 | Cloudflare 安装入口 |

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

### 已安装 Xray 时的安全迁移

如果 VPS 已经安装过 Xray，菜单 `1) 一键安装 / 修复 Xray` 会先读取 systemd / OpenRC 的启动参数，并兼容识别常见的 `/usr/local/etc/xray/config.json` 和 `/etc/xray/config.json`。发现脚本接管前的单文件配置或配置目录时：

1. 连续要求两次确认；任意一次拒绝都会中止安装/修复，不修改配置、服务或 Xray 文件。
2. 将旧配置、当前 Manager 配置目录、Xray 可执行文件和服务定义/状态备份到 `/etc/xray-manager/backups/pre-migration-时间/`。
3. 把旧配置复制到暂存目录，保持原文件不删除，并用当前 Xray 执行 `run -confdir ... -test`。
4. 只有测试通过后才将暂存目录切换为 `/usr/local/etc/xray/conf.d`；原 Manager 目录仍保留为 `/usr/local/etc/xray/conf.d.before-migration-时间`。

迁移结果记录在 `/etc/xray-manager/config_migration.state`，以后再次选择菜单 1 不会重复迁移。v1.4.0 / v1.4.1 已生成 `20-xray-manager-offline.conf`、从而暂时隐藏旧 `config.json` 的机器，也会优先找回并迁移旧配置。

### 4. 只临时运行 Core

不安装 Launcher 也可以直接运行：

~~~bash
sudo bash lib/xray-manager-core.sh
~~~

这种方式可以使用完整管理菜单，但不能直接使用 **xraym --self-update**。以后手动更新时应同时替换 Launcher 和 Core，避免两个文件版本不一致。

## 更新

按安装来源自动选择 GitHub 或 Cloudflare：

```bash
sudo xraym --self-update
```

也可以强制指定：

```bash
sudo xraym --self-update-cloudflare
sudo xraym --self-update-github
```

Cloudflare 更新会再次提示输入安装密钥，密钥不会持久保存。`xraym --self-update` 更新 Launcher 与 Core；Xray-core 和 GeoData 仍通过菜单中的独立功能管理，但通过 Cloudflare 入口安装的机器会自动让这些功能复用同一个 Worker + R2 通道。

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
Cloudflare Worker → 私有 R2 离线包
            ↓ IPv4 / IPv6 鉴权分发
xray-manager.sh
            ↓ Launcher / Cloudflare 或 Private Repo Updater
lib/xray-manager-core.sh
            ↓ 完整 Xray 管理核心
Xray-core / UFW / BBR / 配置文件
```

项目文件：

```text
.
├── xray-manager.sh
├── install.sh
├── cloudflare-install.sh
├── offline-install.sh
├── VERSION
├── XRAY_VERSION
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
│   ├── smoke-configs.sh
│   ├── offline-install.sh
│   └── cloudflare-update.sh
├── .github/workflows/shellcheck.yml
├── .github/workflows/publish-r2.yml
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

`Validate` 工作流执行版本一致性、SHA256、Bash 语法、ShellCheck、已有配置迁移、离线导入和 `XRAY_VERSION` 指定版本的配置冒烟测试。`Publish offline bundles to R2` 使用同一个版本再次运行冒烟测试，成功后才构建并上传 AMD64 / ARM64 离线包。

## License

当前仓库未附加开源许可证，按私有自用项目维护。
