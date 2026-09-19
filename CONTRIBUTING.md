# Contributing

这是一个以个人维护为主的 VPS 管理脚本。

## 从问题定位代码

先用可搜索的维护导航把故障现象映射到实现文件、对应测试和文档。AI 用 `--ai`（只返回行号切片）；不要把 `lib/xray-manager-core.sh` 整文件读进上下文：

```bash
bash scripts/maintainer-map.sh --ai "路由规则顺序"
bash scripts/maintainer-map.sh --ai "Xray 版本选择"
bash scripts/maintainer-map.sh --list
```

详细边界、安全约束和测试选择见 [维护与故障定位指南](docs/MAINTAINER_GUIDE.md)。仓库级 AI 路由见 [AGENTS.md](AGENTS.md) 与 [docs/ai/INDEX.md](docs/ai/INDEX.md)。移动文件、改变模块职责、新增维护区域或移动 Core 簇锚点函数时，必须同步更新 `MAP_ROWS` / `CLUSTER_ANCHORS` 并运行：

```bash
bash scripts/maintainer-map.sh --write-index
bash scripts/maintainer-map.sh --check
bash tests/maintainer-map.sh
```

## 修改原则

- 优先兼容常见 VPS 发行版
- 不盲目修改内核
- 不默认改变系统默认路由
- 不把 SOCKS / HTTP 无加密代理默认暴露公网
- 写配置后先测试，再重启服务
- 重要变更前保留备份
- IPv6-only 环境不能把 DNS64 当作 NAT64

## 提交前检查

```bash
bash -n xray-manager.sh
bash -n install.sh
bash -n offline-install.sh
bash -n scripts/verify-xray-asset.sh
bash -n scripts/maintainer-map.sh
bash -n tests/maintainer-map.sh
bash -n tests/bootstrap-install.sh
```

推荐同时运行：

```bash
shellcheck xray-manager.sh install.sh offline-install.sh \
  scripts/maintainer-map.sh scripts/verify-xray-asset.sh tests/maintainer-map.sh
```

## 版本

功能性变更请同步更新：

- `SCRIPT_VERSION`
- `PROJECT_VERSION` / `CORE_VERSION`
- `VERSION`
- `CHANGELOG.md`
- `README.md`

## 发布新版本

修改脚本后：

```bash
./scripts/refresh-checksums.sh
```

并同步更新：

- `SCRIPT_VERSION`
- `VERSION`
- `CHANGELOG.md`
- `README.md`

GitHub Actions 会检查版本一致性和 `SHA256SUMS`。

`Validate` 工作流在工作流内下载根目录 `XRAY_VERSION` 指定的 Xray 版本，并运行真实配置 smoke test。更新该基线时只修改根目录 `XRAY_VERSION`。

发布的 GitHub Release 只应包含源码、经过 CI 验证的脚本、`SHA256SUMS` 与 `CHANGELOG.md`；不要发布节点配置、订阅、真实密钥、证书私钥或任何用户数据。提交前不要粘贴 Token、密码、私钥、UUID 或真实服务器信息。
