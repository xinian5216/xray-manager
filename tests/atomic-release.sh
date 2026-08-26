#!/usr/bin/env bash
# Regression coverage for atomic Manager releases, migration and rollback.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../xray-manager.sh
source "$ROOT_DIR/xray-manager.sh"

INSTALL_ROOT=""
PAIRS="$TEST_ROOT/pairs"
mkdir -p "$PAIRS"

fail() {
  printf 'atomic-release: %s\n' "$*" >&2
  exit 1
}

mode_of() {
  stat -c '%a' "$1"
}

make_pair() {
  local dest="$1" ver="$2"
  mkdir -p "$dest/lib"
  sed \
    -e "s/^PROJECT_VERSION=.*/PROJECT_VERSION=\"$ver\"/" \
    -e "s/^CORE_VERSION=.*/CORE_VERSION=\"$ver\"/" \
    "$ROOT_DIR/xray-manager.sh" >"$dest/xray-manager.sh"
  sed \
    -e "s/^SCRIPT_VERSION=.*/SCRIPT_VERSION=\"$ver\"/" \
    "$ROOT_DIR/lib/xray-manager-core.sh" >"$dest/lib/xray-manager-core.sh"
  chmod 755 "$dest/xray-manager.sh" "$dest/lib/xray-manager-core.sh"
  (
    cd "$dest"
    sha256sum xray-manager.sh lib/xray-manager-core.sh >SHA256SUMS
  )
  printf '%s\n' "$ver" >"$dest/VERSION"
}

current_dir() {
  readlink -f "$INSTALL_ROOT/lib/current"
}

current_version() {
  read_project_version "$(current_dir)/xray-manager.sh"
}

previous_version() {
  read_project_version "$(readlink -f "$INSTALL_ROOT/lib/previous")/xray-manager.sh"
}

setup_env() {
  local name="$1"
  INSTALL_ROOT="$TEST_ROOT/$name"
  rm -rf "$INSTALL_ROOT"
  mkdir -p "$INSTALL_ROOT/lib"
  XRAY_MANAGER_INSTALL_PATH="$INSTALL_ROOT/xraym"
  XRAY_MANAGER_CORE_PATH="$INSTALL_ROOT/lib/xray-manager-core.sh"
  XRAY_MANAGER_LIB_DIR="$INSTALL_ROOT/lib"
  XRAY_MANAGER_LOCK_DIR="$INSTALL_ROOT/manager.lock"
  XRAY_MANAGER_FAIL_STEP=""
  INSTALL_PATH="$XRAY_MANAGER_INSTALL_PATH"
  CORE_PATH="$XRAY_MANAGER_CORE_PATH"
  manager_layout_paths
}

assert_pair_aligned() {
  local ver="$1" dir
  [[ -L "$INSTALL_ROOT/xraym" ]] || fail "xraym is not a symlink"
  [[ -L "$INSTALL_ROOT/lib/current" ]] || fail "current is not a symlink"
  [[ -L "$INSTALL_ROOT/lib/xray-manager-core.sh" ]] || fail "compat core is not a symlink"
  dir="$(current_dir)"
  [[ -f "$dir/xray-manager.sh" && -f "$dir/xray-manager-core.sh" ]] || fail "release files missing"
  [[ "$(read_project_version "$dir/xray-manager.sh")" == "$ver" ]] || fail "launcher version $ver"
  [[ "$(read_core_version "$dir/xray-manager-core.sh")" == "$ver" ]] || fail "core version $ver"
  cmp "$dir/xray-manager.sh" "$INSTALL_ROOT/xraym" || fail "xraym content mismatch"
  cmp "$dir/xray-manager-core.sh" "$INSTALL_ROOT/lib/xray-manager-core.sh" || fail "core content mismatch"
  [[ "$(readlink -f "$INSTALL_ROOT/xraym")" == "$dir/xray-manager.sh" ]] || fail "xraym does not follow current"
  [[ "$(mode_of "$dir")" == "755" ]] || fail "release dir mode $(mode_of "$dir")"
  [[ "$(mode_of "$dir/xray-manager.sh")" == "755" ]] || fail "launcher mode"
  [[ "$(mode_of "$dir/xray-manager-core.sh")" == "755" ]] || fail "core mode"
  [[ "$(mode_of "$INSTALL_ROOT/lib")" == "755" ]] || fail "lib dir mode $(mode_of "$INSTALL_ROOT/lib")"
}

