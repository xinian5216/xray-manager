#!/usr/bin/env bash
# Anonymous end-to-end verification against the real public repository on a
# clean Linux host (GitHub-hosted runner or disposable VPS):
#   fresh install -> self-update -> four Xray version selection modes ->
#   GeoData update -> legacy Manager migration (GitHub Private + Cloudflare/R2).
# No token of any kind is required or sent; anonymity is proven via the
# anonymous GitHub API rate limit (60/hour).
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_RAW="https://raw.githubusercontent.com/xinian5216/xray-manager/main"

fail() {
  printf 'anonymous-public-verify: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "缺少 curl。"
command -v git >/dev/null 2>&1 || fail "缺少 git（用于历史版本 fixture）。"
command -v jq >/dev/null 2>&1 || fail "缺少 jq。"
command -v timeout >/dev/null 2>&1 || fail "缺少 timeout（coreutils）。"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || {
  echo "Run this script as root (sudo bash tests/anonymous-public-verify.sh)." >&2
  exit 1
}

EXPECTED_VERSION="$(tr -d '[:space:]' <"$ROOT_DIR/VERSION")"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "仓库 VERSION 无效：$EXPECTED_VERSION"

# Pinned historical commits (ancestors of main; extracted via git show).
FIXTURE_SHA_123="1d16c8c45fda17b86b74f59b75365d878a959950" # v1.2.3 fixed / GitHub Private
FIXTURE_SHA_184="3ed1554c34d39f5380a8f171f90ed60752fda7e8" # v1.8.4 atomic / Cloudflare+R2

# Running git as root in the runner-owned checkout needs this explicit trust.
export GIT_CONFIG_COUNT="1"
export GIT_CONFIG_KEY_0="safe.directory"
export GIT_CONFIG_VALUE_0="$ROOT_DIR"

fetch_legacy_fixture() {
  local ver="$1" sha="$2" dir="$3"
  if ! git -C "$ROOT_DIR" cat-file -e "$sha:xray-manager.sh" 2>/dev/null; then
    timeout 60 git -C "$ROOT_DIR" fetch --quiet --depth=1 origin "$sha" 2>/dev/null || \
      fail "无法获取历史 fixture v$ver；请先 git fetch --depth=1 origin $sha"
  fi
  mkdir -p "$dir/lib"
  git -C "$ROOT_DIR" show "$sha:xray-manager.sh" >"$dir/xray-manager.sh"
  git -C "$ROOT_DIR" show "$sha:lib/xray-manager-core.sh" >"$dir/lib/xray-manager-core.sh"
  chmod 755 "$dir/xray-manager.sh" "$dir/lib/xray-manager-core.sh"
}

# Per-case timeout applies to every real installer execution below.
INSTALLER_TIMEOUT="${XRAY_TEST_CASE_TIMEOUT:-420}"
CURRENT_CASE=""
CASE_LOG=""
CASE_STARTED=0
WATCHDOG_PID=""
TEST_START=$SECONDS
VERIFY_DIR="$(mktemp -d)"

cleanup_all() {
  local rc=$?
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if (( rc != 0 )); then
    printf 'CASE FAILED: %s (elapsed %ss)\n' "${CURRENT_CASE:-unknown}" "$(( SECONDS - CASE_STARTED ))" >&2
    if [[ -n "$CASE_LOG" && -f "$CASE_LOG" ]]; then
      printf -- '--- case log tail (%s) ---\n' "$CASE_LOG" >&2
      tail -40 "$CASE_LOG" >&2 || true
    fi
  fi
  rm -rf "$VERIFY_DIR"
}
trap cleanup_all EXIT

run_case() { # $1 case name, $2 case function
  local name="$1"
  shift
  CURRENT_CASE="$name"
  CASE_LOG="$VERIFY_DIR/$name.log"
  CASE_STARTED=$SECONDS
  printf 'CASE START: %s\n' "$name"
  "$@"
  printf 'CASE PASS: %s (%ss)\n' "$name" "$(( SECONDS - CASE_STARTED ))"
}

read_project_version_from() {
  sed -n 's/^PROJECT_VERSION="\([^"]*\)".*/\1/p' "$1" | head -n1
}

state_fingerprint() {
  (
    cd /etc/xray-manager
    find . -type f ! -name manager_update_source ! -name cloudflare_url -print0 |
      sort -z | xargs -0 -r sha256sum
    find . -type f ! -name manager_update_source ! -name cloudflare_url -printf '%m %p\n' | sort
  )
}

# ---------------------------------------------------------------------------
# Cases.
# ---------------------------------------------------------------------------

case_clean_environment() {
  unset XRAY_MANAGER_GITHUB_TOKEN GH_TOKEN
  [[ -z "${XRAY_MANAGER_GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]] || fail "Token 环境变量未清空"
  [[ ! -f "$HOME/.netrc" ]] || fail "存在 ~/.netrc"
  if command -v gh >/dev/null 2>&1; then
    gh auth status >/dev/null 2>&1 && fail "gh CLI 处于登录状态"
  fi
  git config --global --get-all credential.helper >/dev/null 2>&1 && \
    fail "存在全局 git credential helper"
  # Anonymous GitHub API limit is 60/hour; an authenticated token reports 5000.
  curl -fsS -D "$VERIFY_DIR/rate.headers" "https://api.github.com/rate_limit" -o /dev/null
  grep -iq '^x-ratelimit-limit: 60' "$VERIFY_DIR/rate.headers" || \
    fail "匿名限速验证失败（x-ratelimit-limit != 60，疑似带凭据）"
}

case_fresh_install() {
  curl -fsSLo "$VERIFY_DIR/installer.sh" "$REPO_RAW/install.sh"
  local out
  out="$(timeout -k 10 "$INSTALLER_TIMEOUT" bash "$VERIFY_DIR/installer.sh" 2>&1)" || \
    fail "install.sh 执行失败：$(tail -5 <<<"$out")"
  printf '%s\n' "$out" >"$CASE_LOG"
  grep -Fq "Xray Manager 项目版本 $EXPECTED_VERSION 安装完成" <<<"$out" || \
    fail "安装未输出完成提示：$(tail -3 <<<"$out")"
  local ver_out
  ver_out="$(/usr/local/sbin/xraym --version </dev/null 2>&1)" || \
    fail "xraym --version 运行失败：$ver_out"
  grep -Fq "Xray Manager project: $EXPECTED_VERSION" <<<"$ver_out" || \
    fail "xraym --version 输出不符：$ver_out"
}

case_self_update() {
  local out
  out="$(printf 'y\n' | sudo /usr/local/sbin/xraym --self-update 2>&1)" || \
    fail "匿名 self-update 失败：$(tail -5 <<<"$out")"
  grep -Fq "Xray Manager 已更新到项目版本：$EXPECTED_VERSION" <<<"$out" || \
    fail "self-update 输出异常：$(tail -3 <<<"$out")"
}

case_version_selection() {
  CORE_SRC="/usr/local/lib/xray-manager/current/xray-manager-core.sh"
  [[ -f "$CORE_SRC" ]] || fail "未找到已安装 Core：$CORE_SRC"
  # shellcheck source=/dev/null
  source "$CORE_SRC"
  detect_platform
  load_network_state
  ASSET_NAME="$(xray_github_asset_name)" || fail "无法确定架构资产名"
  RELEASES_FILE="$VERIFY_DIR/xray-releases.json"
  xray_github_fetch_releases "$RELEASES_FILE" || fail "GitHub Releases 列表获取失败"
  LATEST_PUBLISHED="$(xray_github_latest_published "$RELEASES_FILE" "$ASSET_NAME")"
  STABLE_LATEST="$(xray_github_latest_stable "$RELEASES_FILE" "$ASSET_NAME")"
  [[ -n "$LATEST_PUBLISHED" ]] || fail "最新发布版为空"
  [[ -n "$STABLE_LATEST" ]] || fail "最新稳定版为空"
  [[ "$(awk -F'\t' '{print $2}' <<<"$STABLE_LATEST")" == "false" ]] || \
    fail "最新稳定版不是 Stable：$STABLE_LATEST"
  HISTORY_LINES="$(xray_github_release_history "$RELEASES_FILE" "$ASSET_NAME" 15)"
  [[ "$(grep -c . <<<"$HISTORY_LINES")" -ge 3 ]] || fail "历史版本列表异常"
  BASELINE_TAG="$(xray_version_normalize "$(tr -d '[:space:]' <"$ROOT_DIR/XRAY_VERSION")")" || \
    fail "基线版本标准化失败"
  BASELINE_LINE="$(xray_github_lookup_tag "$RELEASES_FILE" "$BASELINE_TAG" "$ASSET_NAME")"
  [[ -n "$BASELINE_LINE" ]] || fail "基线版本 $BASELINE_TAG 不在可安装列表"
}

case_four_version_modes() {
  CORE_SRC="/usr/local/lib/xray-manager/current/xray-manager-core.sh"
  # shellcheck source=/dev/null
  source "$CORE_SRC"
  detect_platform
  load_network_state
  ASSET_NAME="$(xray_github_asset_name)"
  RELEASES_FILE="$VERIFY_DIR/xray-releases.json"
  [[ -s "$RELEASES_FILE" ]] || xray_github_fetch_releases "$RELEASES_FILE"

  local latest_tag stable_tag history_tag manual_tag target mode
  latest_tag="$(awk -F'\t' '{print $1}' <<<"$LATEST_PUBLISHED")"
  stable_tag="$(awk -F'\t' '{print $1}' <<<"$STABLE_LATEST")"
  history_tag="$(sed -n '2p' <<<"$HISTORY_LINES" | awk -F'\t' '{print $1}')"
  manual_tag="$BASELINE_TAG"

  for mode in latest stable history manual; do
    case "$mode" in
      latest)  target="$latest_tag" ;;
      stable)  target="$stable_tag" ;;
      history) target="$history_tag" ;;
      manual)  target="$manual_tag" ;;
    esac
    [[ -n "$target" ]] || fail "$mode 模式目标版本为空"
    xray_install_selected_version "$target" || \
      fail "$mode 模式安装 $target 失败（xray.service: $(systemctl is-active xray 2>&1 || true)）"
    local installed
    installed="$(xray_current_version)" || fail "安装后无法读取 Xray 版本"
    [[ "$installed" == "$target" ]] || fail "$mode 模式安装后版本不符：$installed != $target"
    # Each mode triggers two systemd starts (the XTLS installer starts the
    # service, then the Manager restarts it). systemd's default StartLimit is
    # 5 starts / 10s, so back-to-back modes can exhaust it and produce a
    # spurious "Job for xray.service failed." Wait for the service to settle
    # before the next real installation.
    sleep "${XRAY_VERIFY_MODE_SETTLE:-6}"
  done
}

