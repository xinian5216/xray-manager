#!/usr/bin/env bash
# Legacy Xray Manager -> current GitHub Public installer migration coverage.
# Fixtures are real historical Launcher/Core files extracted from pinned
# git-history commits; the migration path must never execute old manager code
# (checked via execution canaries). Run as root: sudo bash tests/legacy-manager-upgrade.sh
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

# Running git as root in the runner-owned checkout needs this explicit trust.
export GIT_CONFIG_COUNT="1"
export GIT_CONFIG_KEY_0="safe.directory"
export GIT_CONFIG_VALUE_0="$ROOT_DIR"

fail() {
  printf 'legacy-manager-upgrade: %s\n' "$*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || fail "需要 git 以提取历史版本 fixture。"
command -v sha256sum >/dev/null 2>&1 || fail "缺少 sha256sum。"
command -v curl >/dev/null 2>&1 || fail "缺少 curl。"
command -v timeout >/dev/null 2>&1 || fail "缺少 timeout（coreutils）。"

# Atomic current/previous layout assertions need real symlink support.
SYM_TGT="$TEST_ROOT/.symtarget"
SYM_LNK="$TEST_ROOT/.symlink"
: >"$SYM_TGT"
ln -s "$SYM_TGT" "$SYM_LNK" 2>/dev/null || \
  fail "当前环境不支持符号链接（Windows/MSYS）；请在 Linux/CI 运行本测试。"
[[ -L "$SYM_LNK" ]] || fail "符号链接创建异常，请在 Linux/CI 运行本测试。"
rm -f "$SYM_LNK" "$SYM_TGT"

# The dependency bootstrap path of the real downloaded Core is executed, so the
# test must run as root (same requirement as tests/bootstrap-install.sh).
[[ "${EUID:-$(id -u)}" -eq 0 ]] || {
  echo "Run this test as root so the bootstrap dependency path is exercised." >&2
  exit 1
}

# Pinned historical commits (ancestors of main; extracted via git show).
FIXTURE_SHA_123="1d16c8c45fda17b86b74f59b75365d878a959950" # v1.2.3 fixed / GitHub Private
FIXTURE_SHA_141="4ff50689d07ea90a2d1d6324f51d674e2a144de9" # v1.4.1 fixed / Cloudflare era
FIXTURE_SHA_160="6d869a28313ccfb38841a79eb25abb2b65bea36a" # v1.6.0 fixed / Cloudflare era
FIXTURE_SHA_183="6121a32f0dc99464f6726e34800bad7b85b598fb" # v1.8.3 atomic / GitHub
FIXTURE_SHA_184="3ed1554c34d39f5380a8f171f90ed60752fda7e8" # v1.8.4 atomic / Cloudflare+R2

REPO_VERSION="$(tr -d '[:space:]' <"$ROOT_DIR/VERSION")"
[[ "$REPO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "仓库 VERSION 无效：$REPO_VERSION"

FIXTURES="$TEST_ROOT/fixtures"
mkdir -p "$FIXTURES"

# Real-network extraction of one pinned ancestor commit; hard-bounded.
fetch_legacy_fixture() {
  local ver="$1" sha="$2"
  local dir="$FIXTURES/$ver" observed
  [[ -x "$dir/xray-manager.sh" ]] && return 0
  if ! git -C "$ROOT_DIR" cat-file -e "$sha:xray-manager.sh" 2>/dev/null; then
    timeout 30 git -C "$ROOT_DIR" fetch --quiet --depth=1 origin "$sha" 2>/dev/null || \
      fail "无法获取历史 fixture v$ver；请先 git fetch --depth=1 origin $sha"
  fi
  mkdir -p "$dir/lib"
  git -C "$ROOT_DIR" show "$sha:xray-manager.sh" >"$dir/xray-manager.sh"
  git -C "$ROOT_DIR" show "$sha:lib/xray-manager-core.sh" >"$dir/lib/xray-manager-core.sh"
  chmod 755 "$dir/xray-manager.sh" "$dir/lib/xray-manager-core.sh"
  observed="$(grep -m1 '^PROJECT_VERSION=' "$dir/xray-manager.sh" | sed 's/^PROJECT_VERSION="\([^"]*\)".*/\1/')"
  [[ "$observed" == "$ver" ]] || fail "fixture v$ver 版本标记异常：$observed"
}

for spec in "1.2.3:$FIXTURE_SHA_123" "1.4.1:$FIXTURE_SHA_141" \
            "1.6.0:$FIXTURE_SHA_160" "1.8.3:$FIXTURE_SHA_183" "1.8.4:$FIXTURE_SHA_184"; do
  fetch_legacy_fixture "${spec%%:*}" "${spec##*:}"
done

MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"

build_base_fixtures() {
  local dest="$1"
  mkdir -p "$dest/lib"
  cp "$ROOT_DIR/xray-manager.sh" "$dest/xray-manager.sh"
  cp "$ROOT_DIR/lib/xray-manager-core.sh" "$dest/lib/xray-manager-core.sh"
  cp "$ROOT_DIR/VERSION" "$dest/VERSION"
  # Normalize the separator so verify_payload's awk lookup matches on MSYS too.
  (cd "$dest" && sha256sum xray-manager.sh lib/xray-manager-core.sh | sed 's/^\([0-9a-f]*\) \*/\1  /' >SHA256SUMS)
}

BASE_FIXTURES="$TEST_ROOT/mock-base"
build_base_fixtures "$BASE_FIXTURES"

# curl mock: serves the current repository files; records every URL and every
# Authorization header; refuses any endpoint outside the GitHub contents API,
# so the retired Cloudflare Worker/R2 endpoints can never be contacted.
cat >"$MOCK_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url_log="${XRAY_TEST_URL_LOG:-/dev/null}"
hdr_log="${XRAY_TEST_HEADER_LOG:-/dev/null}"
out=""
url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o) out="${args[$((i + 1))]}" ;;
    http://*|https://*) url="${args[$i]}" ;;
    Authorization:*) printf '%s\n' "${args[$i]}" >>"$hdr_log" ;;
  esac
done
[[ -n "$url" && -n "$out" ]] || { echo "curl mock: missing url/out" >&2; exit 2; }
printf '%s\n' "$url" >>"$url_log"
case "$url" in
  */contents/VERSION*) source_file="VERSION" ;;
  */contents/SHA256SUMS*) source_file="SHA256SUMS" ;;
  */contents/lib/xray-manager-core.sh*) source_file="lib/xray-manager-core.sh" ;;
  */contents/xray-manager.sh*) source_file="xray-manager.sh" ;;
  *) echo "Unexpected URL: $url" >&2; exit 2 ;;
