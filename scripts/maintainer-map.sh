#!/usr/bin/env bash
# Maintainer navigation for xray-manager. Keep MAP rows aligned with the repo.
# AI first-contact: prefer --ai (ranked slices) or the generated docs/ai/ index.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_MD="docs/ai/INDEX.md"
SYMBOLS_TSV="docs/ai/core-symbols.tsv"
AI_MAX_FUNCTIONS=12
AI_MAX_LINES=500
FUNCS_CACHE=""

cleanup() {
  if [[ -n "${FUNCS_CACHE:-}" && -f "$FUNCS_CACHE" ]]; then
    rm -f "$FUNCS_CACHE"
  fi
}
trap cleanup EXIT

# area|keywords|implementation files|tests/checks|documentation|Bash symbol regex
MAP_ROWS=(
  "launcher|launcher 启动器 自更新 self-update 菜单更新 版本 降级 downgrade 锁 lock 并发 回滚 rollback 原子 current previous 发布 清单 manifest|xray-manager.sh,install.sh,offline-install.sh,cloudflare-install.sh,lib/xray-manager-core.sh|tests/bootstrap-install.sh,tests/cloudflare-update.sh,tests/manager-menu-update.sh,tests/version-lock.sh,tests/atomic-release.sh|README.md,docs/PRIVATE_INSTALL.md,docs/USAGE.md,SECURITY.md|update,version,download,install,lock,rollback,release,manifest"
  "install-migrate|安装 依赖 dependency jq 修复 迁移 migration systemd openrc 服务 接管 配置恢复 日志 permission denied|install.sh,cloudflare-install.sh,offline-install.sh,lib/xray-manager-core.sh|tests/bootstrap-install.sh,tests/offline-install.sh,tests/config-migration.sh,tests/cloudflare-core-download.sh,tests/smoke-configs.sh|README.md,docs/USAGE.md|discover_,migrate_,configure_.*service,install_or_repair,offline_import,dependenc,layout"
  "network-ipv6|网络 ipv4 ipv6 only-v6 NAT64 DNS64 下载代理 proxy|lib/xray-manager-core.sh,install.sh,cloudflare-install.sh|tests/cloudflare-core-download.sh,tests/offline-install.sh|docs/IPV6_ONLY.md,README.md|network,ipv[46],dns64,download,proxy,cloudflare"
  "inbound-transport|入站 inbound 详情 detail 编号 index 诊断 diagnose 外部 external 编辑 edit 用户 user 链接 link 分享 二维码 QR SS2022 VLESS VMess Trojan Shadowsocks SOCKS HTTP Hysteria2 WireGuard peer 公钥 客户端 Tunnel TUN RAW XHTTP gRPC WebSocket REALITY TLS 证书 SNI|lib/xray-manager-core.sh|tests/inbound-management.sh,tests/wireguard-management.sh,tests/smoke-configs.sh,tests/manager-menu-update.sh|docs/USAGE.md,README.md|inbound,user,share,link,transport,reality,tls,certificate,add_,wireguard"
  "outbound|出站 outbound freedom socks http shadowsocks wireguard warp conf 导入 PresharedKey dialerProxy|lib/xray-manager-core.sh|tests/wireguard-management.sh,tests/smoke-configs.sh|docs/USAGE.md,README.md|outbound,wireguard"
  "routing|路由 routing 分流 rule geosite geoip CIDR 默认出口 domainStrategy|lib/xray-manager-core.sh|tests/smoke-configs.sh|docs/USAGE.md,README.md|routing,route"
  "port-forward|端口转发 forwarding forward TCP UDP 监听 目标端口|lib/xray-manager-core.sh|tests/smoke-configs.sh|docs/USAGE.md,README.md|port_forward"
  "config-safety|配置 写入 回滚 backup restore test config conf.d 安全删除 备份 恢复 归档|lib/xray-manager-core.sh|tests/smoke-configs.sh,tests/config-migration.sh,tests/backup-restore.sh|docs/MAINTAINER_GUIDE.md,README.md|safe_,backup,restore,test_config"
  "xray-geodata|Xray-core core geodata geoip geosite 更新 延迟 release 14天 7天 digest sha256 摘要 完整性 integrity dgst 信任 版本选择 指定版本 prerelease pre-release 预发布 最新发布版 最新稳定版 降级 回滚 backup rollback|lib/xray-manager-core.sh,scripts/select-xray-release.sh,scripts/select-geodata-release.sh,scripts/verify-xray-asset.sh,XRAY_VERSION,.github/workflows/publish-r2.yml|tests/xray-release-delay.sh,tests/xray-version-select.sh,tests/geodata-release-delay.sh,tests/xray-asset-integrity.sh,tests/smoke-configs.sh|README.md,CHANGELOG.md,SECURITY.md|update_xray,update_geodata,xray_version,xray_github,xray_release,xray_current_version,xray_history,xray_install_selected,xray_install_official,xray_openrc,xray_verify,xray_parse,xray_backup_core,xray_restore_core,xray_service_active,xray_rollback,xray_confirm_downgrade,xray_ask_manual,xray_report_target,xray_print_update"
  "worker-r2|Cloudflare Worker R2 401 403 404 Bearer token install.sh bundle 构建部署 清单 manifest|worker/src/index.ts,worker/wrangler.jsonc,worker/package.json,.github/workflows/publish-r2.yml,cloudflare-install.sh|worker/test/index.spec.ts,worker/package.json,tests/cloudflare-update.sh|worker/README.md,README.md,SECURITY.md|"
  "firewall-bbr|UFW 防火墙 SSH BBR sysctl 端口放行 规则清理|lib/xray-manager-core.sh|tests/inbound-management.sh,tests/smoke-configs.sh|docs/USAGE.md,README.md|ufw,bbr,ssh"
  "release|发版 version checksum SHA256 changelog release bundle 打包 清单|VERSION,XRAY_VERSION,SHA256SUMS,scripts/refresh-checksums.sh,scripts/verify-xray-asset.sh,.github/workflows/shellcheck.yml,.github/workflows/publish-r2.yml|scripts/maintainer-map.sh,.github/workflows/shellcheck.yml,tests/xray-asset-integrity.sh|CONTRIBUTING.md,CHANGELOG.md,README.md,SECURITY.md|"
  "ci-tests|CI Actions ShellCheck test smoke 测试失败 workflow|.github/workflows/shellcheck.yml,.github/workflows/publish-r2.yml,tests/smoke-configs.sh|tests/inbound-management.sh,tests/maintainer-map.sh,tests/bootstrap-install.sh,tests/offline-install.sh,tests/cloudflare-update.sh,tests/cloudflare-core-download.sh,tests/config-migration.sh,tests/backup-restore.sh,tests/version-lock.sh,tests/manager-menu-update.sh,tests/atomic-release.sh,tests/xray-release-delay.sh,tests/xray-version-select.sh,tests/geodata-release-delay.sh,tests/xray-asset-integrity.sh|CONTRIBUTING.md,docs/MAINTAINER_GUIDE.md|"
)