case_geodata_update() {
  CORE_SRC="/usr/local/lib/xray-manager/current/xray-manager-core.sh"
  # shellcheck source=/dev/null
  source "$CORE_SRC"
  detect_platform
  load_network_state
  update_geodata || fail "GeoData 更新失败"
  [[ -s /usr/local/share/xray/geoip.dat && -s /usr/local/share/xray/geosite.dat ]] || \
    fail "GeoData 文件缺失"
}

seed_legacy_cloudflare() {
  local fixture="$VERIFY_DIR/fixture-1.8.4"
  fetch_legacy_fixture 1.8.4 "$FIXTURE_SHA_184" "$fixture"
  rm -rf /usr/local/lib/xray-manager
  local rel="/usr/local/lib/xray-manager/releases/1.8.4"
  mkdir -p "$rel" /usr/local/sbin /etc/xray-manager/conf.d \
    /etc/xray-manager/wireguard/wg-client /etc/xray-manager/backups/mig /etc/xray-manager/certs
  install -m 755 "$fixture/xray-manager.sh" "$rel/xray-manager.sh"
  install -m 755 "$fixture/lib/xray-manager-core.sh" "$rel/xray-manager-core.sh"
  ln -s "releases/1.8.4" /usr/local/lib/xray-manager/current
  ln -s /usr/local/lib/xray-manager/current/xray-manager.sh /usr/local/sbin/xraym
  ln -s /usr/local/lib/xray-manager/current/xray-manager-core.sh \
    /usr/local/lib/xray-manager/xray-manager-core.sh
  printf 'cloudflare\n' >/etc/xray-manager/manager_update_source
  printf 'https://worker.example.invalid\n' >/etc/xray-manager/cloudflare_url
  printf '{\n  "custom": "preserve-me-2077"\n}\n' >/etc/xray-manager/conf.d/99_custom.json
  printf 'WG_PRIVATE_KEY_FIXTURE_2077\n' >/etc/xray-manager/wireguard/wg-client/private.key
  chmod 600 /etc/xray-manager/wireguard/wg-client/private.key
  printf 'fake-backup-archive-bytes\n' >/etc/xray-manager/backups/mig/config.tar.gz
  printf 'CERT-FIXTURE-PEM-BYTES\n' >/etc/xray-manager/certs/server.pem
}