release_count() {
  find "$INSTALL_ROOT/lib/releases" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | wc -l
}

seed_legacy() {
  local ver="$1"
  mkdir -p "$INSTALL_ROOT/lib"
  install -m 755 "$PAIRS/$ver/xray-manager.sh" "$INSTALL_ROOT/xraym"
  install -m 755 "$PAIRS/$ver/lib/xray-manager-core.sh" "$INSTALL_ROOT/lib/xray-manager-core.sh"
  [[ ! -L "$INSTALL_ROOT/xraym" ]] || fail "legacy launcher unexpectedly a symlink"
}

make_pair "$PAIRS/1.8.0" "1.8.0"
make_pair "$PAIRS/1.8.1" "1.8.1"
make_pair "$PAIRS/1.8.2" "1.8.2"
make_pair "$PAIRS/1.8.3" "1.8.3"
make_pair "$PAIRS/9.9.9" "9.9.9"

# 1. First install from legacy fixed paths (migration + upgrade).
setup_env migrate
seed_legacy 1.8.0
install_pair "$PAIRS/1.8.1/xray-manager.sh" "$PAIRS/1.8.1/lib/xray-manager-core.sh"
assert_pair_aligned 1.8.1
[[ "$(previous_version)" == "1.8.0" ]] || fail "migration did not keep previous 1.8.0"
[[ "$(release_count)" -eq 2 ]] || fail "expected current+previous after migrate/upgrade"

# 2. Normal upgrade.
install_pair "$PAIRS/1.8.2/xray-manager.sh" "$PAIRS/1.8.2/lib/xray-manager-core.sh"
assert_pair_aligned 1.8.2
[[ "$(previous_version)" == "1.8.1" ]] || fail "previous should be 1.8.1"
[[ "$(release_count)" -eq 2 ]] || fail "prune should keep only two releases"

# 3. Same-version reinstall keeps a rollback copy.
install_pair "$PAIRS/1.8.2/xray-manager.sh" "$PAIRS/1.8.2/lib/xray-manager-core.sh"
assert_pair_aligned 1.8.2
[[ "$(previous_version)" == "1.8.2" ]] || fail "reinstall previous should be old 1.8.2"
[[ "$(release_count)" -eq 2 ]] || fail "reinstall prune failed"
[[ "$(readlink -f "$INSTALL_ROOT/lib/current")" != "$(readlink -f "$INSTALL_ROOT/lib/previous")" ]] \
  || fail "current and previous must be distinct copies after reinstall"

# Snapshot the live files for failure cases.
LIVE_LAUNCHER="$(current_dir)/xray-manager.sh"
LIVE_CORE="$(current_dir)/xray-manager-core.sh"
LIVE_HASH="$(sha256_file "$LIVE_LAUNCHER")$(sha256_file "$LIVE_CORE")"
assert_unchanged() {
  local now
  now="$(sha256_file "$(current_dir)/xray-manager.sh")$(sha256_file "$(current_dir)/xray-manager-core.sh")"
  [[ "$now" == "$LIVE_HASH" ]] || fail "live release changed during simulated failure"
}

# 4. Launcher write failure leaves current intact.
XRAY_MANAGER_FAIL_STEP=launcher
if install_pair "$PAIRS/1.8.3/xray-manager.sh" "$PAIRS/1.8.3/lib/xray-manager-core.sh"; then
  fail "launcher failure unexpectedly succeeded"
fi
XRAY_MANAGER_FAIL_STEP=""
assert_pair_aligned 1.8.2
assert_unchanged

# 5. Core write failure leaves current intact.
XRAY_MANAGER_FAIL_STEP=core
if install_pair "$PAIRS/1.8.3/xray-manager.sh" "$PAIRS/1.8.3/lib/xray-manager-core.sh"; then
  fail "core failure unexpectedly succeeded"
fi
XRAY_MANAGER_FAIL_STEP=""
assert_pair_aligned 1.8.2
assert_unchanged

# 6. Switch-before-current failure leaves current intact.
XRAY_MANAGER_FAIL_STEP=switch
if install_pair "$PAIRS/1.8.3/xray-manager.sh" "$PAIRS/1.8.3/lib/xray-manager-core.sh"; then
  fail "switch failure unexpectedly succeeded"
fi
XRAY_MANAGER_FAIL_STEP=""
assert_pair_aligned 1.8.2
assert_unchanged
[[ -x "$INSTALL_ROOT/xraym" ]] || fail "launcher not executable after switch failure"