# area|file|start_function|end_function  (line ranges are computed; names are the stable contract)
CLUSTER_ANCHORS=(
  "launcher|xray-manager.sh|usage|run_core"
  "network-ipv6|lib/xray-manager-core.sh|detect_xray_run_identity|ipv6_only_menu"
  "install-migrate|lib/xray-manager-core.sh|pkg_install_base|need_xray"
  "config-safety|lib/xray-manager-core.sh|test_config_dir|safe_remove_config_file"
  "config-safety|lib/xray-manager-core.sh|validate_backup_archive|backup_menu"
  "inbound-transport|lib/xray-manager-core.sh|copy_existing_certificate|inbound_detail_menu"
  "outbound|lib/xray-manager-core.sh|csv_to_json_array|outbound_menu"
  "routing|lib/xray-manager-core.sh|routing_conflict_files|routing_menu"
  "port-forward|lib/xray-manager-core.sh|list_port_forwards|port_forward_menu"
  "xray-geodata|lib/xray-manager-core.sh|xray_version_normalize|update_geodata"
  "firewall-bbr|lib/xray-manager-core.sh|detect_ssh_port|bbr_status"
)

# chinese_or_alias|function_name_substrings
TOKEN_ALIASES=(
  "路由:routing,route"
  "规则:routing,route"
  "分流:routing,route,geosite,geoip"
  "入站:inbound"
  "出站:outbound"
  "分享:share,link,qr"
  "链接:share,link"
  "用户:user,peer"
  "详情:summary,detail,inbound"
  "诊断:diagnose"
  "编辑:edit_inbound,write_inbound,preview_inbound"
  "备份:backup,restore"
  "恢复:backup,restore"
  "迁移:migrate,discover"
  "下载:download,curl,proxy"
  "锁:lock"
  "回滚:rollback"
  "证书:tls,certificate,acme,reality"
  "防火墙:ufw"
  "转发:port_forward"
  "二维码:share,link,qr,wireguard"
  "公钥:wireguard,peer,reality"
  "客户端:wireguard,peer,share"
  "ss2022:shadowsocks,2022"
  "shadowsocks:shadowsocks"
  "reality:reality"
  "默认出口:default_outbound,routing"
)