seed_legacy_github() {
  local fixture="$VERIFY_DIR/fixture-1.2.3"
  fetch_legacy_fixture 1.2.3 "$FIXTURE_SHA_123" "$fixture"
  rm -rf /usr/local/lib/xray-manager
  mkdir -p /usr/local/lib/xray-manager /usr/local/sbin /etc/xray-manager/conf.d
  install -m 755 "$fixture/xray-manager.sh" /usr/local/sbin/xraym
  install -m 755 "$fixture/lib/xray-manager-core.sh" \
    /usr/local/lib/xray-manager/xray-manager-core.sh
  printf 'github\n' >/etc/xray-manager/manager_update_source
}

case_legacy_cloudflare_r2() {
  seed_legacy_cloudflare
  state_fingerprint >"$VERIFY_DIR/cf-before.txt"
  local out
  out="$(timeout -k 10 "$INSTALLER_TIMEOUT" bash "$VERIFY_DIR/installer.sh" 2>&1)" || \
    fail "Cloudflare 旧版迁移失败：$(tail -5 <<<"$out")"
  grep -Fq '检测到旧版 Cloudflare/R2 安装' <<<"$out" || fail "缺少 Cloudflare 检测提示"
  grep -Fq 'Xray Manager 迁移完成' <<<"$out" || fail "缺少迁移汇总"
  grep -Fq '旧 Cloudflare 状态：已清理' <<<"$out" || fail "缺少 Cloudflare 清理确认"
  [[ "$(read_project_version_from /usr/local/lib/xray-manager/current/xray-manager.sh)" == "$EXPECTED_VERSION" ]] || \
    fail "迁移后 Launcher 版本不符"
  if [[ -e /etc/xray-manager/manager_update_source || -e /etc/xray-manager/cloudflare_url ]]; then
    fail "退役更新源状态未清理"
  fi
  [[ "$(read_project_version_from "$(readlink -f /usr/local/lib/xray-manager/previous)/xray-manager.sh")" == "1.8.4" ]] || \
    fail "previous 未保留 v1.8.4"
  state_fingerprint >"$VERIFY_DIR/cf-after.txt"
  cmp -s "$VERIFY_DIR/cf-before.txt" "$VERIFY_DIR/cf-after.txt" || fail "迁移修改了 Xray 数据"
}

