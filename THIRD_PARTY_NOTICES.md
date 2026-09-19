# 第三方组件声明 / Third-Party Notices

本仓库不包含第三方项目的源代码。以下组件由本项目在运行时从各自官方来源下载、调用或访问，其版权与许可证归各自作者所有。列出这些组件不代表它们认可、赞助或背书本项目。

| 组件 | 用途 | 上游 | 许可证 |
| --- | --- | --- | --- |
| Xray-core | 被管理的主体程序：安装、配置测试与运行 | https://github.com/XTLS/Xray-core | MPL-2.0 |
| Xray-install | systemd / Alpine 安装与 GeoData 更新脚本（运行时下载并执行，不随本仓库分发） | https://github.com/XTLS/Xray-install | GPL-3.0 |
| acme.sh | 可选的 TLS 证书签发工具（按固定 Commit 下载、校验脚本 SHA256 后执行，不随本仓库分发） | https://github.com/acmesh-official/acme.sh | GPL-3.0 |
| GitHub API | 读取本项目公开仓库文件、发布 Release 元数据与资产摘要 | https://docs.github.com/rest | GitHub 服务条款 |
| Cloudflare DNS64 | 可选的 IPv6-only DNS64 解析地址（仅作为 DNS 服务使用，不属于 Cloudflare Worker/R2） | https://www.cloudflare.com/ | Cloudflare 服务条款 |
| Cloudflare WARP 端点 | WireGuard / WARP 出站示例中使用的公共端点（仅作为服务地址引用） | https://www.cloudflare.com/warp/ | Cloudflare 服务条款 |

说明：

- 上游脚本由用户在运行时从官方地址下载；本项目只负责调用与校验，不在仓库中复制其源码。
- Xray-core 由上游安装器或本项目的离线导入流程安装，ZIP 资产通过 GitHub Release API `digest` 与官方 `.dgst` 交叉校验 SHA256。
- 若你重新分发本项目或衍生作品，请自行复核上述上游组件的许可证与再分发条件。
