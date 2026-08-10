# Contributing

这是一个以个人维护为主的 VPS 管理脚本。

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
```

推荐同时运行：

```bash
shellcheck xray-manager.sh
```

## 版本

功能性变更请同步更新：

- `SCRIPT_VERSION`
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