# 7. Post-switch self-check failure rolls back.
XRAY_MANAGER_FAIL_STEP=selfcheck
if install_pair "$PAIRS/1.8.3/xray-manager.sh" "$PAIRS/1.8.3/lib/xray-manager-core.sh"; then
  fail "selfcheck failure unexpectedly succeeded"
fi
XRAY_MANAGER_FAIL_STEP=""
assert_pair_aligned 1.8.2
assert_unchanged

# 8. Successful upgrade then manual rollback, twice (toggle).
install_pair "$PAIRS/1.8.3/xray-manager.sh" "$PAIRS/1.8.3/lib/xray-manager-core.sh"
assert_pair_aligned 1.8.3
[[ "$(previous_version)" == "1.8.2" ]] || fail "previous after 1.8.3 should be 1.8.2"
rollback_manager >/dev/null
assert_pair_aligned 1.8.2
[[ "$(previous_version)" == "1.8.3" ]] || fail "rollback should record 1.8.3 as previous"
rollback_manager >/dev/null
assert_pair_aligned 1.8.3
[[ "$(previous_version)" == "1.8.2" ]] || fail "second rollback should restore 1.8.3"

# 9. Permissions never loosen past 755, and extra releases are pruned.
[[ "$(release_count)" -eq 2 ]] || fail "rollback prune left extra releases"
while IFS=' ' read -r mode path; do
  [[ -n "${mode:-}" ]] || continue
  case "$path" in
    *manager.lock*) continue ;;
  esac
  [[ "$mode" == "755" || "$mode" == "700" ]] || fail "unexpected dir mode $mode $path"
done <<EOF
$(find "$INSTALL_ROOT" -type d ! -path "$INSTALL_ROOT" -printf '%m %p\n')
EOF
while IFS=' ' read -r mode path; do
  [[ -n "${mode:-}" ]] || continue
  [[ "$mode" == "755" ]] || fail "unexpected file mode $mode $path"
done <<EOF
$(find "$INSTALL_ROOT/lib/releases" -type f -printf '%m %p\n')
EOF

# 10. GitHub self-update path shares install_pair and does not persist tokens.
setup_env github
MOCK_BIN="$INSTALL_ROOT/mock-bin"
FIXTURES="$INSTALL_ROOT/fixtures"
mkdir -p "$MOCK_BIN" "$FIXTURES/lib"
install -m 755 "$PAIRS/9.9.9/xray-manager.sh" "$FIXTURES/xray-manager.sh"
install -m 755 "$PAIRS/9.9.9/lib/xray-manager-core.sh" "$FIXTURES/lib/xray-manager-core.sh"
install -m 644 "$PAIRS/9.9.9/SHA256SUMS" "$FIXTURES/SHA256SUMS"
printf '9.9.9\n' >"$FIXTURES/VERSION"

cat >"$MOCK_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url=""
out=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|-x|--connect-timeout|--max-time|--retry) shift 2 ;;
    -fsSL) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$url" && -n "$out" ]]
case "$url" in
  */contents/VERSION\?*) source_file="VERSION" ;;
  */contents/SHA256SUMS\?*) source_file="SHA256SUMS" ;;
  */contents/xray-manager.sh\?*) source_file="xray-manager.sh" ;;
  */contents/lib/xray-manager-core.sh\?*) source_file="lib/xray-manager-core.sh" ;;
  *) echo "Unexpected URL: $url" >&2; exit 2 ;;
esac
cp "$XRAY_TEST_FIXTURES/$source_file" "$out"
SH
chmod 755 "$MOCK_BIN/curl"

PATH="$MOCK_BIN:$PATH" \
XRAY_TEST_FIXTURES="$FIXTURES" \
XRAY_MANAGER_GITHUB_TOKEN="ghp_test_token_secret_xyz" \
XRAY_MANAGER_INSTALL_PATH="$INSTALL_ROOT/xraym" \
XRAY_MANAGER_CORE_PATH="$INSTALL_ROOT/lib/xray-manager-core.sh" \
XRAY_MANAGER_LOCK_DIR="$INSTALL_ROOT/manager.lock" \
bash "$ROOT_DIR/xray-manager.sh" --self-update-github >/dev/null

[[ -L "$INSTALL_ROOT/xraym" ]] || fail "github update did not create launcher symlink"
[[ "$(read_project_version "$(readlink -f "$INSTALL_ROOT/xraym")")" == "9.9.9" ]] \
  || fail "github update did not install 9.9.9"
