# 使用说明

## 1. 启动

```bash
chmod +x xray-manager.sh
sudo ./xray-manager.sh
```

安装后：

```bash
sudo xraym
```

## 2. 首次安装

选择：

```text
1) 一键安装 / 修复 Xray
```

脚本会：

1. 检测发行版和初始化系统
2. 检测网络条件
3. 在 IPv6-only VPS 上检查 NAT64 / DNS64 / 下载代理
4. 安装基础依赖
5. 调用 XTLS 官方安装器
6. 初始化多文件配置目录
7. 测试配置
8. 启动 Xray
9. 安装 `xraym` 管理命令

## 3. 添加入站

选择：

```text
2) 入站管理
→ 1) 添加入站协议
```

再选择需要的协议。

### VLESS

常用推荐：

```text
VLESS
RAW
REALITY
xtls-rprx-vision
```

REALITY 向导会要求：

- target 域名
- target 端口
- SNI / serverName

并自动生成：

- X25519 PrivateKey
- PublicKey
- ShortID

### TLS

可以：

- 导入已有证书
- 自动通过 acme.sh 签发

## 4. 入站详情、编辑、用户与分享

```text
2) 入站管理
→ 2) 查看入站列表（支持编号选择）
→ 3) 入站详情 / 快捷管理
→ 4) 编辑入站
→ 5) 用户管理
→ 6) 分享链接 / WireGuard 客户端配置与二维码
→ 8) 查看入站原始 JSON
→ 9) 入站健康诊断
```

入站列表同时显示编号、用户模式/数量和来源。每项操作都支持输入数字编号或原有 Tag；选择 `3)` 后可固定当前入站，连续查看用户、分享链接、编辑、查看路由和运行诊断，不需要重复输入 Tag。

`managed` 表示 `conf.d/10_inbound_<tag>.json` 中的受管入站；`external` 表示迁移来的 `00_base.json` 或其他配置文件中的节点。外部入站只读，不会自动移动、拆分或覆盖原配置。

“编辑入站”可以直接修改端口和监听地址。高级 JSON 编辑会打开 `$VISUAL`、`$EDITOR`、`nano` 或 `vi`；仍只允许一个 `InboundObject`，也不允许直接修改 Tag，防止文件名和路由引用失配。

“用户管理”支持：

- VLESS / VMess：UUID/ID、email，VLESS 还可单独设置 Flow
- Trojan：密码、email
- Shadowsocks / SS2022：默认单用户；多用户时只显示真实用户，SS2022 分享密码自动组合为 `ServerPassword:UserPassword`
- Hysteria2：auth、email
- SOCKS5 / HTTP：用户名、密码
- WireGuard：客户端 Peer 名称、公钥、独立隧道地址，支持自动生成或导入已有客户端公钥

每次修改都会先显示 JSON 差异，再测试完整 `conf.d`，随后备份、写入和重启；测试失败不会改正式文件，重启失败会恢复旧文件。除 Shadowsocks 可退回默认主密码外，其余认证协议拒绝删除最后一个用户。

Shadowsocks 没有 `users` 数组时是单用户，可选择 `INDEX 0` 分享顶层密码。添加第一个用户后会提示旧链接失效并切换为多用户；实际用户从 `INDEX 1` 开始，SS2022 的服务器主 PSK 只是共享前缀，不再允许单独分享。删除最后一个附加用户会再次确认并恢复单用户。SS2022 多用户仅支持两个 AES 方法，Chacha20-2022 只能保持单用户。

“分享链接与二维码”需要输入客户端实际连接的域名或 IP。VPS 监听 `0.0.0.0` 或 `::` 时不会把通配地址误写进链接。二维码通过可选的 `qrencode` 在终端显示。链接与二维码都含完整凭据，只应在可信终端使用。

WireGuard 创建入站时可自动生成客户端密钥对和 `10.66.66.x/32` 独立地址，或仅导入已有客户端 `PublicKey`。自动生成的 Peer 可通过 `6)` 导出标准 `[Interface]` / `[Peer]` `.conf` 并生成 WireGuard App 二维码；仅导入公钥的 Peer 不会凭空生成对端私钥，因此不能导出完整配置。服务端 `allowedIPs` 是各客户端的隧道源地址，客户端配置中的 `AllowedIPs` 是需要转发的目标网段。

自动生成的客户端私钥资料保存在 `/etc/xray-manager/wireguard/<tag>/`，目录权限 `700`、文件权限 `600`；现有配置备份与恢复会一并处理。入站详情会显示 `peers/<数量>`，用户管理支持新增、删除、重命名和修改客户端地址，并拒绝重复公钥、重叠 IPv4 网段和删除最后一个 Peer。

“入站健康诊断”会检查完整配置、服务及端口监听、SS2022/WireGuard Base64 密钥、WireGuard Peer 地址、VMess/SS2022 时间同步、路由引用、TLS 证书和 UFW 规则；不会自动修改系统时间、防火墙或路由。

## 5. 查看配置

```text
2) 入站管理
→ 2) 查看入站列表
→ 3) 入站详情 / 快捷管理
→ 8) 查看入站原始 JSON
```

详情摘要默认隐藏凭据。原始配置默认只显示当前入站的脱敏 JSON；明确确认后才显示完整敏感字段，包括：

- UUID
- 密码
- REALITY PrivateKey
- ShortID

不要把输出公开。

## 6. 删除入站

选择：

```text
2) 入站管理
→ 7) 删除入站
```

