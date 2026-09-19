# Xray Manager

一个面向常用 Linux VPS 的交互式 Xray 安装与管理项目，兼顾 IPv4、双栈和 IPv6-only VPS。

> 当前项目版本：**v1.8.4** · Core：**v1.8.4**

## 核心功能

- Xray-core 安装 / 修复 / 更新
- GeoIP / GeoSite 更新
- VLESS、VMess、Trojan、Shadowsocks、Hysteria2
- 编号选择入站、人类可读详情中心、迁移/外部入站只读发现与快捷管理
- 入站端口/监听地址编辑、完整 Inbound JSON 高级编辑
- VLESS、VMess、Trojan、Shadowsocks、Hysteria2、SOCKS/HTTP、WireGuard 用户/Peer 增删改查
- VLESS、VMess、Trojan、Shadowsocks、Hysteria2、SOCKS/HTTP 分享链接与终端二维码
- SOCKS5、HTTP Proxy、WireGuard Inbound、Tunnel、TUN
- WireGuard 双端密钥生成、独立客户端地址、完整 `.conf` 配置导出与手机扫码
- Freedom IPv4/IPv6、SOCKS5、HTTP、Shadowsocks、WireGuard/WARP 出站管理及标准 `.conf` 导入
- GeoSite、GeoIP、CIDR、入站、IPv4/IPv6 与常用服务路由分流
- 路由规则查看、删除、优先级调整、默认出口与自定义 RuleObject
- TCP、UDP、TCP+UDP 端口转发，可选择公网/本机监听及指定出站
- RAW、XHTTP、gRPC、WebSocket、HTTPUpgrade、mKCP
- REALITY / TLS / 自定义 SNI 与 target
- REALITY 共享 CDN target 风险检测、随机化回落限速
- 入站健康诊断：监听、服务、SS2022/WireGuard 密钥、NTP、关联路由、TLS 证书与 UFW
- UFW、BBR、日志、配置测试、备份恢复
- 备份内置版本清单与唯一文件名；恢复前拒绝危险归档，服务异常时自动切回原配置
- IPv6-only、NAT64 / DNS64、IPv6 可达下载代理
- 单一在线来源：私有 GitHub 仓库安装与自更新，Xray Core 来自 XTLS/Xray-core Releases
- `XRAY_DOWNLOAD_PROXY` 支持 HTTP / HTTPS / SOCKS5 / SOCKS5H 下载代理
- 完全离线导入 Xray ZIP、GeoIP 与 GeoSite
- 已有 Xray 配置安全迁移、双重确认和迁移前完整备份
- 主菜单直接更新 Xray Manager Launcher 与 Core
- Manager 自更新原子切换 current/previous，失败自动回滚，支持 `xraym --rollback`

## 快速安装

在线安装只有一个来源：私有 GitHub 仓库。

创建只针对 `xray-manager`、仅授予 `Contents: Read-only` 的 Fine-grained PAT：

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

仓库是 Private，直接访问 `raw.githubusercontent.com/.../install.sh` 或不带 Token 请求 API 会返回 `404`，这是 GitHub 隐藏私有仓库的正常行为。如果上面的命令也返回 `404`，请检查 PAT 是否确实选择了 `xray-manager`、仍在有效期内，并具有 `Contents: Read-only` 权限。

这种方式的安装和后续 `xraym --self-update` 都需要能够访问 `api.github.com`，或者设置 `XRAY_DOWNLOAD_PROXY`。PAT 只在本次下载使用，不会持久化、不会写入日志、也不会拼进 URL。

安装后，主菜单 `1) 安装 / 修复 Xray`、`6) 更新 Xray-core` 和 `7) 更新 GeoData` 都直接从 XTLS 官方 GitHub Release 获取资源，并支持在菜单里选择 Xray Core 版本（见下文）。

## 纯 IPv6 VPS：其他备用方式

如果 GitHub API 无法访问，可以设置 `XRAY_DOWNLOAD_PROXY`、使用真正的手动离线导入，或借助另一台双栈 VPS 建立临时代理。

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