esac
if [[ "${XRAY_TEST_HTTP_STATUS:-200}" != "200" ]]; then
  printf '%s' "$XRAY_TEST_HTTP_STATUS"
  exit 22
fi
cp "$XRAY_TEST_FIXTURES/$source_file" "$out"
printf '200'
SH

# apt-get mock: package-manager side effects are out of scope here (covered by
# tests/bootstrap-install.sh); every invocation is logged only.
cat >"$MOCK_BIN/apt-get" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${XRAY_TEST_APT_LOG:-/dev/null}"
exit 0
SH

chmod 755 "$MOCK_BIN/curl" "$MOCK_BIN/apt-get"

read_project_version() {
  local file="$1" version
  [[ -f "$file" ]] || return 1
  version="$(sed -n 's/^PROJECT_VERSION="\([^"]*\)".*/\1/p' "$file" | head -n1)"
  [[ -n "$version" ]] || return 1
  printf '%s' "$version"
}

read_core_version() {
  local file="$1" version
  [[ -f "$file" ]] || return 1
  version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$file" | head -n1)"
  [[ -n "$version" ]] || return 1
  printf '%s' "$version"
}

current_dir() {
  readlink -f "$LIB_DIR/current"
}

previous_dir() {
  readlink -f "$LIB_DIR/previous"
}

new_scenario() {
  INSTALL_ROOT="$TEST_ROOT/$1"
  STATE_ROOT="$INSTALL_ROOT/etc/xray-manager"
  LIB_DIR="$INSTALL_ROOT/usr/local/lib/xray-manager"
  INSTALL_PATH="$INSTALL_ROOT/usr/local/sbin/xraym"
  CORE_PATH="$LIB_DIR/xray-manager-core.sh"
  URL_LOG="$INSTALL_ROOT/urls.log"
  HDR_LOG="$INSTALL_ROOT/headers.log"
  APT_LOG="$INSTALL_ROOT/apt.log"
  rm -rf "$INSTALL_ROOT"
  mkdir -p "$INSTALL_ROOT" "$STATE_ROOT" "$LIB_DIR"
  : >"$URL_LOG"; : >"$HDR_LOG"; : >"$APT_LOG"
}

# Per-case observability and failure diagnostics.
CASE_SECONDS_LIMIT="${XRAY_TEST_CASE_TIMEOUT:-60}"
CURRENT_CASE=""
CASE_LOG=""
CASE_STARTED=0
WATCHDOG_PID=""
TEST_START=$SECONDS

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
  rm -rf "$TEST_ROOT"
}
trap cleanup_all EXIT

run_case() { # $1 case name; the case body follows as a function name
  local name="$1"
  shift
  CURRENT_CASE="$name"
  CASE_LOG="$TEST_ROOT/$name.log"
  CASE_STARTED=$SECONDS
  printf 'CASE START: %s\n' "$name"
  "$@"
  printf 'CASE PASS: %s (%ss)\n' "$name" "$(( SECONDS - CASE_STARTED ))"
}

run_install() { # $1 log, $2 fixtures (optional), $3 FAIL_STEP, $4 HTTP status
  local log="$1" fixtures="${2:-$BASE_FIXTURES}" fail_step="${3:-}" http="${4:-200}" rc=0
  (
    export XRAY_MANAGER_STATE_DIR="$STATE_ROOT"
    export XRAY_MANAGER_INSTALL_PATH="$INSTALL_PATH"
    export XRAY_MANAGER_CORE_PATH="$CORE_PATH"
    export XRAY_MANAGER_LIB_DIR="$LIB_DIR"
    export XRAY_MANAGER_RELEASES_DIR="$LIB_DIR/releases"
    export XRAY_MANAGER_CURRENT_LINK="$LIB_DIR/current"
    export XRAY_MANAGER_PREVIOUS_LINK="$LIB_DIR/previous"
    export XRAY_MANAGER_LOCK_DIR="$INSTALL_ROOT/manager.lock"
    export XRAY_MANAGER_FAIL_STEP="$fail_step"
    export XRAY_TEST_HTTP_STATUS="$http"
    export XRAY_TEST_FIXTURES="$fixtures"
    export XRAY_TEST_URL_LOG="$URL_LOG"
    export XRAY_TEST_HEADER_LOG="$HDR_LOG"
    export XRAY_TEST_APT_LOG="$APT_LOG"
    export PATH="$MOCK_BIN:$PATH"
    # /dev/null stdin: any accidental interactive read fails fast instead of
    # blocking CI; the installer path has no interactive prompts.
    timeout -k 5 "$CASE_SECONDS_LIMIT" \
      env -u XRAY_MANAGER_GITHUB_TOKEN -u GH_TOKEN bash "$ROOT_DIR/install.sh" </dev/null
  ) >"$log" 2>&1 || rc=$?
  return "$rc"
}

seed_fixed_layout() {
  local ver="$1"
  mkdir -p "$LIB_DIR" "$(dirname "$INSTALL_PATH")"
  install -m 755 "$FIXTURES/$ver/xray-manager.sh" "$INSTALL_PATH"
  install -m 755 "$FIXTURES/$ver/lib/xray-manager-core.sh" "$CORE_PATH"
  [[ ! -L "$INSTALL_PATH" ]] || fail "seed: 旧 Launcher 意外为符号链接"
}

seed_atomic_layout() {
  local ver="$1"
  local rel="$LIB_DIR/releases/$ver"
  mkdir -p "$rel" "$(dirname "$INSTALL_PATH")"
  install -m 755 "$FIXTURES/$ver/xray-manager.sh" "$rel/xray-manager.sh"
  install -m 755 "$FIXTURES/$ver/lib/xray-manager-core.sh" "$rel/xray-manager-core.sh"
  ln -s "releases/$ver" "$LIB_DIR/current"
  ln -s "$LIB_DIR/current/xray-manager.sh" "$INSTALL_PATH"
  ln -s "$LIB_DIR/current/xray-manager-core.sh" "$CORE_PATH"
}

seed_cloudflare_state() {
  printf 'cloudflare\n' >"$STATE_ROOT/manager_update_source"
  printf 'https://worker.example.invalid\n' >"$STATE_ROOT/cloudflare_url"
}

seed_github_state() {
  printf 'github\n' >"$STATE_ROOT/manager_update_source"
}

seed_xray_data() {
  mkdir -p "$STATE_ROOT/conf.d" "$STATE_ROOT/wireguard/wg-client" \
    "$STATE_ROOT/backups/xray-core-1" "$STATE_ROOT/certs"
  printf '{\n  "custom": "preserve-me-2077"\n}\n' >"$STATE_ROOT/conf.d/99_custom.json"
  printf 'WG_PRIVATE_KEY_FIXTURE_2077\n' >"$STATE_ROOT/wireguard/wg-client/private.key"
  chmod 600 "$STATE_ROOT/wireguard/wg-client/private.key"
  printf 'fake-backup-archive-bytes\n' >"$STATE_ROOT/backups/xray-core-1/config.tar.gz"
  printf 'CERT-FIXTURE-PEM-BYTES\n' >"$STATE_ROOT/certs/server.pem"
}

state_fingerprint() {
  (
    cd "$STATE_ROOT"
    find . -type f ! -name manager_update_source ! -name cloudflare_url -print0 |
      sort -z | xargs -0 -r sha256sum
    find . -type f ! -name manager_update_source ! -name cloudflare_url -printf '%m %p\n' | sort
  )
}

assert_markers_gone() {
  [[ ! -e "$STATE_ROOT/manager_update_source" ]] || fail "manager_update_source 未清理"
  [[ ! -e "$STATE_ROOT/cloudflare_url" ]] || fail "cloudflare_url 未清理"
}

assert_markers_kept() {
  [[ -e "$STATE_ROOT/manager_update_source" ]] || fail "失败场景中 manager_update_source 被提前删除"
  [[ -e "$STATE_ROOT/cloudflare_url" ]] || fail "失败场景中 cloudflare_url 被提前删除"
}

assert_new_layout() {
  local expect="$1" cur
  [[ -L "$INSTALL_PATH" ]] || fail "xraym 未变为符号链接"
  [[ -L "$LIB_DIR/current" ]] || fail "current 不是符号链接"
  [[ -L "$CORE_PATH" ]] || fail "兼容 Core 不是符号链接"
  cur="$(readlink -f "$LIB_DIR/current")"
  [[ -f "$cur/xray-manager.sh" && -f "$cur/xray-manager-core.sh" ]] || fail "release 文件缺失"
  [[ "$(read_project_version "$cur/xray-manager.sh")" == "$expect" ]] || \
    fail "Launcher 版本不是 $expect"
  [[ "$(read_core_version "$cur/xray-manager-core.sh")" == "$expect" ]] || \
    fail "Core 版本不是 $expect"
  [[ "$(readlink -f "$INSTALL_PATH")" == "$cur/xray-manager.sh" ]] || \
    fail "xraym 未指向 current"
  local version_output
  version_output="$(XRAY_MANAGER_INSTALL_PATH="$INSTALL_PATH" \
    XRAY_MANAGER_CORE_PATH="$CORE_PATH" \
    XRAY_MANAGER_LIB_DIR="$LIB_DIR" \
    bash "$INSTALL_PATH" --version </dev/null 2>&1)" || \
    fail "xraym --version 运行失败：$version_output"
  printf '%s\n' "$version_output" | grep -Fq "Xray Manager project: $expect" || \
    fail "xraym --version 输出不符：$version_output"
}

assert_backup_preserved() {
  local backup old_launcher_hash backup_hash
  backup="$(find "$LIB_DIR/migration-backup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1 || true)"
  [[ -n "$backup" && -f "$backup/migration.info" ]] || fail "迁移备份缺失"
  grep -Fq 'type=' "$backup/migration.info" || fail "迁移备份缺少类型记录"
  if [[ -f "$backup/xraym" ]]; then
    old_launcher_hash="$(sha256sum "$1" | awk '{print $1}')"
    backup_hash="$(sha256sum "$backup/xraym" | awk '{print $1}')"
    [[ "$old_launcher_hash" == "$backup_hash" ]] || fail "备份 Launcher 与旧文件不一致"
  fi
}