INDEXED_BASH_FILES=(
  xray-manager.sh
  install.sh
  cloudflare-install.sh
  offline-install.sh
  lib/xray-manager-core.sh
  scripts/select-xray-release.sh
  scripts/select-geodata-release.sh
  scripts/verify-xray-asset.sh
)

usage() {
  cat <<'EOF'
Usage:
  bash scripts/maintainer-map.sh <symptom-or-keyword>
  bash scripts/maintainer-map.sh --ai "<task or error>"
  bash scripts/maintainer-map.sh --list
  bash scripts/maintainer-map.sh --check
  bash scripts/maintainer-map.sh --write-index

AI first contact:
  bash scripts/maintainer-map.sh --ai "路由规则顺序"
  Then read only the printed file:start-end slices. Never open Core in full.

Examples:
  bash scripts/maintainer-map.sh "Worker 401"
  bash scripts/maintainer-map.sh --ai SS2022
  bash scripts/maintainer-map.sh port-forward
EOF
}

split_csv() {
  local csv="$1"
  local IFS=','
  # shellcheck disable=SC2086
  printf '%s\n' $csv
}

split_words() {
  local text="$1"
  local IFS=' '
  # shellcheck disable=SC2086
  printf '%s\n' $text
}

index_bash_functions() {
  local file="$1"
  [[ -f "$ROOT_DIR/$file" ]] || return 0
  awk -v file="$file" '
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
      if (name != "") printf "%s\t%d\t%d\t%s\n", file, start, NR - 1, name
      name = $1
      sub(/\(.*$/, "", name)
      start = NR
    }
    END {
      if (name != "") printf "%s\t%d\t%d\t%s\n", file, start, NR, name
    }
  ' "$ROOT_DIR/$file"
}

ensure_funcs_cache() {
  [[ -n "${FUNCS_CACHE:-}" && -f "$FUNCS_CACHE" ]] && return 0
  FUNCS_CACHE="$(mktemp)"
  local file
  : >"$FUNCS_CACHE"
  for file in "${INDEXED_BASH_FILES[@]}"; do
    index_bash_functions "$file" >>"$FUNCS_CACHE"
  done
}

lookup_function() {
  local file="$1" want="$2"
  ensure_funcs_cache
  awk -F '\t' -v file="$file" -v want="$want" '
    $1 == file && $4 == want { printf "%s\t%s\n", $2, $3; found=1; exit }
    END { if (!found) exit 1 }
  ' "$FUNCS_CACHE"
}

cluster_ranges_for_area() {
  local want="$1" row area file start_fn end_fn span start end
  for row in "${CLUSTER_ANCHORS[@]}"; do
    IFS='|' read -r area file start_fn end_fn <<<"$row"
    [[ "$area" == "$want" ]] || continue
    span="$(lookup_function "$file" "$start_fn")" || {
      printf 'missing-start:%s:%s\n' "$file" "$start_fn" >&2
      continue
    }
    start="${span%%$'\t'*}"
    span="$(lookup_function "$file" "$end_fn")" || {
      printf 'missing-end:%s:%s\n' "$file" "$end_fn" >&2
      continue
    }
    end="${span#*$'\t'}"
    printf '%s:%s-%s\n' "$file" "$start" "$end"
  done
}

