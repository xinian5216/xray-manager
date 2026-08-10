# Private Repository 一键安装

本仓库为 Private Repository，匿名 raw 下载不会成功。推荐使用只绑定 `xray-manager` 的 Fine-grained PAT，并只授予 `Contents: Read-only`。

## 一次粘贴版

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

## 默认安装路径

```text
Launcher: /usr/local/sbin/xraym
Core:     /usr/local/lib/xray-manager/xray-manager-core.sh
```

## 更新

```bash
sudo xraym --self-update
```

更新流程：

1. 获取 `VERSION`。
2. 下载 `SHA256SUMS`、Launcher 和原始 Core。
3. SHA256 校验通过。
4. 在本地为 Core 应用 Launcher 兼容补丁，防止 Core 覆盖 Launcher。
5. 对 Launcher 与 Core 执行 `bash -n`。
6. 更新本机文件。

## IPv6-only

若 GitHub API 可通过原生 IPv6 访问，可直接安装。若 GitHub 链路不可达，可以给 bootstrap 指定 IPv6 可达的 HTTP / SOCKS5 代理：

```bash
bash /tmp/xray-manager-install.sh \
  --proxy 'socks5h://[IPv6地址]:1080' \
  --run
```

如果 VPS 既无法访问 GitHub，又没有 NAT64 或任何 IPv6 可达代理，在线 bootstrap 无法取得私有仓库文件。
