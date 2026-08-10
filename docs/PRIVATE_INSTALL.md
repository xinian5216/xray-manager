# Private Repository 一键安装

本仓库是 Private Repository，因此匿名 `curl raw.githubusercontent.com/...` 不会成功。

推荐使用 GitHub Fine-grained Personal Access Token，并只给：

```text
Repository access:
Only select repositories
→ xray-manager

Repository permissions:
Contents → Read-only
```

GitHub 的 Repository Contents API 对私有仓库读取只需要 `Contents: Read` 权限。

## 推荐安装方式

先在终端安全输入 Token：

```bash
read -rsp "GitHub Token: " GH_TOKEN; echo
export GH_TOKEN
```

再下载安装器：

```bash
curl -fsSL \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github.raw+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/xinian5216/xray-manager/contents/install.sh?ref=main" \
  -o /tmp/xray-manager-install.sh
```

安装并直接运行：

```bash
bash /tmp/xray-manager-install.sh --run
```

最后清理：

```bash
rm -f /tmp/xray-manager-install.sh
unset GH_TOKEN
```

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
rc=$?; rm -f /tmp/xray-manager-install.sh; unset GH_TOKEN; exit $rc
```

Token 不会被写死在命令历史中；你只会看到提示后手动输入的内容。

## 安装器做什么

`install.sh` 会：

1. 从私有仓库读取 `VERSION`
2. 下载 `SHA256SUMS`
3. 下载 `xray-manager.sh`
4. 校验 SHA256
5. 执行 `bash -n`
6. 安装到 `/usr/local/sbin/xraym`
7. `--run` 时直接启动管理菜单

## IPv6-only

如果 GitHub API 可以通过原生 IPv6 访问，直接使用即可。

如果 VPS 的 GitHub 链路不可达，可以给 bootstrap 指定一个 IPv6 可达的 HTTP / SOCKS5 代理：

```bash
export XRAY_DOWNLOAD_PROXY='socks5h://[IPv6地址]:1080'
bash /tmp/xray-manager-install.sh --run
```

或：

```bash
bash /tmp/xray-manager-install.sh \
  --proxy 'http://[IPv6地址]:8080' \
  --run
```

注意：如果 VPS 本身既不能访问 GitHub，又没有 NAT64 或可用代理，那么任何“在线一键安装脚本”都无法凭空取得私有仓库内容。

## Xray Manager 自更新

进入：

```text
15) 检查 / 更新 Xray Manager（私有仓库）
```

脚本会再次提示 Token，然后：

- 读取仓库 VERSION
- 下载 SHA256SUMS
- 下载最新版 `xray-manager.sh`
- 校验 SHA256
- 检查 Bash 语法
- 覆盖 `/usr/local/sbin/xraym`

Token 默认不会保存到 VPS。

## 固定 VPS 的长期凭据

如果未来希望服务器长期自动拉取私有仓库，可以使用 GitHub read-only Deploy Key。

Deploy Key 默认可以设为只读，并且只绑定一个仓库；但私钥会长期留在服务器上，所以服务器失陷时仍需撤销该 Key。

当前 `xraym` 的内置自更新使用 HTTPS Contents API，因此默认采用临时 Fine-grained PAT，而不是长期 Deploy Key。