assert_no_legacy_execution() {
  [[ ! -e "$1" ]] || fail "检测到旧版 Manager 代码被执行（迁移不得调用旧 self-update）"
}

assert_url_log_only_github() {
  grep -Fq 'api.github.com' "$URL_LOG" || fail "未记录到 GitHub API 请求"
  if grep -Evq 'api\.github\.com' "$URL_LOG"; then
    grep -Ev 'api\.github\.com' "$URL_LOG" | head -3 >&2
    fail "迁移访问了非 GitHub 端点"
  fi
}

assert_anonymous() {
  [[ ! -s "$HDR_LOG" ]] || fail "匿名迁移不应发送 Authorization 头"
  grep -Fq '未提供 GitHub Token，将匿名读取公开仓库' "$1" || fail "安装未走匿名路径"
}

before_state="$(mktemp)"
after_state="$(mktemp)"
snapshot_to() {
  state_fingerprint >"$1"
}

# ---------------------------------------------------------------------------
# Case functions (one per scenario) — each wrapped by run_case for timing.
# ---------------------------------------------------------------------------

case_fresh_install() {
  new_scenario fresh
  seed_xray_data
  state_fingerprint >"$before_state"
  run_install "$CASE_LOG" || \
    fail "fresh install 失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  snapshot_to "$after_state"
  cmp -s "$before_state" "$after_state" || fail "fresh install 修改了 Xray 数据"
  grep -Fq '未检测到旧版 Xray Manager，将执行全新安装' "$CASE_LOG" ||
    fail "fresh install 未输出全新安装提示"
  if grep -Fq '迁移完成' "$CASE_LOG"; then
    fail "fresh install 不应输出迁移汇总"
  fi
  [[ ! -e "$LIB_DIR/migration-backup" ]] || fail "fresh install 不应创建迁移备份"
  assert_url_log_only_github
}

