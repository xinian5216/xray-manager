# Private Repository 一键安装

本仓库保持 Private。可以使用 Cloudflare 私有分发安装，也可以直接通过 GitHub API + Fine-grained PAT 安装。

## Cloudflare Worker + 私有 R2

纯 IPv6、IPv4 和双栈 VPS 均可使用：

```bash
curl -fsSLo /tmp/xray-manager-install.sh \
  https://xray-manager-download.xinian5216.workers.dev/install.sh &&
sudo bash /tmp/xray-manager-install.sh
```

输入的是 Worker 的独立 `INSTALL_TOKEN`，不是 GitHub PAT。公开入口只返回引导脚本，AMD64 / ARM64 完整安装包保存在私有 R2，必须经过 Worker 鉴权。

引导脚本会通过系统软件源一并安装 `jq`、OpenSSL、`unzip`、`iproute2` 等运行依赖；执行入口前仍需具备 `curl` 与 `tar`。

通过此方式安装后，管理器会记录更新来源：

```bash
sudo xraym --self-update
```

更新时再次输入安装密钥，密钥不会保存到 VPS 配置。

## GitHub API + Fine-grained PAT

GitHub API 可达时，推荐使用只绑定 `xray-manager`、仅授予 `Contents: Read-only` 的 Fine-grained PAT。

### 一次粘贴版

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

Token 不会直接出现在命令历史中，输入时也不会回显。

仓库是 Private，直接访问 `raw.githubusercontent.com/.../install.sh` 或不带 Token 请求 GitHub API 会返回 `404`。如果带 Token 的命令仍返回 `404`，通常是 PAT 没有选择本仓库、权限不是 `Contents: Read-only`、Token 已失效，或指定的 ref 不存在。

## 默认安装路径

```text
Launcher: /usr/local/sbin/xraym -> .../current/xray-manager.sh
Core:     /usr/local/lib/xray-manager/xray-manager-core.sh
          -> .../current/xray-manager-core.sh
Releases: /usr/local/lib/xray-manager/releases/<version>/
Current:  /usr/local/lib/xray-manager/current
Previous: /usr/local/lib/xray-manager/previous
```

## 强制指定更新来源

```bash
sudo xraym --self-update
sudo xraym --self-update-cloudflare
sudo xraym --self-update-github
```

更新流程：

1. 获取 `VERSION`。
2. GitHub：下载 `SHA256SUMS`、Launcher 和原始 Core 并校验 SHA256。
   Cloudflare：下载对应架构 tar、sidecar `.sha256` 和 `releases/manifest.json`，要求包摘要与外层清单一致。
3. Cloudflare 解压后还要求内嵌 `release-manifest.json` 的 `manager_version` 与 `VERSION` 一致。
4. 在本地为 Core 应用 Launcher 兼容补丁，防止 Core 覆盖 Launcher。
5. 对 Launcher 与 Core 执行 `bash -n`。
6. 安装/检查 `jq`、OpenSSL、`iproute2` 等运行依赖。
7. 将 Launcher 与 Core 写入同一 `releases/<version>/` 目录，校验后再原子切换 `current`。
8. 失败时保留原 current；需要时用 `xraym --rollback` 切回 previous。

## GitHub 方式的 IPv6-only 注意事项

若 GitHub API 可通过原生 IPv6 访问，可直接安装。若 GitHub 链路不可达，可以给 bootstrap 指定 IPv6 可达的 HTTP / SOCKS5 代理：

```bash
bash /tmp/xray-manager-install.sh \
  --proxy 'socks5h://[IPv6地址]:1080' \
  --run
```

如果 VPS 既无法访问 GitHub，又没有 NAT64 或任何 IPv6 可达代理，在线 bootstrap 无法取得私有仓库文件。

此时应使用本文开头的 Cloudflare 入口；只有 Worker 也不可达时，才需要手动上传完整离线包。