case_legacy_github_private() {
  seed_legacy_github
  state_fingerprint >"$VERIFY_DIR/gh-before.txt"
  local out
  out="$(timeout -k 10 "$INSTALLER_TIMEOUT" bash "$VERIFY_DIR/installer.sh" 2>&1)" || \
    fail "GitHub Private 旧版迁移失败：$(tail -5 <<<"$out")"
  grep -Fq '检测到旧版 GitHub Private 安装' <<<"$out" || fail "缺少 GitHub Private 提示"
  grep -Fq '以后默认无需 PAT' <<<"$out" || fail "缺少无需 PAT 提示"
  [[ "$(read_project_version_from /usr/local/lib/xray-manager/current/xray-manager.sh)" == "$EXPECTED_VERSION" ]] || \
    fail "迁移后 Launcher 版本不符"
  [[ ! -e /etc/xray-manager/manager_update_source ]] || fail "旧更新源状态未清理"
  [[ "$(read_project_version_from "$(readlink -f /usr/local/lib/xray-manager/previous)/xray-manager.sh")" == "1.2.3" ]] || \
    fail "previous 未保留 v1.2.3"
  state_fingerprint >"$VERIFY_DIR/gh-after.txt"
  cmp -s "$VERIFY_DIR/gh-before.txt" "$VERIFY_DIR/gh-after.txt" || fail "迁移修改了 Xray 数据"
}

# ---------------------------------------------------------------------------
# Total timeout watchdog.
# ---------------------------------------------------------------------------
TOTAL_TIMEOUT="${XRAY_TEST_TOTAL_TIMEOUT:-1200}"
(
  sleep "$TOTAL_TIMEOUT"
  printf 'TOTAL TIMEOUT after %ss（当前 case 见上方最后的 CASE START 行）\n' "$TOTAL_TIMEOUT" >&2
  kill -TERM "$PPID" 2>/dev/null || true
) &
WATCHDOG_PID=$!

TEST_START=$SECONDS
unset XRAY_MANAGER_GITHUB_TOKEN GH_TOKEN

run_case clean-environment     case_clean_environment
run_case fresh-install         case_fresh_install
run_case anonymous-self-update case_self_update
run_case version-selection-api case_version_selection
run_case four-version-modes    case_four_version_modes
run_case geodata-update        case_geodata_update
run_case legacy-cf-r2-migrate  case_legacy_cloudflare_r2
run_case legacy-github-private case_legacy_github_private

kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
printf 'Anonymous public verification passed (%ss total).\n' "$(( SECONDS - TEST_START ))"