脚本会：

1. 自动备份
2. 暂时移除目标入站
3. 测试剩余配置
4. 重启 Xray
5. 清理由该入站创建的带 Tag 的 UFW 规则
6. 异常时尝试回滚

## 7. 出站管理

选择：

```text
3) 出站管理
```

常用向导：

- Freedom：自动、强制 IPv4、强制 IPv6、指定源 IP/CIDR
- SOCKS5：可以连接本机 WARP SOCKS 端口
- HTTP Proxy：只支持 TCP
- WireGuard / WARP：手工填写 PrivateKey、客户端地址、Endpoint、服务端 PublicKey，可选 `PresharedKey`、WARP `Reserved` 与 KeepAlive
- 导入标准 WireGuard / WARP `.conf`：文件路径或终端粘贴，自动识别 `[Interface]` / `[Peer]`、双栈地址、`PresharedKey`、MTU 和 `PersistentKeepalive`
- Shadowsocks
- 自定义 `OutboundObject` JSON

导入入口：

```text
3) 出站管理
→ 1) 添加出站
→ 7) 导入标准 WireGuard / WARP .conf
```

粘贴导入时，单独输入 `END` 结束。导入不会执行 `.conf` 里的 `PostUp` 等宿主机命令，也不会改写系统 DNS 或默认路由。服务端公钥必须由服务端提供；客户端私钥如使用 `auto` 自动生成，需要将对应公钥预先登记到自建服务端，不能直接替代已注册的 WARP 密钥。

新增出站保存在：

```text
/usr/local/etc/xray/conf.d/20_outbound_<tag>_tail.json
```

`tail` 是 Xray 多文件配置的特殊标记，确保新增出站追加到末尾，不会意外成为默认出站。

删除出站前会检查路由、链式出站和 `dialerProxy` 引用；仍被引用时拒绝删除。

## 8. 路由与分流

选择：

```text
4) 路由与分流
```

支持常用服务预设、`geosite:`、`geoip:`、CIDR、入站 Tag、IPv4/IPv6 全局目标、广告/BT 拦截和最终默认出口。

路由从上到下匹配，第一条命中后停止。可在菜单中查看顺序并上下移动。最终默认规则会自动保持在最后。

管理器路由文件：

```text
/usr/local/etc/xray/conf.d/30_routing.json
```

如果其他 JSON 已包含 `routing`，菜单会显示冲突文件并停止，不会自动覆盖迁移来的规则。

## 9. 端口转发

选择：

```text
5) 端口转发
```

依次选择：

1. 公网 IPv4、公网 IPv6、仅本机或自定义监听地址
2. 监听端口
3. TCP、UDP 或 TCP+UDP
4. 目标域名/IP和目标端口
5. `direct` 或其他已配置出站

如果选择非 `direct` 出站，脚本会创建基于入站 Tag 的路由规则。删除该端口转发时，会同步清理脚本创建的关联路由。

端口转发不带认证和加密，也不保证保留客户端源 IP。公网监听应仅开放确实需要的端口。

## 10. 更新 Xray Manager

```bash
sudo xraym --self-update
```

通过 Cloudflare 安装时会继续使用 Worker + 私有 R2，并再次提示安装密钥；通过 GitHub 安装时继续使用 Fine-grained PAT。也可用 `--self-update-cloudflare` 或 `--self-update-github` 强制指定。

更新器只接受并严格比较 `MAJOR.MINOR.PATCH` 三段式版本号。升级默认允许；相同版本会要求确认后重装；降级默认拒绝，确需回退时显式执行：

```bash
sudo xraym --self-update --allow-downgrade
```

本地已成功安装过至少两个发布版本时，也可以不重新下载，直接回切上一版：

```bash
sudo xraym --rollback
```

`--rollback` 只接受已经通过最小自检的 `previous` 发布目录，并显示目标版本；再执行一次会切回刚才的 current。

自更新与 Core 中所有会修改系统状态的主菜单操作共用 root-only 全局锁。同一时间只能运行一个此类操作；仍在运行的持锁进程会阻止第二个操作，失效锁仅在确认进程不存在且锁目录结构安全后清理。

## 11. 更新 Xray 与 GeoData

```text
6) 更新 Xray-core
7) 更新 GeoIP / GeoSite
```

## 12. UFW

选择：

```text
10) UFW 防火墙
```

建议第一次使用“安装并安全启用”。

即使脚本会先放行当前 SSH 端口，仍建议保留 VPS 控制台作为应急方案。

## 13. BBR

选择：

```text
11) BBR
```

脚本仅在当前内核支持时启用。

## 14. 日志

选择：

```text
8) Xray 服务 / 配置测试 / 日志
```

可以检查：

- 配置语法
- systemd / OpenRC 服务
- error.log
- access.log
- Xray 版本

## 15. 备份

选择：

```text
9) 备份 / 恢复
```

默认备份目录：

```text
/etc/xray-manager/backups/
```

每份新备份使用不会因同秒操作而冲突的唯一文件名，并包含 Manager/Xray
版本与内容范围清单。恢复前会拒绝绝对路径、未知目录、符号链接及特殊文件，
先在临时目录测试配置，再为当前状态创建安全备份。

正式恢复使用同文件系统内的暂存与回滚目录切换配置、证书和 WireGuard
客户端资料；切换后的完整配置测试或 Xray 重启失败时，会自动恢复操作前
状态并再次启动服务。旧版不含清单的合法备份仍可恢复。