file_line_count() {
  local file="$1"
  [[ -f "$ROOT_DIR/$file" ]] || { printf '0'; return 0; }
  wc -l <"$ROOT_DIR/$file" | tr -d ' '
}

file_byte_count() {
  local file="$1"
  [[ -f "$ROOT_DIR/$file" ]] || { printf '0'; return 0; }
  wc -c <"$ROOT_DIR/$file" | tr -d ' '
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
  local printed=0 file start end name
  IFS='|' read -r _area _keywords implementation _tests _docs symbols <<<"$row"
  [[ -n "$symbols" ]] || return 0
  ensure_funcs_cache
  symbols="${symbols//,/|}"

  printf '  候选符号:\n'
  while IFS= read -r path; do
    [[ "$path" == *.sh && -f "$ROOT_DIR/$path" ]] || continue
    while IFS=$'\t' read -r file start end name; do
      [[ "$name" =~ $symbols ]] || continue
      printf '    %s:%s-%s %s\n' "$file" "$start" "$end" "$name"
      printed=$((printed + 1))
      if ((printed >= 20)); then
        printf '    ... truncated; use --ai or grep %s\n' "$SYMBOLS_TSV"
        return 0
      fi
    done <<<"$(awk -F '\t' -v path="$path" '$1 == path { print }' "$FUNCS_CACHE")"
  done <<<"$(split_csv "$implementation")"
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
  done <<<"$(printf '%s\n' "$row" | tr ' |' '\n')"
  ((matched_any == 1))
}

