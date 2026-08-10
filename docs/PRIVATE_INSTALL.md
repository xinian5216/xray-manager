# Private Repository 一键安装

本仓库是 Private Repository，匿名 raw 下载不会成功。

Fine-grained PAT 建议仅授权：`xray-manager` → `Contents: Read-only`。

## 一次粘贴版

```bash
read -rsp "GitHub Token: " GH_TOKEN; echo; export GH_TOKEN; \
curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github.raw+json" -H "X-GitHub-Api-Version: 2022-11-28" \
"https://api.github.com/repos/xinian5216/xray-manager/contents/install.sh?ref=main" -o /tmp/xray-manager-install.sh && \
bash /tmp/xray-manager-install.sh --run; rc=$?; rm -f /tmp/xray-manager-install.sh; unset GH_TOKEN; exit $rc
```

安装器会下载 Launcher、Core 与 `SHA256SUMS`，通过 SHA256 和 `bash -n` 后才安装。

默认路径：
- Launcher: `/usr/local/sbin/xraym`
- Core: `/usr/local/lib/xray-manager/xray-manager-core.sh`

## 自更新

```bash
sudo xraym --self-update
```

## IPv6-only

可通过 `XRAY_DOWNLOAD_PROXY` 或 `--proxy` 指定 IPv6 可达的 HTTP/SOCKS5 代理。如果 VPS 既无法访问 GitHub，又没有 NAT64 或代理，在线 bootstrap 无法取得私有仓库内容。

Token 默认不会保存到 VPS。