该流程不会调用网络下载或包管理器，因此必须事先安装 `jq`、OpenSSL、`iproute2`、`procps`、`tar`、`gzip`、`coreutils`，以及 `unzip`、`bsdtar`、Python 3 中至少一种 ZIP 读取工具。已经安装 `xraym` 时，也可在主菜单选择：

```text
14) 完全离线安装 / 导入 Xray + GeoData
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
| **XRAY_VERSION** | CI 使用的 Xray Core 测试基准版本 | 发布维护 |
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
sudo install -d -m 755 /usr/local/lib/xray-manager/releases/manual
sudo install -m 755 xray-manager.sh \
  /usr/local/lib/xray-manager/releases/manual/xray-manager.sh
sudo install -m 755 lib/xray-manager-core.sh \
  /usr/local/lib/xray-manager/releases/manual/xray-manager-core.sh
sudo ln -sfn /usr/local/lib/xray-manager/releases/manual \
  /usr/local/lib/xray-manager/current
sudo ln -sfn /usr/local/lib/xray-manager/current/xray-manager.sh \
  /usr/local/sbin/xraym
sudo ln -sfn /usr/local/lib/xray-manager/current/xray-manager-core.sh \
  /usr/local/lib/xray-manager/xray-manager-core.sh
sudo xraym
~~~

推荐优先使用 `install.sh` / `offline-install.sh`：它们会把 Launcher 与 Core 写入同一发布目录，再原子切换 `current`，并在失败时保留原版本。手工复制两个文件到固定路径仍然能启动，但没有 `previous` 回滚点。

首次进入菜单后选择 **1) 一键安装 / 修复 Xray**。这里的“一键”只负责安装官方 Xray-core 和系统服务，不会重新下载 Xray Manager 项目。

### 已安装 Xray 时的安全迁移

如果 VPS 已经安装过 Xray，菜单 `1) 一键安装 / 修复 Xray` 会先读取 systemd / OpenRC 的启动参数，并兼容识别常见的 `/usr/local/etc/xray/config.json` 和 `/etc/xray/config.json`。旧 Xray 即使安装在 `/usr/bin/xray` 等非 Manager 路径，也会使用服务当前实际调用的二进制完成迁移校验。发现脚本接管前的单文件配置或配置目录时：

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

`xraym --self-update` 只有一种行为：从私有 GitHub 仓库安全更新 Launcher + Core。

```bash
sudo xraym --self-update
```

更新会先读取仓库 `VERSION`，按版本策略确认后下载 `SHA256SUMS`、`xray-manager.sh` 与 `lib/xray-manager-core.sh`，校验 SHA256、执行 `bash -n`、应用兼容补丁并原子切换 `current`；Token 只在本次使用，不会落盘。Xray-core 和 GeoData 仍通过菜单中的独立功能管理，并且都只使用各自官方的 GitHub Release。

更新器严格比较 `MAJOR.MINOR.PATCH` 三段式版本号：默认允许升级；相同版本会要求确认后重装；降级默认拒绝。确需回退时必须显式执行：

```bash
sudo xraym --self-update --allow-downgrade
sudo xraym --rollback
```

`--rollback` 只切换到本机已经校验过的上一发布版本，不会重新下载；连续执行会在 current 与 previous 之间切换。

Launcher 自更新和 Core 中所有会修改系统状态的主菜单操作共用一个 root-only 全局锁。同一时间只允许一个操作运行；若已有操作仍在执行，新操作会显示持锁进程并安全退出。崩溃遗留的锁会在确认持锁进程已不存在且锁目录结构安全后自动清理。

不想记命令时，可直接在主菜单选择：

```text
16) 更新 Xray Manager 脚本
```

它会调用 Launcher 的同一套 GitHub 自更新逻辑；完成后可以立即重新载入新版菜单。

### GitHub 来源下的 Xray Core 版本选择

通过 GitHub 安装或更新 Xray-core 时，主菜单 `1) 一键安装 / 修复 Xray` 与 `6) 更新 Xray-core` 都会先显示版本选择：

```text
========== Xray Core 版本选择 ==========

