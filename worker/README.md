# Cloudflare download Worker

该 Worker 为 Xray Manager 提供 IPv4 / IPv6 下载入口：

- `/install.sh`、`/releases/latest-{amd64,arm64}.{tar.gz,sha256}` 与 `/releases/manifest.json`：均验证 Bearer `INSTALL_TOKEN` 后读取私有 R2。
- 所有成功响应使用 `private, no-store`，不允许共享缓存长期保留安装文件。
- 只接受 `GET` 与 `HEAD`，其他路径和版本化文件名不会被代理。

## 本地校验

```bash
npm ci
npm run check
```

`npm run check` 会生成绑定类型、执行 TypeScript 检查和 Workers 运行时测试。如需额外验证部署包，可运行 `npm run deploy:dry-run`。

## Cloudflare 配置

连接现有 Worker，不要新建第二个：

| 设置 | 值 |
| --- | --- |
| Worker 名称 | `xray-manager-download` |
| Git 仓库 | `xinian5216/xray-manager` |
| Production branch | `main` |
| Root directory | `worker` |
| Build command | `npm run check` |
| Deploy command | `npm run deploy` |
| Build include path | `worker/*` |

运行时配置：

- R2 绑定 `BUNDLES` → `xray-manager-private`，已在 `wrangler.jsonc` 声明。
- `INSTALL_TOKEN` 必须继续作为 Worker Secret 保存，不能写入源码、`vars` 或 GitHub。

如需首次手动写入或轮换 Secret：

```bash
npx wrangler secret put INSTALL_TOKEN
```

生产部署使用 `--keep-vars`，以保留控制台中已有的运行时变量；Wrangler Secret 仍由 Cloudflare 独立保存。

首次连接 Git 构建时，Cloudflare 不会补跑连接前的历史提交；保存配置后需要向生产分支推送一次新提交来触发首次构建。
