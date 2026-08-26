# Contributing

这是一个以个人维护为主的 VPS 管理脚本。

## 从问题定位代码

先用可搜索的维护导航把故障现象映射到实现文件、对应测试和文档：

```bash
bash scripts/maintainer-map.sh "路由规则顺序"
bash scripts/maintainer-map.sh "Worker 401"
bash scripts/maintainer-map.sh --list
```

详细边界、安全约束和测试选择见 [维护与故障定位指南](docs/MAINTAINER_GUIDE.md)。移动文件、改变模块职责或新增维护区域时，必须同步更新 `MAP_ROWS` 并运行：

```bash
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
bash -n cloudflare-install.sh
bash -n scripts/select-xray-release.sh
bash -n scripts/verify-xray-asset.sh
bash -n scripts/maintainer-map.sh
bash -n tests/maintainer-map.sh
bash -n tests/bootstrap-install.sh
```

推荐同时运行：

```bash
shellcheck xray-manager.sh install.sh offline-install.sh cloudflare-install.sh \
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

涉及 R2 分发时，还应确认 `shellcheck.yml` 与 `publish-r2.yml` 使用相同的固定 Xray 版本，并确保发布工作流在上传前完成真实配置冒烟测试。

更新随包分发的 Xray-core 时，只修改根目录 `XRAY_VERSION`，两个工作流都会读取该文件。
