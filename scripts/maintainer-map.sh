#!/usr/bin/env bash
# Maintainer navigation for xray-manager. Keep MAP rows aligned with the repo.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# area|keywords|implementation files|tests/checks|documentation|Bash symbol regex
MAP_ROWS=(
  "launcher|launcher 启动器 自更新 self-update 菜单更新 版本 降级 downgrade 锁 lock 并发 回滚 rollback 原子 current previous 发布 清单 manifest|xray-manager.sh,install.sh,offline-install.sh,cloudflare-install.sh,lib/xray-manager-core.sh|tests/bootstrap-install.sh,tests/cloudflare-update.sh,tests/manager-menu-update.sh,tests/version-lock.sh,tests/atomic-release.sh|README.md,docs/PRIVATE_INSTALL.md,docs/USAGE.md,SECURITY.md|update,version,download,install,lock,rollback,release,manifest"
  "install-migrate|安装 依赖 dependency jq 修复 迁移 migration systemd openrc 服务 接管 配置恢复 日志 permission denied|install.sh,cloudflare-install.sh,offline-install.sh,lib/xray-manager-core.sh|tests/bootstrap-install.sh,tests/offline-install.sh,tests/config-migration.sh,tests/cloudflare-core-download.sh,tests/smoke-configs.sh|README.md,docs/USAGE.md|discover_,migrate_,configure_.*service,install_or_repair,offline_import,dependenc,layout"
  "network-ipv6|网络 ipv4 ipv6 only-v6 NAT64 DNS64 下载代理 proxy|lib/xray-manager-core.sh,install.sh,cloudflare-install.sh|tests/cloudflare-core-download.sh,tests/offline-install.sh|docs/IPV6_ONLY.md,README.md|network,ipv[46],dns64,download,proxy,cloudflare"
  "inbound-transport|入站 inbound 详情 detail 编号 index 诊断 diagnose 外部 external 编辑 edit 用户 user 链接 link 分享 二维码 QR SS2022 VLESS VMess Trojan Shadowsocks SOCKS HTTP Hysteria2 WireGuard peer 公钥 客户端 Tunnel TUN RAW XHTTP gRPC WebSocket REALITY TLS 证书 SNI|lib/xray-manager-core.sh|tests/inbound-management.sh,tests/wireguard-management.sh,tests/smoke-configs.sh,tests/manager-menu-update.sh|docs/USAGE.md,README.md|inbound,user,share,link,transport,reality,tls,certificate,add_,wireguard"
  "outbound|出站 outbound freedom socks http shadowsocks wireguard warp conf 导入 PresharedKey dialerProxy|lib/xray-manager-core.sh|tests/wireguard-management.sh,tests/smoke-configs.sh|docs/USAGE.md,README.md|outbound,wireguard"
  "routing|路由 routing 分流 rule geosite geoip CIDR 默认出口 domainStrategy|lib/xray-manager-core.sh|tests/smoke-configs.sh|docs/USAGE.md,README.md|routing,route"
  "port-forward|端口转发 forwarding forward TCP UDP 监听 目标端口|lib/xray-manager-core.sh|tests/smoke-configs.sh|docs/USAGE.md,README.md|port_forward"
  "config-safety|配置 写入 回滚 backup restore test config conf.d 安全删除|lib/xray-manager-core.sh|tests/smoke-configs.sh,tests/config-migration.sh,tests/backup-restore.sh|docs/MAINTAINER_GUIDE.md,README.md|safe_,backup,restore,test_config"
  "xray-geodata|Xray-core core geodata geoip geosite 更新 延迟 release 14天 7天 digest sha256 摘要 完整性 integrity dgst 信任|lib/xray-manager-core.sh,scripts/select-xray-release.sh,scripts/select-geodata-release.sh,scripts/verify-xray-asset.sh,XRAY_VERSION,.github/workflows/publish-r2.yml|tests/xray-release-delay.sh,tests/geodata-release-delay.sh,tests/xray-asset-integrity.sh,tests/smoke-configs.sh|README.md,CHANGELOG.md,SECURITY.md|update_xray,update_geodata,release,verify"
  "worker-r2|Cloudflare Worker R2 401 403 404 Bearer token install.sh bundle 构建部署 清单 manifest|worker/src/index.ts,worker/wrangler.jsonc,worker/package.json,.github/workflows/publish-r2.yml,cloudflare-install.sh|worker/test/index.spec.ts,worker/package.json,tests/cloudflare-update.sh|worker/README.md,README.md,SECURITY.md|"
  "firewall-bbr|UFW 防火墙 SSH BBR sysctl 端口放行 规则清理|lib/xray-manager-core.sh|tests/inbound-management.sh,tests/smoke-configs.sh|docs/USAGE.md,README.md|ufw,bbr,ssh"
  "release|发版 version checksum SHA256 changelog release bundle 打包 清单|VERSION,XRAY_VERSION,SHA256SUMS,scripts/refresh-checksums.sh,scripts/verify-xray-asset.sh,.github/workflows/shellcheck.yml,.github/workflows/publish-r2.yml|scripts/maintainer-map.sh,.github/workflows/shellcheck.yml,tests/xray-asset-integrity.sh|CONTRIBUTING.md,CHANGELOG.md,README.md,SECURITY.md|"
  "ci-tests|CI Actions ShellCheck test smoke 测试失败 workflow|.github/workflows/shellcheck.yml,.github/workflows/publish-r2.yml,tests/smoke-configs.sh|tests/inbound-management.sh,tests/maintainer-map.sh,tests/bootstrap-install.sh,tests/offline-install.sh,tests/cloudflare-update.sh,tests/cloudflare-core-download.sh,tests/config-migration.sh,tests/backup-restore.sh,tests/version-lock.sh,tests/manager-menu-update.sh,tests/atomic-release.sh,tests/xray-release-delay.sh,tests/geodata-release-delay.sh,tests/xray-asset-integrity.sh|CONTRIBUTING.md,docs/MAINTAINER_GUIDE.md|"
)

