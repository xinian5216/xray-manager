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
2) 添加入站协议
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
3) 查看入站列表
4) 查看某入站完整配置
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
5) 删除入站
```

脚本会：

1. 自动备份
2. 暂时移除目标入站
3. 测试剩余配置
4. 重启 Xray
5. 异常时尝试回滚

## 6. 更新 Xray Manager

```bash
sudo xraym --self-update
```

通过 Cloudflare 安装时会继续使用 Worker + 私有 R2，并再次提示安装密钥；通过 GitHub 安装时继续使用 Fine-grained PAT。也可用 `--self-update-cloudflare` 或 `--self-update-github` 强制指定。

## 7. 更新 Xray 与 GeoData

```text
6) 更新 Xray-core
7) 更新 GeoIP / GeoSite
```

## 8. UFW

选择：

```text
8) UFW 防火墙
```

建议第一次使用“安装并安全启用”。

即使脚本会先放行当前 SSH 端口，仍建议保留 VPS 控制台作为应急方案。

## 9. BBR

选择：

```text
9) BBR
```

脚本仅在当前内核支持时启用。

## 10. 日志

选择：

```text
11) Xray 服务 / 配置测试 / 日志
```

可以检查：

- 配置语法
- systemd / OpenRC 服务
- error.log
- access.log
- Xray 版本

## 11. 备份

选择：

```text
12) 备份 / 恢复
```

默认备份目录：

```text
/etc/xray-manager/backups/
```
