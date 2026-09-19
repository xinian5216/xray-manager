# Private Repository 一键安装

本仓库保持 Private。在线安装只有一个来源：GitHub API + Fine-grained PAT。

## GitHub API + Fine-grained PAT

使用只绑定 `xray-manager`、仅授予 `Contents: Read-only` 的 Fine-grained PAT。

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

## 更新

```bash
sudo xraym --self-update
```

更新流程：

1. 获取仓库 `VERSION`。
2. 下载 `SHA256SUMS`、Launcher 和原始 Core 并校验 SHA256。
3. 在本地为 Core 应用 Launcher 兼容补丁，防止 Core 覆盖 Launcher。
4. 对 Launcher 与 Core 执行 `bash -n`。
5. 安装/检查 `jq`、OpenSSL、`iproute2` 等运行依赖。
6. 将 Launcher 与 Core 写入同一 `releases/<version>/` 目录，校验后再原子切换 `current`。
7. 失败时保留原 current；需要时用 `xraym --rollback` 切回 previous。

## GitHub 方式的 IPv6-only 注意事项

若 GitHub API 可通过原生 IPv6 访问，可直接安装。若 GitHub 链路不可达，可以给 bootstrap 指定 IPv6 可达的 HTTP / SOCKS5 代理：

```bash
bash /tmp/xray-manager-install.sh \
  --proxy 'socks5h://[IPv6地址]:1080' \
  --run
```

如果 VPS 既无法访问 GitHub，又没有 NAT64 或任何 IPv6 可达代理，在线 bootstrap 无法取得私有仓库文件。

此时需要手动上传完整离线包，并使用 `offline-install.sh` 完成纯离线安装（见 README「完全手动离线导入」）。