当前版本      : v26.7.28
最新发布版    : v26.9.9 [Pre-release]
最新稳定版    : v26.3.27 [Stable]

1) 最新发布版 [默认]
2) 最新稳定版
3) 选择历史版本
4) 手动输入版本
0) 取消
```

- **最新发布版（默认）**：GitHub Releases 中最新发布、非 Draft、并且包含当前 CPU 架构 ZIP 资产的版本，允许 `prerelease=true`。注意它并不等于 GitHub `/releases/latest`，后者只跟踪最新 Stable Release。
- **最新稳定版**：`draft=false` 且 `prerelease=false` 的最新版本。
- **选择历史版本**：列出最近 15 个可安装 Release，显示发布日期与 `Stable` / `Pre-release`，编号选择；非法编号会重新提示。
- **手动输入版本**：接受 `26.9.9` 或 `v26.9.9`，只接受严格 `vX.Y.Z` 三段格式，并会向 GitHub API 验证该 Release 与当前架构 ZIP 确实存在，不会把输入直接拼接进命令或 URL。

选择 Pre-release 会再次确认。目标版本低于当前版本时识别为降级，默认拒绝；相同版本会询问是否重装。版本比较按数字逐段进行，`v26.10.0` 大于 `v26.9.9`。

更新前会把当前 `/usr/local/bin/xray` 备份到 `/etc/xray-manager/backups/xray-core-时间/`。安装后必须依次通过“新二进制可执行 → `xray run -confdir ... -test` → 服务重启并进入运行状态”检查；任一步失败会自动恢复旧 Core 并重新启动，只有全部成功才显示 `Xray 更新完成`。

Alpine/OpenRC 下官方 Alpine 安装器不支持 `--version`，管理器会直接下载对应 Release 的官方 ZIP，校验 GitHub API `digest` 与官方 `.dgst` 的 SHA256（两者都存在时必须一致）后，复用离线导入流程安装，不会裸覆盖 `/usr/local/bin/xray`。

其他 CPU 架构（例如 arm32）没有可筛选的 Release 资产时，安装/更新会保持原来的官方安装器默认版本行为，仍然先备份并保留配置测试失败时的自动回滚。

GitHub API 超时、限额或返回异常时，菜单会提供“重试 / 手动输入版本 / 返回”；手动输入同样需要验证 Release 元数据，验证不了就不会盲目下载安装。所有 GitHub 请求都会使用已配置的 `XRAY_DOWNLOAD_PROXY`。

`XRAY_VERSION` 只是 CI 使用的 Xray Core 测试基准版本（同时用于真实配置 smoke test），不限制 GitHub 在线安装用户能选择的版本。

### GeoData 更新

主菜单 `7) 更新 GeoIP / GeoSite` 调用 XTLS 官方安装器更新 `geoip.dat` / `geosite.dat`；Alpine/OpenRC 会连同 Xray 一起更新。完全离线环境可在菜单 `14)` 中导入本地 GeoData。

查看项目 / Core 版本：

```bash
xraym --version
```

## 入站详情、编辑、用户与分享

主菜单选择：

```text
2) 入站管理
```

v1.8.0 的入站列表会同时显示编号、Tag、协议、监听地址/端口、传输安全、用户或 WireGuard Peer 数量和配置来源：

```text
INDEX TAG             PROTOCOL      LISTEN      PORT TRANSPORT SECURITY USERS     SOURCE
1     ss-home         shadowsocks   ::          8388 native    -        single/1  managed
2     vless-phone     vless         0.0.0.0     443  raw       reality  users/2   managed
3     old-node        shadowsocks   0.0.0.0     9443 native    -        multi/2   external
```

所有入站操作均可输入编号或 Tag。`managed` 是管理器创建的独立配置，`external` 是从已有 Xray 配置迁移过来的节点或其他 JSON 中的入站；外部入站只允许查看详情、原始配置、路由和诊断，不会被静默改写。

- `3) 入站详情 / 快捷管理`：查看人类可读摘要，选择一次后直接进入用户、分享、编辑、路由、诊断和删除操作。
- `4) 编辑入站`：交互修改监听端口或监听地址；高级模式用终端编辑器修改完整单个 `InboundObject`。
- `5) 用户管理`：查看、添加、编辑和删除协议用户；拒绝删除需要认证的最后一个用户。
- `6) 分享链接 / WireGuard 客户端配置与二维码`：按用户生成导入链接，或导出完整 WireGuard 客户端 `.conf`，可用 `qrencode` 直接在终端显示二维码。
- `8) 查看入站原始 JSON`：默认只输出当前入站的脱敏配置；查看完整私钥和密码必须再次确认。
- `9) 入站健康诊断`：检查配置、服务、监听端口、SS2022/WireGuard 密钥、Peer 地址、NTP、关联路由、TLS 证书和已启用的 UFW。

所有受管入站仍是普通的 `conf.d/10_inbound_<tag>.json`。WireGuard 自动生成的客户端私钥与导出资料单独保存在 root-only 的 `/etc/xray-manager/wireguard/<tag>/`，并随配置备份一起保存和恢复。修改前会显示 JSON 差异，Tag 不允许在编辑器内直接改名；确认后执行“临时目录测试完整配置 → 自动备份 → 替换 → 重启”，测试或重启失败时不保留错误配置。

用户管理覆盖 VLESS、VMess、Trojan、Shadowsocks（含 SS2022 多用户）、Hysteria2、密码 SOCKS5、HTTP Proxy 和 WireGuard Peer。Tunnel、TUN 以及自定义冷门协议没有统一用户模型，应使用高级 JSON 编辑。

### WireGuard 入站与客户端

创建 WireGuard 入站时，服务端私钥与公钥会自动成对生成。客户端可选择：

1. **自动生成客户端密钥对**：分配独立隧道地址，保存完整客户端配置，后续可在 `分享链接 / WireGuard 客户端配置与二维码` 中查看或扫码。
2. **导入已有客户端 PublicKey**：适用于手机或其他设备已经创建密钥的情况；管理器只保存对端公钥，无法导出它从未获得的客户端私钥。

默认每个客户端使用独立的 `10.66.66.x/32`，可以手动添加 IPv6 地址。服务端 Peer 的 `allowedIPs` 表示该客户端允许使用的隧道源地址，不应给多个客户端同时配置 `0.0.0.0/0,::/0`；客户端 `.conf` 中的 `AllowedIPs` 则表示通过隧道转发的目标网段，两者含义不能混淆。

自动生成的配置形式为：

```ini
[Interface]
PrivateKey = 客户端私钥
Address = 10.66.66.2/32
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = 服务端公钥
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