case_legacy_123_github() {
  new_scenario legacy123
  fetch_legacy_fixture 1.2.3 "$FIXTURE_SHA_123"
  seed_fixed_layout 1.2.3
  seed_github_state
  seed_xray_data
  state_fingerprint >"$before_state"
  run_install "$CASE_LOG" || \
    fail "v1.2.3 迁移失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  assert_markers_gone
  snapshot_to "$after_state"
  cmp -s "$before_state" "$after_state" || fail "v1.2.3 迁移修改了 Xray 数据"
  [[ "$(read_project_version "$(previous_dir)/xray-manager.sh")" == "1.2.3" ]] || \
    fail "previous 未保留 v1.2.3"
  assert_backup_preserved "$FIXTURES/1.2.3/xray-manager.sh"
  grep -Fq '检测到旧版 GitHub Private 安装' "$CASE_LOG" || fail "缺少 GitHub Private 提示"
  grep -Fq '以后默认无需 PAT' "$CASE_LOG" || fail "缺少无需 PAT 提示"
  assert_anonymous "$CASE_LOG"
  assert_url_log_only_github
}

case_legacy_141_cloudflare() {
  new_scenario legacy141
  fetch_legacy_fixture 1.4.1 "$FIXTURE_SHA_141"
  seed_fixed_layout 1.4.1
  seed_cloudflare_state
  seed_xray_data
  state_fingerprint >"$before_state"
  run_install "$CASE_LOG" || \
    fail "v1.4.1 迁移失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  assert_markers_gone
  snapshot_to "$after_state"
  cmp -s "$before_state" "$after_state" || fail "v1.4.1 迁移修改了 Xray 数据"
  assert_backup_preserved "$FIXTURES/1.4.1/xray-manager.sh"
  grep -Fq '检测到旧版 Cloudflare/R2 安装' "$CASE_LOG" || fail "缺少 Cloudflare 提示"
  grep -Fq '旧 Cloudflare 状态：已清理' "$CASE_LOG" || fail "缺少 Cloudflare 清理确认"
  assert_url_log_only_github
  if grep -q 'worker.example.invalid' "$URL_LOG"; then
    fail "迁移访问了已退役 Worker"
  fi
}