score_area_row() {
  local query="$1" row="$2"
  local area keywords implementation tests docs symbols
  local q="${query,,}" score=0 token kw
  IFS='|' read -r area keywords implementation tests docs symbols <<<"$row"
  local haystack="${row,,}"

  if [[ "$q" == "$area" ]]; then
    score=$((score + 120))
  elif [[ "$q" == *"$area"* ]]; then
    score=$((score + 50))
  fi

  while IFS= read -r kw; do
    [[ -n "$kw" ]] || continue
    local kw_l="${kw,,}"
    if [[ "$q" == *"$kw_l"* ]]; then
      score=$((score + ${#kw} + 8))
    fi
  done <<<"$(split_words "$keywords")"

  while IFS= read -r token; do
    ((${#token} >= 2)) || continue
    local t="${token,,}"
    [[ "$haystack" == *"$t"* ]] || continue
    score=$((score + ${#t}))
  done <<<"$(split_words "$query")"

  printf '%s' "$score"
}

expand_query_needles() {
  local query="$1" alias_row key values
  {
    printf '%s\n' "${query,,}"
    split_words "${query,,}"
    for alias_row in "${TOKEN_ALIASES[@]}"; do
      key="${alias_row%%:*}"
      values="${alias_row#*:}"
      if [[ "${query,,}" == *"${key,,}"* ]]; then
        split_csv "$values"
      fi
    done
  } | awk 'NF && !seen[$0]++'
}

function_query_score() {
  local name="$1" query="$2" score=0 needle
  local name_l="${name,,}"
  [[ "$name_l" == "${query,,}" ]] && score=$((score + 80))
  while IFS= read -r needle; do
    ((${#needle} >= 2)) || continue
    if [[ "$name_l" == *"$needle"* ]]; then
      score=$((score + ${#needle} + 6))
    fi
  done <<<"$(expand_query_needles "$query")"
  printf '%s' "$score"
}

function_in_clusters() {
  local file="$1" start="$2" clusters="$3" cluster c_file c_range c_start c_end
  [[ -n "$clusters" ]] || return 0
  while IFS= read -r cluster; do
    [[ -n "$cluster" ]] || continue
    c_file="${cluster%%:*}"
    c_range="${cluster#*:}"
    c_start="${c_range%-*}"
    c_end="${c_range#*-}"
    if [[ "$file" == "$c_file" && "$start" -ge "$c_start" && "$start" -le "$c_end" ]]; then
      return 0
    fi
  done <<<"$clusters"
  return 1
}

select_ai_functions() {
  local row="$1" query="$2" clusters="$3"
  local area _keywords implementation _tests _docs symbols path
  local file start end name fn_score scored="" in_cluster=0
  IFS='|' read -r area _keywords implementation _tests _docs symbols <<<"$row"
  ensure_funcs_cache

  while IFS= read -r path; do
    [[ "$path" == *.sh && -f "$ROOT_DIR/$path" ]] || continue
    while IFS=$'\t' read -r file start end name; do
      [[ -n "$name" ]] || continue
      fn_score="$(function_query_score "$name" "$query")"
      if [[ -n "$symbols" && "$name" =~ ${symbols//,/|} ]]; then
        fn_score=$((fn_score + 2))
      fi
      in_cluster=0
      if function_in_clusters "$file" "$start" "$clusters"; then
        in_cluster=1
        fn_score=$((fn_score + 4))
      elif [[ -n "$clusters" ]]; then
        ((fn_score >= 24)) || continue
      fi
      if ((in_cluster == 1)); then
        ((fn_score >= 8)) || continue
      else
        ((fn_score >= 8)) || continue
      fi
      scored+="${fn_score}"$'\t'"${file}"$'\t'"${start}"$'\t'"${end}"$'\t'"${name}"$'\n'
    done <<<"$(awk -F '\t' -v path="$path" '$1 == path { print }' "$FUNCS_CACHE")"
  done <<<"$(split_csv "$implementation")"

  [[ -n "$scored" ]] || return 0
  printf '%s' "$scored" | sort -nr -k1,1 | awk -v n="$AI_MAX_FUNCTIONS" 'NR <= n'
}

emit_ai_row() {
  local row="$1" query="$2" score="$3"
  local area keywords implementation tests docs _symbols
  IFS='|' read -r area keywords implementation tests docs _symbols <<<"$row"

  printf 'area: %s  (score %s)\n' "$area" "$score"
  printf 'impl: %s\n' "$implementation"
  printf 'test: %s\n' "$tests"
  printf 'docs: %s\n' "$docs"

  local cluster c_file c_range c_start c_end c_lines=0
  local clusters=""
  while IFS= read -r cluster; do
    [[ -n "$cluster" ]] || continue
    clusters+="$cluster"$'\n'
    c_file="${cluster%%:*}"
    c_range="${cluster#*:}"
    c_start="${c_range%-*}"
    c_end="${c_range#*-}"
    c_lines=$((c_lines + c_end - c_start + 1))
    printf 'cluster: %s (%s lines)\n' "$cluster" "$((c_end - c_start + 1))"
  done <<<"$(cluster_ranges_for_area "$area")"

  local picked
  picked="$(select_ai_functions "$row" "$query" "$clusters" || true)"
  if [[ -n "$picked" ]]; then
    printf 'functions:\n'
    while IFS=$'\t' read -r fn_score file start end name; do
      [[ -n "$name" ]] || continue
      printf '  %s:%s-%s %s\n' "$file" "$start" "$end" "$name"
    done <<<"$picked"
    local span_start span_end span_file count
    span_file="$(printf '%s\n' "$picked" | awk -F '\t' 'NR==1 {print $2}')"
    span_start="$(printf '%s\n' "$picked" | awk -F '\t' '$2 != "" {print $3}' | sort -n | head -n1)"
    span_end="$(printf '%s\n' "$picked" | awk -F '\t' '$2 != "" {print $4}' | sort -n | tail -n1)"
    count="$(printf '%s\n' "$picked" | awk 'NF {n++} END {print n+0}')"
    printf 'read:\n'
    if [[ -n "$clusters" && "$c_lines" -gt 0 && "$c_lines" -le "$AI_MAX_LINES" && "$count" -ge 5 ]]; then
      while IFS= read -r cluster; do
        [[ -n "$cluster" ]] || continue
        c_file="${cluster%%:*}"
        c_range="${cluster#*:}"
        c_start="${c_range%-*}"
        c_end="${c_range#*-}"
        printf '  sed -n "%s,%sp" %s   # %s cluster\n' "$c_start" "$c_end" "$c_file" "$area"
      done <<<"$clusters"
    elif [[ -n "$span_file" && -n "$span_start" && $((span_end - span_start + 1)) -le $AI_MAX_LINES && "$count" -ge 4 ]]; then
      printf '  sed -n "%s,%sp" %s   # covering %s hits\n' "$span_start" "$span_end" "$span_file" "$count"
    else
      local sorted consumed=0 span
      sorted="$(printf '%s\n' "$picked" | awk -F '\t' '{print $2 "\t" $3 "\t" $4 "\t" $5}' | sort -t $'\t' -k1,1 -k2,2n)"
      while IFS=$'\t' read -r file start end name; do
        [[ -n "$file" ]] || continue
        span=$((end - start + 1))
        if ((consumed + span > AI_MAX_LINES && consumed > 0)); then
          printf '  # further hits omitted (cap %s lines)\n' "$AI_MAX_LINES"
          break
        fi
        printf '  sed -n "%s,%sp" %s   # %s\n' "$start" "$end" "$file" "$name"
        consumed=$((consumed + span))
      done <<<"$sorted"
    fi
  elif [[ -n "$clusters" && "$c_lines" -gt 0 && "$c_lines" -le "$AI_MAX_LINES" ]]; then
    printf 'read:\n'
    while IFS= read -r cluster; do
      [[ -n "$cluster" ]] || continue
      c_file="${cluster%%:*}"
      c_range="${cluster#*:}"
      c_start="${c_range%-*}"
      c_end="${c_range#*-}"
      printf '  sed -n "%s,%sp" %s\n' "$c_start" "$c_end" "$c_file"
    done <<<"$clusters"
  else
    local primary
    primary="$(split_csv "$implementation" | awk 'NR==1 {print; exit}')"
    if [[ -n "$primary" && "$(file_line_count "$primary")" -le "$AI_MAX_LINES" ]]; then
      printf 'read:\n  %s  (whole, %s lines)\n' "$primary" "$(file_line_count "$primary")"
    else
      printf 'read: too large for a whole-area dump. Grep %s or pass a narrower query.\n' "$SYMBOLS_TSV"
    fi
  fi
  printf 'skip: README.md CHANGELOG.md lib/xray-manager-core.sh(full)\n'
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
    printf '  grep -i %q %s\n' "$query" "$SYMBOLS_TSV" >&2
    return 1
  fi
  return 0
}

ai_find() {
  local query="$*"
  [[ -n "$query" ]] || { usage; return 2; }
  local row score best_score=0 scored=""

  printf 'query: %s\n' "$query"
  printf 'rule: read only the slices below; never dump Core/README/CHANGELOG.\n'

  for row in "${MAP_ROWS[@]}"; do
    score="$(score_area_row "$query" "$row")"
    [[ "$score" =~ ^[0-9]+$ ]] || score=0
    ((score > 0)) || continue
    scored+="${score}|${row}"$'\n'
    if ((score > best_score)); then
      best_score=$score
    fi
  done

  if ((best_score == 0)); then
    printf 'no area match: %s\n' "$query" >&2
    printf 'try: bash scripts/maintainer-map.sh --list\n' >&2
    printf 'or:  grep -i %q %s\n' "$query" "$SYMBOLS_TSV" >&2
    return 1
  fi

  local shown=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    score="${line%%|*}"
    row="${line#*|}"
    if ((shown > 0)) && ((score * 2 < best_score)); then
      continue
    fi
    printf '\n'
    emit_ai_row "$row" "$query" "$score"
    shown=$((shown + 1))
    if ((shown >= 2)); then
      break
    fi
  done <<<"$(printf '%s' "$scored" | sort -t '|' -nr -k1,1)"
}

area_row_by_id() {
  local want="$1" row area
  for row in "${MAP_ROWS[@]}"; do
    area="${row%%|*}"
    if [[ "$area" == "$want" ]]; then
      printf '%s' "$row"
      return 0
    fi
  done
  return 1
}

generate_symbols_tsv() {
  local file start end name area areas cluster c_file c_range c_start c_end
  local cluster_cache=""
  ensure_funcs_cache
  for area in launcher install-migrate network-ipv6 inbound-transport outbound routing port-forward config-safety xray-geodata firewall-bbr; do
    while IFS= read -r cluster; do
      [[ -n "$cluster" ]] || continue
      cluster_cache+="${area}|${cluster}"$'\n'
    done <<<"$(cluster_ranges_for_area "$area")"
  done

  printf '# file\tstart\tend\tname\tareas\n'
  while IFS=$'\t' read -r file start end name; do
    [[ -n "$name" ]] || continue
    areas=""
    while IFS= read -r cluster; do
      [[ -n "$cluster" ]] || continue
      area="${cluster%%|*}"
      cluster="${cluster#*|}"
      c_file="${cluster%%:*}"
      c_range="${cluster#*:}"
      c_start="${c_range%-*}"
      c_end="${c_range#*-}"
      if [[ "$file" == "$c_file" && "$start" -ge "$c_start" && "$end" -le "$c_end" ]]; then
        if [[ "$areas" != *"$area"* ]]; then
          areas="${areas:+$areas,}$area"
        fi
      fi
    done <<<"$cluster_cache"
    printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$start" "$end" "$name" "${areas:-}"
  done <"$FUNCS_CACHE"
}

generate_index_md() {
  local row area keywords implementation tests docs _symbols
  local cluster c_file c_range c_start c_end lines
  local core_bytes core_lines launcher_bytes launcher_lines
  core_bytes="$(file_byte_count lib/xray-manager-core.sh)"
  core_lines="$(file_line_count lib/xray-manager-core.sh)"
  launcher_bytes="$(file_byte_count xray-manager.sh)"
  launcher_lines="$(file_line_count xray-manager.sh)"
  cat <<EOF
# AI index (generated)

Do not hand-edit. Regenerate with \`bash scripts/maintainer-map.sh --write-index\`.
First contact: read [AGENTS.md](../../AGENTS.md), then this file or \`--ai\`. Never open \`lib/xray-manager-core.sh\` in full.

## File budget

| file | bytes | lines | first contact |
| --- | ---: | ---: | --- |
| AGENTS.md | $(file_byte_count AGENTS.md) | $(file_line_count AGENTS.md) | always |
| $INDEX_MD | generated | generated | always |
| $SYMBOLS_TSV | generated | generated | grep function names |
| lib/xray-manager-core.sh | ${core_bytes} | ${core_lines} | **never whole** — slices only |
| xray-manager.sh | ${launcher_bytes} | ${launcher_lines} | launcher/self-update only |
| README.md | $(file_byte_count README.md) | $(file_line_count README.md) | user-doc edits only |
| CHANGELOG.md | $(file_byte_count CHANGELOG.md) | $(file_line_count CHANGELOG.md) | release notes only |
| tests/smoke-configs.sh | $(file_byte_count tests/smoke-configs.sh) | $(file_line_count tests/smoke-configs.sh) | config-generation tests |

Cap: about ${AI_MAX_LINES} lines of Core per turn. Prefer \`bash scripts/maintainer-map.sh --ai "<task>"\`.

## Areas
EOF
  printf '\n| area | core slice | lines | tests | when |\n| --- | --- | ---: | --- | --- |\n'
  for row in "${MAP_ROWS[@]}"; do
    IFS='|' read -r area keywords implementation tests docs _symbols <<<"$row"
    local slices="—"
    local total=0
    local slice_bits=()
    while IFS= read -r cluster; do
      [[ -n "$cluster" ]] || continue
      c_file="${cluster%%:*}"
      c_range="${cluster#*:}"
      c_start="${c_range%-*}"
      c_end="${c_range#*-}"
      lines=$((c_end - c_start + 1))
      total=$((total + lines))
      slice_bits+=("${c_file}:${c_range}")
    done <<<"$(cluster_ranges_for_area "$area")"
    if ((${#slice_bits[@]} > 0)); then
      local IFS=', '
      slices="${slice_bits[*]}"
      unset IFS
      IFS=$'\n\t'
    elif [[ "$implementation" == *worker/src/index.ts* ]]; then
      slices="worker/src/index.ts (whole)"
      total=$(file_line_count worker/src/index.ts)
    fi
    local when
    when="$(split_words "$keywords" | awk 'NR<=8 {printf "%s%s", (NR==1?"":" / "), $0}')"
    printf '| `%s` | %s | %s | %s | %s |\n' "$area" "$slices" "$total" "$tests" "$when"
  done

  cat <<'EOF'

## How to slice

```bash
bash scripts/maintainer-map.sh --ai "SS2022 用户"
grep -i shadowsocks docs/ai/core-symbols.tsv
sed -n '2565,2628p' lib/xray-manager-core.sh
```

If the cluster is larger than 500 lines (`inbound-transport` is ~3000), do not read the cluster. Grep the TSV or pass a protocol/function keyword to `--ai`.

EOF
}

write_index() {
  mkdir -p "$ROOT_DIR/docs/ai"
  generate_index_md >"$ROOT_DIR/$INDEX_MD"
  generate_symbols_tsv >"$ROOT_DIR/$SYMBOLS_TSV"
  printf '[✓] wrote %s and %s\n' "$INDEX_MD" "$SYMBOLS_TSV"
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
      done <<<"$(split_csv "$group")"
    done
  done

  local anchor file start_fn end_fn
  for anchor in "${CLUSTER_ANCHORS[@]}"; do
    IFS='|' read -r area file start_fn end_fn <<<"$anchor"
    if ! area_row_by_id "$area" >/dev/null; then
      printf '[x] CLUSTER_ANCHORS 引用了未知区域：%s\n' "$area" >&2
      failed=1
    fi
    if ! lookup_function "$file" "$start_fn" >/dev/null; then
      printf '[x] 找不到簇起点 %s:%s\n' "$file" "$start_fn" >&2
      failed=1
    fi
    if ! lookup_function "$file" "$end_fn" >/dev/null; then
      printf '[x] 找不到簇终点 %s:%s\n' "$file" "$end_fn" >&2
      failed=1
    fi
  done

  local tmp
  tmp="$(mktemp -d)"
  generate_index_md >"$tmp/INDEX.md"
  generate_symbols_tsv >"$tmp/core-symbols.tsv"
  if [[ ! -f "$ROOT_DIR/$INDEX_MD" || ! -f "$ROOT_DIR/$SYMBOLS_TSV" ]]; then
    printf '[x] 缺少生成索引。请运行：bash scripts/maintainer-map.sh --write-index\n' >&2
    failed=1
  else
    if ! diff -u "$ROOT_DIR/$INDEX_MD" "$tmp/INDEX.md" >/dev/null; then
      printf '[x] %s 已过期。请运行：bash scripts/maintainer-map.sh --write-index\n' "$INDEX_MD" >&2
      failed=1
    fi
    if ! diff -u "$ROOT_DIR/$SYMBOLS_TSV" "$tmp/core-symbols.tsv" >/dev/null; then
      printf '[x] %s 已过期。请运行：bash scripts/maintainer-map.sh --write-index\n' "$SYMBOLS_TSV" >&2
      failed=1
    fi
  fi
  if ! grep -Eq $'\tsafe_write_config_file\t' "$tmp/core-symbols.tsv"; then
    printf '[x] 符号表缺少 safe_write_config_file\n' >&2
    failed=1
  fi
  rm -rf "$tmp"

  if ((failed != 0)); then
    return 1
  fi
  printf '[✓] 维护导航中的 %d 个区域、簇锚点和生成索引均有效。\n' "${#MAP_ROWS[@]}"
}

main() {
  case "${1:-}" in
    -h|--help|'') usage ;;
    --list) list_areas ;;
    --check) check_map ;;
    --write-index) write_index ;;
    --ai|--slice)
      shift
      ai_find "$*"
      ;;
    *) find_area "$*" ;;
  esac
}

main "$@"