服务端私钥不会在创建结果中显示；客户端配置和二维码包含客户端私钥，只有明确确认后才显示。客户端资料目录权限为 `700`，文件权限为 `600`，并纳入现有 root-only 备份与恢复。WireGuard 直接作为跨境外层时协议特征明显，不适合替代具有伪装能力的 REALITY 等传输。

Shadowsocks 默认是单用户，`INDEX 0` 对应可直接连接的顶层密码。添加第一个用户后会切换为多用户：旧单用户链接失效，实际用户从 `INDEX 1` 开始。对 SS2022，顶层密码变成服务器主 PSK，不再是独立用户，客户端密码必须是 `ServerPassword:UserPassword`。当前 Xray 只支持 `2022-blake3-aes-128-gcm` 和 `2022-blake3-aes-256-gcm` 的 SS2022 多用户；`2022-blake3-chacha20-poly1305` 保持单用户。删除最后一个附加用户会恢复单用户模式，并再次提示现有链接失效。

新建的 UFW 放行规则带 `XrayManager:<tag>:<protocol>` 标识。修改端口或删除入站时只会清理这个入站由管理器创建的规则，不会碰用户手动添加的规则或旧版本的通用 `Xray` 规则。

链接生成支持 VLESS、Trojan、SIP002 Shadowsocks、Hysteria2、SOCKS/HTTP URI；VMess 生成兼容常见客户端的 Base64 JSON 链接。REALITY 链接会从服务端私钥推导客户端 `pbk/password`，不会把私钥写进链接。脚本会要求手动确认客户端连接域名/IP，避免把 `0.0.0.0`、`::` 或错误探测地址写进节点。