case_legacy_160_cloudflare() {
  new_scenario legacy160
  fetch_legacy_fixture 1.6.0 "$FIXTURE_SHA_160"
  seed_fixed_layout 1.6.0
  seed_cloudflare_state
  seed_xray_data
  run_install "$CASE_LOG" || \
    fail "v1.6.0 迁移失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  assert_markers_gone
  grep -Fq '检测到旧版 Cloudflare/R2 安装' "$CASE_LOG" || fail "缺少 Cloudflare 提示"
  assert_url_log_only_github
}

case_atomic_183_github() {
  new_scenario atomic183
  fetch_legacy_fixture 1.8.3 "$FIXTURE_SHA_183"
  seed_atomic_layout 1.8.3
  seed_github_state
  seed_xray_data
  state_fingerprint >"$before_state"
  run_install "$CASE_LOG" || \
    fail "v1.8.3 升级失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  assert_markers_gone
  snapshot_to "$after_state"
  cmp -s "$before_state" "$after_state" || fail "v1.8.3 升级修改了 Xray 数据"
  [[ "$(read_project_version "$(previous_dir)/xray-manager.sh")" == "1.8.3" ]] || \
    fail "previous 未保留 v1.8.3"
  assert_url_log_only_github
}

case_atomic_184_cloudflare() {
  new_scenario atomic184
  fetch_legacy_fixture 1.8.4 "$FIXTURE_SHA_184"
  seed_atomic_layout 1.8.4
  seed_cloudflare_state
  seed_xray_data
  run_install "$CASE_LOG" || \
    fail "v1.8.4 迁移失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  assert_markers_gone
  grep -Fq 'Xray Manager 迁移完成' "$CASE_LOG" || fail "缺少迁移完成汇总"
  grep -Fq '旧 Cloudflare 状态：已清理' "$CASE_LOG" || fail "缺少 Cloudflare 清理状态"
  assert_url_log_only_github
}