usage() {
  cat <<'EOF'
Usage:
  bash scripts/maintainer-map.sh <symptom-or-keyword>
  bash scripts/maintainer-map.sh --list
  bash scripts/maintainer-map.sh --check

Examples:
  bash scripts/maintainer-map.sh "路由规则顺序"
  bash scripts/maintainer-map.sh "Worker 401"
  bash scripts/maintainer-map.sh port-forward
EOF
}

split_paths() {
  local csv="$1"
  tr ',' '\n' <<<"$csv"
}

show_row() {
  local row="$1" area keywords implementation tests docs _symbols
  IFS='|' read -r area keywords implementation tests docs _symbols <<<"$row"
  printf '\n[%s]\n' "$area"
  printf '  关键词: %s\n' "$keywords"
  printf '  实现:   %s\n' "$implementation"
  printf '  测试:   %s\n' "$tests"
  printf '  文档:   %s\n' "$docs"
}

list_areas() {
  local row area keywords _rest
  printf '%-18s %s\n' "AREA" "KEYWORDS"
  printf '%-18s %s\n' "------------------" "--------"
  for row in "${MAP_ROWS[@]}"; do
    IFS='|' read -r area keywords _rest <<<"$row"
    printf '%-18s %s\n' "$area" "$keywords"
  done
}

show_matching_symbols() {
  local row="$1" _area _keywords implementation _tests _docs symbols path
  IFS='|' read -r _area _keywords implementation _tests _docs symbols <<<"$row"
  command -v grep >/dev/null 2>&1 || return 0
  [[ -n "$symbols" ]] || return 0
  symbols="${symbols//,/|}"

  printf '  候选符号:\n'
  while IFS= read -r path; do
    [[ "$path" == *.sh && -f "$ROOT_DIR/$path" ]] || continue
    grep -nEi -- "^[[:space:]]*(function[[:space:]]+)?[[:alnum:]_]*(${symbols})[[:alnum:]_]*[[:space:]]*(\(\))?[[:space:]]*\{" \
      "$ROOT_DIR/$path" 2>/dev/null | sed "s#^#    $path:#" || true
  done < <(split_paths "$implementation")
}

row_matches() {
  local query="$1" row="$2" token matched_any=0
  local -a query_tokens=()
  [[ "$row" == *"$query"* ]] && return 0

  if [[ "$query" == *' '* ]]; then
    IFS=' ' read -r -a query_tokens <<<"$query"
    for token in "${query_tokens[@]}"; do
      [[ "$row" == *"$token"* ]] || return 1
    done
    return 0
  fi

  while IFS= read -r token; do
    ((${#token} >= 2)) || continue
    [[ "$query" == *"$token"* ]] && matched_any=1
  done < <(tr ' |' '\n' <<<"$row")
  ((matched_any == 1))
}

find_area() {
  local query="$1" normalized row haystack matched=0
  normalized="${query,,}"
  for row in "${MAP_ROWS[@]}"; do
    haystack="${row,,}"
    if row_matches "$normalized" "$haystack"; then
      show_row "$row"
      show_matching_symbols "$row"
      matched=1
    fi
  done

  if ((matched == 0)); then
    printf '没有精确命中维护区域：%s\n' "$query" >&2
    printf '建议先运行 --list，或直接搜索函数/错误文本：\n' >&2
    printf '  rg -n --fixed-strings %q .\n' "$query" >&2
    return 1
  fi
}

check_map() {
  local row area _keywords implementation tests docs _symbols group path separators failed=0
  declare -A seen=()

  for row in "${MAP_ROWS[@]}"; do
    separators="${row//[^|]/}"
    if ((${#separators} != 5)); then
      printf '[x] 映射行必须正好包含 6 个字段：%s\n' "$row" >&2
      failed=1
      continue
    fi
    IFS='|' read -r area _keywords implementation tests docs _symbols <<<"$row"
    if [[ -n "${seen[$area]:-}" ]]; then
      printf '[x] 重复区域：%s\n' "$area" >&2
      failed=1
    fi
    seen[$area]=1

    for group in "$implementation" "$tests" "$docs"; do
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if [[ ! -e "$ROOT_DIR/$path" ]]; then
          printf '[x] %s 引用了不存在的路径：%s\n' "$area" "$path" >&2
          failed=1
        fi
      done < <(split_paths "$group")
    done
  done

  if ((failed != 0)); then
    return 1
  fi
  printf '[✓] 维护导航中的 %d 个区域和全部路径均有效。\n' "${#MAP_ROWS[@]}"
}

main() {
  case "${1:-}" in
    -h|--help|'') usage ;;
    --list) list_areas ;;
    --check) check_map ;;
    *) find_area "$*" ;;
  esac
}

main "$@"