if grep -Rqs 'ghp_test_token_secret_xyz' "$INSTALL_ROOT"; then
  fail "GitHub token was persisted on disk"
fi

# 11. Cloudflare self-update path and token hygiene.
setup_env cloudflare
PACKAGE_ROOT="$INSTALL_ROOT/package"
MANAGER="$PACKAGE_ROOT/xray-manager"
FIXTURES="$INSTALL_ROOT/cf-fixtures"
MOCK_BIN="$INSTALL_ROOT/mock-bin"
mkdir -p "$MANAGER/lib" "$FIXTURES" "$MOCK_BIN"
install -m 755 "$PAIRS/9.9.9/xray-manager.sh" "$MANAGER/xray-manager.sh"
install -m 755 "$PAIRS/9.9.9/lib/xray-manager-core.sh" "$MANAGER/lib/xray-manager-core.sh"
install -m 644 "$PAIRS/9.9.9/SHA256SUMS" "$MANAGER/SHA256SUMS"
printf '9.9.9\n' >"$MANAGER/VERSION"
printf '{"format":1,"manager_version":"9.9.9"}\n' >"$MANAGER/release-manifest.json"
tar -C "$PACKAGE_ROOT" -czf "$FIXTURES/latest-amd64.tar.gz" xray-manager
sha256sum "$FIXTURES/latest-amd64.tar.gz" | awk '{print $1}' >"$FIXTURES/latest-amd64.sha256"
python3 - "$FIXTURES/latest-amd64.sha256" "$FIXTURES/manifest.json" <<'PY'
import pathlib, sys
sha = pathlib.Path(sys.argv[1]).read_text().strip()
pathlib.Path(sys.argv[2]).write_text(
    '{"format":1,"manager_version":"9.9.9","packages":{"amd64":{"file":"latest-amd64.tar.gz","sha256":"%s"}}}\n' % sha
)
PY

cat >"$MOCK_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url=""
out=""
while (($#)); do
  case "$1" in
    --config) shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$url" && -n "$out" ]]
cp "$XRAY_TEST_FIXTURES/${url##*/}" "$out"
SH
chmod 755 "$MOCK_BIN/curl"

# Preserve update-source / Cloudflare URL files across install.
mkdir -p "$INSTALL_ROOT/state"
printf 'cloudflare\n' >"$INSTALL_ROOT/state/manager_update_source"
printf 'https://worker.example.invalid\n' >"$INSTALL_ROOT/state/cloudflare_url"
chmod 600 "$INSTALL_ROOT/state/manager_update_source" "$INSTALL_ROOT/state/cloudflare_url"

PATH="$MOCK_BIN:$PATH" \
XRAY_TEST_FIXTURES="$FIXTURES" \
XRAY_MANAGER_INSTALL_TOKEN="cf_install_token_secret_xyz" \
XRAY_MANAGER_CLOUDFLARE_URL="https://worker.example.invalid" \
XRAY_MANAGER_UPDATE_SOURCE_FILE="$INSTALL_ROOT/state/manager_update_source" \
XRAY_MANAGER_CLOUDFLARE_URL_FILE="$INSTALL_ROOT/state/cloudflare_url" \
XRAY_MANAGER_LOCK_DIR="$INSTALL_ROOT/manager.lock" \
XRAY_MANAGER_INSTALL_PATH="$INSTALL_ROOT/xraym" \
XRAY_MANAGER_CORE_PATH="$INSTALL_ROOT/lib/xray-manager-core.sh" \
bash "$ROOT_DIR/xray-manager.sh" --self-update-cloudflare >/dev/null

[[ "$(read_project_version "$(readlink -f "$INSTALL_ROOT/xraym")")" == "9.9.9" ]] \
  || fail "cloudflare update did not install 9.9.9"
[[ "$(tr -d '[:space:]' <"$INSTALL_ROOT/state/manager_update_source")" == "cloudflare" ]] \
  || fail "update source file was modified"
[[ "$(tr -d '[:space:]' <"$INSTALL_ROOT/state/cloudflare_url")" == "https://worker.example.invalid" ]] \
  || fail "cloudflare url file was modified"
if grep -Rqs 'cf_install_token_secret_xyz' "$INSTALL_ROOT"; then
  fail "Cloudflare install token was persisted on disk"
fi

echo "Atomic Manager release tests passed."