case_current_reinstall() {
  new_scenario reinstall
  run_install "$CASE_LOG" || \
    fail "首次安装失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  run_install "$CASE_LOG" || \
    fail "同版本重装失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  grep -Fq '当前已是仓库版本' "$CASE_LOG" || fail "缺少重装提示"
  [[ ! -e "$LIB_DIR/migration-backup" ]] || fail "同版本重装不应创建迁移备份"
  local_cur="$(readlink -f "$LIB_DIR/current")"
  local_prev="$(readlink -f "$LIB_DIR/previous")"
  [[ -n "$local_prev" && "$local_cur" != "$local_prev" ]] || \
    fail "重装后 previous 应保留独立副本"
}

case_unknown_legacy() {
  new_scenario unknown
  EXEC_CANARY="$TEST_ROOT/legacy-executed"
  CORE_CANARY="$TEST_ROOT/legacy-core-executed"
  mkdir -p "$LIB_DIR" "$(dirname "$INSTALL_PATH")"
  cat >"$INSTALL_PATH" <<EOF
#!/usr/bin/env bash
# 极早期/未知布局的旧版 Xray Manager（无任何版本标记）
if [[ "\${BASH_SOURCE[0]}" == "\$0" ]]; then
  : >"$EXEC_CANARY"
fi
echo "unknown legacy xray manager"
EOF
  cat >"$CORE_PATH" <<EOF
#!/usr/bin/env bash
if [[ "\${BASH_SOURCE[0]}" == "\$0" ]]; then
  : >"$CORE_CANARY"
fi
printf 'legacy core\\n'
EOF
  chmod 755 "$INSTALL_PATH" "$CORE_PATH"
  seed_xray_data
  cp "$INSTALL_PATH" "$TEST_ROOT/unknown-seed-launcher"
  run_install "$CASE_LOG" || \
    fail "unknown legacy 迁移失败：$(tail -5 "$CASE_LOG")"
  assert_new_layout "$REPO_VERSION"
  grep -Fq '检测到无法完整识别版本的旧 Xray Manager 安装' "$CASE_LOG" || \
    fail "缺少 unknown legacy 提示"
  assert_no_legacy_execution "$EXEC_CANARY"
  assert_no_legacy_execution "$CORE_CANARY"
  assert_backup_preserved "$TEST_ROOT/unknown-seed-launcher"
}

