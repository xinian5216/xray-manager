# 安装与更新

仓库默认以 **Public** 方式使用：安装和自更新都通过匿名 GitHub API 完成，不需要任何 Token。私有 fork 或更高的 API 速率限制可以把 Token 作为可选项。

## 一键安装（匿名，推荐）

```bash
curl -fsSLo /tmp/xray-manager-install.sh \
  https://raw.githubusercontent.com/xinian5216/xray-manager/main/install.sh &&
sudo bash /tmp/xray-manager-install.sh --run
```

安装脚本会通过匿名 GitHub API 读取 `VERSION`、`SHA256SUMS`、`xray-manager.sh` 与 `lib/xray-manager-core.sh`，校验 SHA256 后事务安装，并安装 `jq`、OpenSSL、`iproute2` 等运行依赖。

匿名 GitHub API 限制为每小时 60 次请求，一次安装约使用 4 次。若遇到速率限制或使用私有 fork，可设置可选 Token：

```bash
export XRAY_MANAGER_GITHUB_TOKEN="<Fine-grained PAT>"
```

Token 只作为 `Authorization` 头发送给 `api.github.com`，不会写入磁盘、不会出现在日志、不会拼进 URL，也不会发送给第三方镜像。

## 从源码手动安装

```bash
git clone https://github.com/xinian5216/xray-manager.git
cd xray-manager
bash install.sh --run
```

## 默认安装路径

```text
Launcher: /usr/local/sbin/xraym -> .../current/xray-manager.sh
Core:     /usr/local/lib/xray-manager/xray-manager-core.sh
          -> .../current/xray-manager-core.sh
Releases: /usr/local/lib/xray-manager/releases/<version>/
Current:  /usr/local/lib/xray-manager/current
Previous: /usr/local/lib/xray-manager/previous
```

## 更新

```bash
sudo xraym --self-update
```

更新流程：

1. 获取仓库 `VERSION`（匿名或可选 Token）。
2. 下载 `SHA256SUMS`、Launcher 和原始 Core 并校验 SHA256。
3. 在本地为 Core 应用 Launcher 兼容补丁，防止 Core 覆盖 Launcher。
4. 对 Launcher 与 Core 执行 `bash -n`。
5. 将两者写入同一 `releases/<version>/` 目录，校验后再原子切换 `current`。
6. 失败时保留原 current；需要时用 `xraym --rollback` 切回 previous。

版本策略：升级默认允许；相同版本要求确认后重装；降级默认拒绝，确需回退时：

```bash
sudo xraym --self-update --allow-downgrade
sudo xraym --rollback
```

## IPv6-only 与下载代理

若 GitHub 链路不可达，可以给 bootstrap 或菜单指定 IPv6 可达的 HTTP / SOCKS5 代理：

```bash
bash /tmp/xray-manager-install.sh --proxy 'socks5h://[2001:db8::1]:1080' --run
```

或：

```bash
export XRAY_DOWNLOAD_PROXY='http://[2001:db8::1]:8080'
```

主菜单 `13) IPv6-only / NAT64 网络助手` 也可以交互设置并保存该代理。代理是用户自行选择的传输层，不是项目的信任根。

## 完全离线安装

无法访问 GitHub 时，使用 `offline-install.sh` 从本地上传的 Xray ZIP、`geoip.dat` 与 `geosite.dat` 完成安装，全程不访问网络。详见 README「完全手动离线导入」。
