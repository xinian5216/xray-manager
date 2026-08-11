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

## 4. 查看配置

```text
2) 入站管理
→ 2) 查看入站列表
→ 3) 查看某入站完整配置
```

注意完整配置可能包含：

- UUID
- 密码
- REALITY PrivateKey
- ShortID

不要把输出公开。

## 5. 删除入站

选择：

```text
2) 入站管理
→ 4) 删除入站
```

脚本会：

1. 自动备份
2. 暂时移除目标入站
3. 测试剩余配置
4. 重启 Xray
5. 异常时尝试回滚

## 6. 出站管理

选择：

```text
3) 出站管理
```

常用向导：

- Freedom：自动、强制 IPv4、强制 IPv6、指定源 IP/CIDR
- SOCKS5：可以连接本机 WARP SOCKS 端口
- HTTP Proxy：只支持 TCP
- WireGuard / WARP：需要 PrivateKey、客户端地址、Endpoint、服务端 PublicKey
- Shadowsocks
- 自定义 `OutboundObject` JSON

新增出站保存在：

```text
/usr/local/etc/xray/conf.d/20_outbound_<tag>_tail.json
```

`tail` 是 Xray 多文件配置的特殊标记，确保新增出站追加到末尾，不会意外成为默认出站。

删除出站前会检查路由、链式出站和 `dialerProxy` 引用；仍被引用时拒绝删除。

## 7. 路由与分流

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

## 8. 端口转发

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

## 9. 更新 Xray Manager

```bash
sudo xraym --self-update
```

通过 Cloudflare 安装时会继续使用 Worker + 私有 R2，并再次提示安装密钥；通过 GitHub 安装时继续使用 Fine-grained PAT。也可用 `--self-update-cloudflare` 或 `--self-update-github` 强制指定。

## 10. 更新 Xray 与 GeoData

```text
6) 更新 Xray-core
7) 更新 GeoIP / GeoSite
```

## 11. UFW

选择：

```text
10) UFW 防火墙
```

建议第一次使用“安装并安全启用”。

即使脚本会先放行当前 SSH 端口，仍建议保留 VPS 控制台作为应急方案。

## 12. BBR

选择：

```text
11) BBR
```

脚本仅在当前内核支持时启用。

## 13. 日志

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

## 14. 备份

选择：

```text
9) 备份 / 恢复
```

默认备份目录：

```text
/etc/xray-manager/backups/
```