# ---------------------------------------------------------------------------
# Failure rollback: legacy CF install must stay fully intact
# ---------------------------------------------------------------------------
failure_scenario() {
  new_scenario "$1"
  fetch_legacy_fixture 1.8.4 "$FIXTURE_SHA_184"
  seed_fixed_layout 1.8.4
  seed_cloudflare_state
  seed_xray_data
  state_fingerprint >"$before_state"
}

# $1 rc, $2 log, $3 backup expected: yes (during install) / no (download/verify)
assert_failure_rollback() {
  local rc="$1" log="$2" backup_expected="$3" backup
  (( rc != 0 )) || fail "失败注入意外成功：$log"
  assert_markers_kept
  snapshot_to "$after_state"
  cmp -s "$before_state" "$after_state" || fail "失败场景修改了 Xray 数据"
  [[ "$(read_project_version "$INSTALL_PATH")" == "1.8.4" ]] || \
    fail "失败场景中旧 Launcher 版本改变"
  [[ -x "$INSTALL_PATH" ]] || fail "失败场景中旧 xraym 不可执行"
  backup="$(find "$LIB_DIR/migration-backup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1 || true)"
  if [[ "$backup_expected" == "yes" ]]; then
    [[ -n "$backup" && -f "$backup/migration.info" ]] || fail "安装中途失败应保留迁移备份"
    grep -Fq 'old_version=1.8.4' "$backup/migration.info" || fail "备份缺少旧版本记录"
  else
    [[ -z "$backup" ]] || fail "下载/校验阶段失败不应创建迁移备份"
  fi
}

run_expect_failure() { # $1 log, $2 fixtures, $3 FAIL_STEP, $4 HTTP -> echoes rc
  local rc=0
  run_install "$1" "${2:-}" "${3:-}" "${4:-200}" || rc=$?
  printf '%s' "$rc"
}

case_fail_download() {
  failure_scenario faildownload
  assert_failure_rollback "$(run_expect_failure "$CASE_LOG" "" "" 500)" \
    "$CASE_LOG" no
  grep -Fq 'GitHub API 下载失败' "$CASE_LOG" || fail "缺少下载失败提示"
}

case_fail_sha() {
  failure_scenario failsha
  BADSUM_FIXTURES="$TEST_ROOT/mock-badsums"
  build_base_fixtures "$BADSUM_FIXTURES"
  sed -i '1s/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
    "$BADSUM_FIXTURES/SHA256SUMS"
  assert_failure_rollback "$(run_expect_failure "$CASE_LOG" "$BADSUM_FIXTURES")" \
    "$CASE_LOG" no
  grep -Fq 'SHA256 校验失败' "$CASE_LOG" || fail "缺少校验失败提示"
}