分享链接和二维码包含完整 UUID、密码或认证值，任何拿到的人都可以使用节点。脚本只在明确确认后显示；不要截图、录屏、贴到工单或公开聊天中。`qrencode` 不存在时会先征求同意再安装，也可以跳过二维码、只复制链接。

## REALITY 回落流量保护

REALITY 会把未通过认证的连接转发到 `target` 以维持正常 TLS 站点的外观。因此即使攻击者没有 UUID，仍可能通过扫描消耗 VPS 与 `target` 之间的回落流量；共享 CDN target 的风险尤其高。

项目创建 REALITY 入站时会：

1. 检查常见共享 CDN 域名、CNAME 和 HTTPS 响应头；发现高风险目标时要求再次确认。
2. 提供随机化的 `limitFallbackUpload` / `limitFallbackDownload`“流量保护”和“隐蔽平衡”两档，也允许选择完全不限速。
3. 查看入站详情时默认隐藏 UUID、Short ID、密码和 REALITY 密钥。
4. 将 `/etc/xray-manager` 与其中备份限制为 root-only。

检测属于启发式判断，不能保证识别所有套了 CDN 的自定义域名。最稳妥的方案仍是自己的域名配合本机 Web 服务，或者同 ASN、非共享 CDN、资源体积较小的普通目标站。如果采用“偷自己”，应让本机 Web 服务监听另一个端口（例如 `127.0.0.1:8443`）并提供自有域名证书；不要让 target 再指回 Xray 正在监听的同一个公网端口，否则会形成回环。

回落限速按单连接生效，攻击者可以通过并发连接部分绕过；限速行为本身也可能形成额外特征。因此它是止损措施，不能替代安全的 target 选择。即使 target 被判定为高风险，用户仍可在阅读警告并再次确认后关闭限速，最终选择权由用户保留。

## 出站与路由管理

主菜单提供：

```text
3) 出站管理
4) 路由与分流
```

常用出站向导包括：

- Freedom 自动、强制 IPv4、强制 IPv6 及指定源 IP/CIDR
- SOCKS5（适合连接本机 WARP 代理）
- HTTP Proxy（仅 TCP）
- WireGuard / WARP 手动配置及标准 `.conf` 导入，支持 `PresharedKey`、IPv6、`PersistentKeepalive` 和 WARP `Reserved`；默认使用 userspace TUN，避免容器权限和路由表冲突
- Shadowsocks
- 自定义单个 `OutboundObject` JSON

标准 WireGuard 配置可在 `3) 出站管理 → 1) 添加出站 → 7) 导入标准 WireGuard / WARP .conf` 中通过文件路径或直接粘贴导入。服务端 `PublicKey` 必须来自现有服务端；如果手动选择自动生成客户端私钥，必须先把对应客户端公钥登记到对端。WARP 账号不能直接使用未注册的随机客户端密钥。`.conf` 中的 `DNS` 不会改写宿主机 DNS，Xray 仍使用自己的 DNS 配置。

脚本创建的出站使用 `20_outbound_<tag>_tail.json`。文件名必须保留 `tail`，否则 Xray 多文件合并可能把新出站插入最前并意外改变默认出口。

路由统一保存在 `30_routing.json`，支持：

- Google、Telegram、OpenAI、Netflix、YouTube 常用服务预设
- 域名、`geosite:`、IP、CIDR、`geoip:` 分流
- 指定入站、全部 IPv4、全部 IPv6 分流
- 中国大陆域名/IP 直连、广告和 BitTorrent 拦截
- 最终默认出口
- 查看、删除、上下移动规则
- 自定义单个 `RuleObject` JSON

规则按显示顺序从上到下匹配，命中第一条后停止；最终默认规则始终保持在最后。每次写入都会先在临时目录测试完整配置，再备份、写入和重启，失败时自动回滚。