case_fail_launcher_bashn() {
  failure_scenario failbashn
  BADLN_FIXTURES="$TEST_ROOT/mock-badlauncher"
  build_base_fixtures "$BADLN_FIXTURES"
  printf '\nif true; then\n' >>"$BADLN_FIXTURES/xray-manager.sh"
  (cd "$BADLN_FIXTURES" && sha256sum xray-manager.sh lib/xray-manager-core.sh | \
    sed 's/^\([0-9a-f]*\) \*/\1  /' >SHA256SUMS)
  assert_failure_rollback "$(run_expect_failure "$CASE_LOG" "$BADLN_FIXTURES")" \
    "$CASE_LOG" no
}

case_fail_core_bashn() {
  failure_scenario failcorebashn
  BADCORE_FIXTURES="$TEST_ROOT/mock-badcore"
  build_base_fixtures "$BADCORE_FIXTURES"
  printf '\nif true; then\n' >>"$BADCORE_FIXTURES/lib/xray-manager-core.sh"
  (cd "$BADCORE_FIXTURES" && sha256sum xray-manager.sh lib/xray-manager-core.sh | \
    sed 's/^\([0-9a-f]*\) \*/\1  /' >SHA256SUMS)
  assert_failure_rollback "$(run_expect_failure "$CASE_LOG" "$BADCORE_FIXTURES")" \
    "$CASE_LOG" no
}

case_fail_pair_write() {
  failure_scenario failpair
  assert_failure_rollback "$(run_expect_failure "$CASE_LOG" "" launcher)" \
    "$CASE_LOG" yes
}

case_fail_switch() {
  failure_scenario failswitch
  assert_failure_rollback "$(run_expect_failure "$CASE_LOG" "" switch)" \
    "$CASE_LOG" yes
}

case_fail_selfcheck() {
  failure_scenario failselfcheck
  assert_failure_rollback "$(run_expect_failure "$CASE_LOG" "" selfcheck)" \
    "$CASE_LOG" yes
  [[ "$(read_project_version "$(current_dir)/xray-manager.sh")" == "1.8.4" ]] || \
    fail "selfcheck 失败后 current 未回到旧版本"
}

# ---------------------------------------------------------------------------
# Total timeout watchdog (the whole test must finish in a few minutes).
# ---------------------------------------------------------------------------
TOTAL_TIMEOUT="${XRAY_TEST_TOTAL_TIMEOUT:-300}"
(
  sleep "$TOTAL_TIMEOUT"
  printf 'TOTAL TIMEOUT after %ss（当前 case 见上方最后的 CASE START 行）\n' "$TOTAL_TIMEOUT" >&2
  kill -TERM "$PPID" 2>/dev/null || true
) &
WATCHDOG_PID=$!

TEST_START=$SECONDS

run_case fresh-install        case_fresh_install
run_case legacy-1.2.3-github  case_legacy_123_github
run_case legacy-1.4.1-cf      case_legacy_141_cloudflare
run_case legacy-1.6.0-cf      case_legacy_160_cloudflare
run_case atomic-1.8.3-github  case_atomic_183_github
run_case atomic-1.8.4-cf      case_atomic_184_cloudflare
run_case current-reinstall    case_current_reinstall
run_case unknown-legacy       case_unknown_legacy
run_case fail-download        case_fail_download
run_case fail-sha256sums      case_fail_sha
run_case fail-launcher-syntax case_fail_launcher_bashn
run_case fail-core-syntax     case_fail_core_bashn
run_case fail-pair-write      case_fail_pair_write
run_case fail-atomic-switch   case_fail_switch
run_case fail-selfcheck       case_fail_selfcheck

kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
rm -f "$before_state" "$after_state"
printf 'Legacy manager upgrade tests passed (%ss total).\n' "$(( SECONDS - TEST_START ))"