如果迁移进来的其他 JSON 已经包含顶层 `routing`，管理器会拒绝自动接管并显示冲突文件，避免把已有复杂规则静默覆盖。

## 端口转发

主菜单选择：

```text
5) 端口转发
```

可配置：

- 公网 IPv4、公网 IPv6、仅本机或自定义监听地址
- TCP、UDP、TCP+UDP
- 监听端口、目标域名/IP、目标端口
- `direct` 或任意已配置出站
- 查看和删除现有转发

公网监听时，如果 UFW 已启用，会按所选协议放行 TCP、UDP 或两者。端口转发本身不提供身份认证或加密，目标端看到的通常是 VPS/所选出站的源地址，不适合代替需要保留客户端源 IP 的 DNAT。

## 维护与故障定位

仓库提供面向维护者的可搜索导航。AI 第一次接触请用 `--ai` 或 [docs/ai/INDEX.md](docs/ai/INDEX.md)，只打开返回的行号切片，不要通读 Core：

```bash
bash scripts/maintainer-map.sh --ai "路由规则顺序"
bash scripts/maintainer-map.sh --ai "SS2022 用户"
bash scripts/maintainer-map.sh --ai "IPv6 下载"
```

路径、职责或 Core 簇锚点调整后执行 `bash scripts/maintainer-map.sh --write-index && bash scripts/maintainer-map.sh --check`，Validate 工作流也会自动阻止失效映射合并。维护前请先看 [维护与故障定位指南](docs/MAINTAINER_GUIDE.md)；仓库级自动化维护规则见 [AGENTS.md](AGENTS.md)。

## 架构

```text
私有 GitHub 仓库（install.sh / 自更新）
            ↓ HTTPS + Fine-grained PAT / XRAY_DOWNLOAD_PROXY
xray-manager.sh
            ↓ Launcher / GitHub Updater
lib/xray-manager-core.sh
            ↓ 完整 Xray 管理核心
Xray-core / UFW / BBR / 配置文件
```

项目文件：

```text
.
├── xray-manager.sh
├── install.sh
├── offline-install.sh
├── VERSION
├── XRAY_VERSION
├── SHA256SUMS
├── lib/
│   └── xray-manager-core.sh
├── docs/
│   ├── USAGE.md
│   ├── MAINTAINER_GUIDE.md
│   ├── IPV6_ONLY.md
│   ├── PRIVATE_INSTALL.md
│   └── ai/                      # generated AI first-contact index
│       ├── INDEX.md
│       └── core-symbols.tsv
├── scripts/
│   ├── maintainer-map.sh
│   ├── refresh-checksums.sh
│   └── verify-xray-asset.sh
├── tests/
│   ├── inbound-management.sh
│   ├── smoke-configs.sh
│   ├── offline-install.sh
│   ├── xray-version-select.sh
│   └── xray-asset-integrity.sh
├── .github/workflows/shellcheck.yml
├── README.md
├── AGENTS.md
├── CLAUDE.md
├── CHANGELOG.md
├── SECURITY.md
├── CONTRIBUTING.md
└── .gitignore
```

## 安装与更新安全

1. 先下载 `SHA256SUMS`、Launcher 与原始 Core，再校验 SHA256。
2. 确认 Core 使用独立安装路径，不覆盖 `/usr/local/sbin/xraym`；安装器仍保留对旧版 Core 的兼容补丁。
3. 对 Launcher 与补丁后的 Core 执行 `bash -n`。
4. 全部通过后才写入 `releases/<version>/`，原子切换 `current`；失败时保留原 current。

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

`Validate` 工作流执行版本一致性、SHA256、Bash 语法、ShellCheck、菜单自更新、已有配置迁移、事务化备份恢复、原子发布、上游资产完整性、Xray 版本选择（解析、Stable/Pre-release 筛选、降级保护、安装参数与失败回滚）、离线导入和真实 Xray 配置 smoke test。

## License

当前仓库未附加开源许可证，按私有自用项目维护。
