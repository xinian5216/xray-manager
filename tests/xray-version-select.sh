#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"

fail() {
  echo "xray-version-select: $1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Version normalization
# ---------------------------------------------------------------------------
[[ "$(xray_version_normalize 26.9.9)" == "v26.9.9" ]]
[[ "$(xray_version_normalize v26.9.9)" == "v26.9.9" ]]
[[ "$(xray_version_normalize ' v26.9.9 ')" == "v26.9.9" ]]
if xray_version_normalize abc >/dev/null 2>&1; then
  fail "normalize accepted 'abc'"
fi
if xray_version_normalize v26.9 >/dev/null 2>&1; then
  fail "normalize accepted 'v26.9'"
fi
if xray_version_normalize 'v26.9.9;rm' >/dev/null 2>&1; then
  fail "normalize accepted shell metacharacters"
fi
if xray_version_normalize 'v26.9.9 beta' >/dev/null 2>&1; then
  fail "normalize accepted trailing junk"
fi
if xray_version_normalize '../etc/passwd' >/dev/null 2>&1; then
  fail "normalize accepted a path"
fi

# ---------------------------------------------------------------------------
# 2. Numeric version comparison (no string ordering)
# ---------------------------------------------------------------------------
[[ "$(xray_version_compare v26.9.9 v26.7.28)" == ">" ]]
[[ "$(xray_version_compare v26.7.28 v26.9.9)" == "<" ]]
[[ "$(xray_version_compare v26.9.9 v26.9.9)" == "=" ]]
[[ "$(xray_version_compare v26.10.0 v26.9.9)" == ">" ]] # 10 > 9 numerically
[[ "$(xray_version_compare v27.0.0 v26.99.99)" == ">" ]]
if xray_version_compare not-a-version v1.2.3 >/dev/null 2>&1; then
  fail "compare accepted invalid input"
fi

[[ "$(xray_version_action v26.9.9 v26.7.28)" == "downgrade" ]]
[[ "$(xray_version_action v26.7.28 v26.9.9)" == "upgrade" ]]
[[ "$(xray_version_action v26.9.9 v26.9.9)" == "reinstall" ]]

# ---------------------------------------------------------------------------
# 3. Release fixtures: stable, pre-release, draft, missing asset
# ---------------------------------------------------------------------------
ASSET="Xray-linux-64.zip"

make_release() {
  local tag="$1" prerelease="$2" published="$3" draft="$4" with_asset="${5:-yes}"
  local assets="[]"
  if [[ "$with_asset" == "yes" ]]; then
    assets="[
      {
        \"name\": \"$ASSET\",
        \"browser_download_url\": \"https://github.com/XTLS/Xray-core/releases/download/$tag/$ASSET\",
        \"digest\": \"sha256:$(printf 'a%.0s' {1..64})\"
      }
    ]"
  elif [[ "$with_asset" == "other-arch" ]]; then
    assets="[
      {
        \"name\": \"Xray-linux-arm64-v8a.zip\",
        \"browser_download_url\": \"https://github.com/XTLS/Xray-core/releases/download/$tag/Xray-linux-arm64-v8a.zip\"
      }
    ]"
  fi
  printf '{
    "tag_name": "%s",
    "draft": %s,
    "prerelease": %s,
    "published_at": "%s",
    "assets": %s
  }' "$tag" "$draft" "$prerelease" "$published" "$assets"
}

RELEASES_JSON="$(mktemp)"
{
  make_release v26.9.9  true  "2026-09-08T00:00:00Z" false
  make_release v26.9.8  true  "2026-09-07T00:00:00Z" false
  make_release v26.7.28 true  "2026-07-28T00:00:00Z" false
  make_release v26.3.27 false "2026-03-27T00:00:00Z" false
  make_release v26.8.19 false "2026-08-19T00:00:00Z" true    # draft
  make_release v26.8.20 true  "2026-08-20T00:00:00Z" false other-arch
  make_release v26.6.6  false "2026-06-06T00:00:00Z" false
} | jq -s . >"$RELEASES_JSON"

# Latest published: newest non-draft with our asset, prereleases allowed.
LATEST_PUB="$(xray_github_latest_published "$RELEASES_JSON" "$ASSET")"
[[ "$LATEST_PUB" == $'v26.9.9\ttrue' ]] ||
  fail "latest published: got '$LATEST_PUB'"

# Latest stable: newest non-draft, non-prerelease with our asset.
LATEST_STABLE="$(xray_github_latest_stable "$RELEASES_JSON" "$ASSET")"
[[ "$LATEST_STABLE" == $'v26.6.6\tfalse' ]] ||
  fail "latest stable: got '$LATEST_STABLE'"

[[ "$LATEST_PUB" != "$LATEST_STABLE" ]] ||
  fail "latest published and stable unexpectedly identical"

# Draft and missing-asset releases must never be selected.
[[ "$LATEST_PUB" != v26.8.19* ]] || fail "draft was selected"
[[ "$LATEST_PUB" != v26.8.20* ]] || fail "missing-asset release was selected"

# History: drafts and missing assets excluded, newest first, max 15.
HISTORY="$(xray_github_release_history "$RELEASES_JSON" "$ASSET")"
[[ "$(wc -l <<<"$HISTORY")" -eq 5 ]] ||
  fail "history size: $(wc -l <<<"$HISTORY")"
[[ "$(head -n 1 <<<"$HISTORY")" == $'v26.9.9\ttrue\t2026-09-08' ]] ||
  fail "history newest entry wrong"
grep -q $'^v26.8.19\t' <<<"$HISTORY" && fail "draft leaked into history"
grep -q $'^v26.8.20\t' <<<"$HISTORY" && fail "missing-asset leaked into history"

# Tag lookup: valid tag with asset resolves; draft / missing asset does not.
[[ "$(xray_github_lookup_tag "$RELEASES_JSON" v26.9.9 "$ASSET")" == $'v26.9.9\ttrue' ]]
if xray_github_lookup_tag "$RELEASES_JSON" v26.8.19 "$ASSET" >/dev/null 2>&1; then
  fail "lookup accepted a draft"
fi
if xray_github_lookup_tag "$RELEASES_JSON" v26.8.20 "$ASSET" >/dev/null 2>&1; then
  fail "lookup accepted a release without our asset"
fi
if xray_github_lookup_tag "$RELEASES_JSON" v99.0.0 "$ASSET" >/dev/null 2>&1; then
  fail "lookup accepted a nonexistent tag"
fi

# ---------------------------------------------------------------------------
# 4. History menu: valid index, invalid index, cancel
# ---------------------------------------------------------------------------
# The menu is driven directly with scripted stdin.
sel="$(printf '2\n' | xray_history_menu "$RELEASES_JSON" "$ASSET")"
[[ "$sel" == $'v26.9.8\ttrue' ]] || fail "history menu index 2: '$sel'"

sel="$(printf '1\n' | xray_history_menu "$RELEASES_JSON" "$ASSET")"
[[ "$sel" == $'v26.9.9\ttrue' ]] || fail "history menu index 1: '$sel'"

# Out-of-range index must re-prompt, then 0 cancels.
if sel="$(printf '99\n0\n' | xray_history_menu "$RELEASES_JSON" "$ASSET")" && [[ -n "$sel" ]]; then
  fail "history menu accepted out-of-range index"
fi

if printf '0\n' | xray_history_menu "$RELEASES_JSON" "$ASSET" >/dev/null; then
  fail "history menu cancel should fail"
fi

if printf 'zzz\n0\n' | xray_history_menu "$RELEASES_JSON" "$ASSET" >/dev/null; then
  fail "history menu accepted non-numeric input"
fi

# ---------------------------------------------------------------------------
# 5. Manual version input validation against the release list
# ---------------------------------------------------------------------------
MANUAL_OK="$(printf '26.9.9\n' | xray_ask_manual_version "$RELEASES_JSON")"
[[ "$MANUAL_OK" == $'v26.9.9\ttrue' ]] || fail "manual '26.9.9' failed"

MANUAL_OK="$(printf 'v26.6.6\n' | xray_ask_manual_version "$RELEASES_JSON")"
[[ "$MANUAL_OK" == $'v26.6.6\tfalse' ]] || fail "manual 'v26.6.6' failed"

if printf 'abc\n' | xray_ask_manual_version "$RELEASES_JSON" >/dev/null 2>&1; then
  fail "manual accepted 'abc'"
fi
if printf 'v26.9\n' | xray_ask_manual_version "$RELEASES_JSON" >/dev/null 2>&1; then
  fail "manual accepted 'v26.9'"
fi
if printf 'v26.9.9;rm\n' | xray_ask_manual_version "$RELEASES_JSON" >/dev/null 2>&1; then
  fail "manual accepted shell metacharacters"
fi
if printf 'v99.0.0\n' | xray_ask_manual_version "$RELEASES_JSON" >/dev/null 2>&1; then
  fail "manual accepted a nonexistent release"
fi

# ---------------------------------------------------------------------------
# 6. Downgrade guard: v26.9.9 -> v26.7.28 defaults to refusal
# ---------------------------------------------------------------------------
if printf '\n' | xray_confirm_downgrade v26.9.9 v26.7.28 >/dev/null 2>&1; then
  fail "downgrade silently accepted with default (empty) answer"
fi
if ! printf 'y\n' | xray_confirm_downgrade v26.9.9 v26.7.28 >/dev/null 2>&1; then
  fail "downgrade refused despite explicit y"
fi

# ---------------------------------------------------------------------------
# 7. API digest verification
# ---------------------------------------------------------------------------
ZIP="$TEST_ROOT/fake.zip"
printf 'fake-xray-payload\n' >"$ZIP"
ZIP_SHA="$(sha256sum "$ZIP" | awk '{print $1}')"

DIGEST_JSON="$(mktemp)"
jq -n --arg sha "$ZIP_SHA" '
  [
    {
      tag_name: "v26.9.9",
      draft: false,
      prerelease: true,
      assets: [
        {
          name: "Xray-linux-64.zip",
          browser_download_url: "https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-linux-64.zip",
          digest: ("sha256:" + $sha)
        }
      ]
    }
  ]
' >"$DIGEST_JSON"

VERIFY_OUT="$(xray_verify_api_digest "$DIGEST_JSON" v26.9.9 "$ASSET" "$ZIP")"
[[ "$VERIFY_OUT" == "$ZIP_SHA" ]] || fail "api digest verify failed on a good file"

printf 'tampered\n' >"$TEST_ROOT/bad.zip"
if xray_verify_api_digest "$DIGEST_JSON" v26.9.9 "$ASSET" "$TEST_ROOT/bad.zip" >/dev/null 2>&1; then
  fail "api digest verify accepted a tampered file"
fi

jq '[.[] | .assets[0].digest = "not-a-digest"]' "$DIGEST_JSON" >"$TEST_ROOT/bad-digest.json"
if xray_verify_api_digest "$TEST_ROOT/bad-digest.json" v26.9.9 "$ASSET" "$ZIP" >/dev/null 2>&1; then
  fail "api digest verify accepted a malformed digest"
fi

# Missing digest must fail closed.
jq '[.[] | del(.assets[0].digest)]' "$DIGEST_JSON" >"$TEST_ROOT/no-digest.json"
if xray_verify_api_digest "$TEST_ROOT/no-digest.json" v26.9.9 "$ASSET" "$ZIP" >/dev/null 2>&1; then
  fail "api digest verify accepted a missing digest"
fi

# ---------------------------------------------------------------------------
# 8. Systemd installer receives --version and keeps the proxy flag
# ---------------------------------------------------------------------------
# 8a. Exercise the real run_systemd_installer wrapper end-to-end with a fake
#     installer script that records its argv.
FAKE_INSTALLER="$TEST_ROOT/fake-install-release.sh"
FAKE_INSTALLER_LOG="$TEST_ROOT/fake-installer.log"
cat >"$FAKE_INSTALLER" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FAKE_INSTALLER_LOG"
SH
chmod +x "$FAKE_INSTALLER"
export FAKE_INSTALLER_LOG

: >"$FAKE_INSTALLER_LOG"
DOWNLOAD_PROXY=""
# shellcheck disable=SC2218  # real Core function; the test stubs it further down
run_systemd_installer "$FAKE_INSTALLER" install --version v26.9.9
[[ "$(cat "$FAKE_INSTALLER_LOG")" == "install --version v26.9.9" ]] ||
  fail "real wrapper did not forward --version: $(cat "$FAKE_INSTALLER_LOG")"

: >"$FAKE_INSTALLER_LOG"
DOWNLOAD_PROXY="socks5h://[2001:db8::1]:1080"
# shellcheck disable=SC2218
run_systemd_installer "$FAKE_INSTALLER" install --version v26.9.9
[[ "$(cat "$FAKE_INSTALLER_LOG")" == "install --version v26.9.9 -p socks5h://[2001:db8::1]:1080" ]] ||
  fail "real wrapper dropped the proxy flag: $(cat "$FAKE_INSTALLER_LOG")"
DOWNLOAD_PROXY=""

# 8b. xray_install_selected_version passes the version through to the wrapper.
SYSTEMD_CALLS="$TEST_ROOT/systemd-calls.log"
run_systemd_installer() {
  # Mirrors the real Core wrapper: action, optional --version, then -p PROXY.
  local script="$1" action="$2"
  shift 2
  local -a args=("$action" "$@")
  if [[ -n "${DOWNLOAD_PROXY:-}" ]]; then
    args+=("-p" "$DOWNLOAD_PROXY")
  fi
  # Rebind to single-space IFS because the Core sets IFS=$'\n\t' globally.
  local IFS=' '
  printf '%s\n' "$script ${args[*]}" >>"$SYSTEMD_CALLS"
  return 0
}
download_to_tmp() {
  : >"$2"
  return 0
}

# shellcheck disable=SC2034
INIT_SYS="systemd"
XRAY_BIN="$TEST_ROOT/bin/xray"
mkdir -p "$(dirname "$XRAY_BIN")"
cat >"$XRAY_BIN" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version|-version) echo "Xray 26.9.9 (CUSTOM)" ;;
  run) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$XRAY_BIN"

prepare_existing_xray_config() { return 0; }
ensure_layout() { return 0; }
test_config() { return 0; }
service_restart() { return 0; }
xray_service_active() { return 0; }
xray_backup_core() { printf '%s' "$TEST_ROOT/core-backup"; mkdir -p "$TEST_ROOT/core-backup"; cp "$XRAY_BIN" "$TEST_ROOT/core-backup/xray"; }
# NOTE: do not stub xray_confirm_downgrade/xray_report_target_action here;
# section 12 needs the real implementations.

if ! xray_install_selected_version v26.9.9; then
  fail "xray_install_selected_version failed with all stubs succeeding"
fi
grep -Eq '(^| )install --version v26\.9\.9( |$)' "$SYSTEMD_CALLS" ||
  fail "systemd installer call missing '--version v26.9.9': $(cat "$SYSTEMD_CALLS")"

# Proxy must still be forwarded to the official installer.
DOWNLOAD_PROXY="socks5h://[2001:db8::1]:1080"
: >"$SYSTEMD_CALLS"
if ! xray_install_selected_version v26.9.9; then
  fail "xray_install_selected_version failed with a proxy configured"
fi
grep -Eq '(^| )install --version v26\.9\.9 -p socks5h://\[2001:db8::1\]:1080( |$)' "$SYSTEMD_CALLS" ||
  fail "proxy flag missing from installer call: $(cat "$SYSTEMD_CALLS")"
DOWNLOAD_PROXY=""

# ---------------------------------------------------------------------------
# 8c. Alpine/OpenRC: verified asset download + offline import
# ---------------------------------------------------------------------------
OPENRC_ROOT="$TEST_ROOT/openrc"
MOCK_BIN="$OPENRC_ROOT/mock-bin"
GITHUB_DIR="$OPENRC_ROOT/github"
mkdir -p "$MOCK_BIN" "$GITHUB_DIR"

cat >"$MOCK_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url=""
out=""
while (($#)); do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    -x) shift 2 ;;
    -H|--retry|--connect-timeout|--max-time) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$url" && -n "$out" ]] || exit 2
printf '%s\n' "$url" >>"$MOCK_CURL_LOG"
case "$url" in
  https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100)
    cp "$MOCK_RELEASES_JSON" "$out"
    ;;
  *)
    cp "$MOCK_DOWNLOAD_DIR/${url##*/}" "$out"
    ;;
esac
SH
chmod 755 "$MOCK_BIN/curl"

write_openrc_fixtures() {
  local tag="$1" prerelease="$2" api_digest="$3" with_dgst="$4" dgst_value="$5"
  local zip_asset="Xray-linux-64.zip" dgst_asset="Xray-linux-64.zip.dgst"
  local base="https://github.com/XTLS/Xray-core/releases/download/$tag"
  local dgst_field="null"
  [[ "$with_dgst" == "yes" ]] && dgst_field="\"$base/$dgst_asset\""

  jq -n \
    --arg tag "$tag" \
    --argjson prerelease "$prerelease" \
    --arg api_digest "$api_digest" \
    --arg base "$base" \
    --arg zip "$zip_asset" \
    --arg dgst "$dgst_asset" \
    --argjson dgst_url "$dgst_field" '
      [
        {
          tag_name: $tag,
          draft: false,
          prerelease: $prerelease,
          published_at: "2026-09-08T00:00:00Z",
          assets: (
            [
              {
                name: $zip,
                browser_download_url: ($base + "/" + $zip),
                digest: $api_digest
              }
            ]
            + (if $dgst_url == null then [] else [{
                name: $dgst,
                browser_download_url: $dgst_url
              }] end)
          )
        }
      ]
    ' >"$MOCK_RELEASES_JSON"

  if [[ "$with_dgst" == "yes" ]]; then
    printf 'MD5= feedface\nSHA2-256= %s\nSHA2-512= 00\n' "$dgst_value" >"$MOCK_DOWNLOAD_DIR/$dgst_asset"
  fi
}

OPENRC_IMPORT_LOG="$OPENRC_ROOT/import.log"
offline_import_xray() {
  printf '%s\n' "$1" >"$OPENRC_IMPORT_LOG"
  return 0
}
# xray_openrc_install_version reuses the currently installed geodata.
ASSET_DIR="$OPENRC_ROOT/assets"
mkdir -p "$ASSET_DIR"
head -c 2048 /dev/zero >"$ASSET_DIR/geoip.dat"
head -c 2048 /dev/zero >"$ASSET_DIR/geosite.dat"
export MOCK_CURL_LOG="$OPENRC_ROOT/curl.log"
export MOCK_RELEASES_JSON="$OPENRC_ROOT/releases.json"
export MOCK_DOWNLOAD_DIR="$GITHUB_DIR"
PATH="$MOCK_BIN:$PATH"

# Section 8b replaced download_to_tmp with a stub; restore a mock-backed
# implementation so the OpenRC path really exercises the download flow.
download_to_tmp() {
  local url="$1" out="$2"
  curl_net -fL --retry 4 --connect-timeout 12 --max-time 180 -o "$out" "$url"
}

# Case 1: stable release, API digest + .dgst agree -> install proceeds.
printf 'openrc-xray-zip-payload\n' >"$GITHUB_DIR/Xray-linux-64.zip"
ZIP_SHA="$(sha256sum "$GITHUB_DIR/Xray-linux-64.zip" | awk '{print $1}')"
write_openrc_fixtures v26.6.6 false "sha256:$ZIP_SHA" yes "$ZIP_SHA"
rm -f "$OPENRC_IMPORT_LOG" "$MOCK_CURL_LOG"
mkdir -p "$OPENRC_ROOT/work-1"
if ! xray_openrc_install_version v26.6.6 "$OPENRC_ROOT/work-1"; then
  fail "openrc install failed for a valid stable release"
fi
[[ -f "$OPENRC_IMPORT_LOG" ]] || fail "offline_import_xray was not called"
[[ "$(cat "$OPENRC_IMPORT_LOG")" == "$OPENRC_ROOT/work-1/Xray-linux-64.zip" ]] ||
  fail "offline_import_xray received the wrong archive"
grep -Fxq "https://github.com/XTLS/Xray-core/releases/download/v26.6.6/Xray-linux-64.zip" "$MOCK_CURL_LOG" ||
  fail "official ZIP URL was not downloaded"
grep -Fxq "https://github.com/XTLS/Xray-core/releases/download/v26.6.6/Xray-linux-64.zip.dgst" "$MOCK_CURL_LOG" ||
  fail "official .dgst URL was not downloaded"

# Case 2: prerelease release without .dgst, API digest matches -> install proceeds.
printf 'openrc-prerelease-payload\n' >"$GITHUB_DIR/Xray-linux-64.zip"
ZIP_SHA="$(sha256sum "$GITHUB_DIR/Xray-linux-64.zip" | awk '{print $1}')"
write_openrc_fixtures v26.9.9 true "sha256:$ZIP_SHA" no ""
rm -f "$OPENRC_IMPORT_LOG"
mkdir -p "$OPENRC_ROOT/work-2"
if ! xray_openrc_install_version v26.9.9 "$OPENRC_ROOT/work-2"; then
  fail "openrc install failed for a valid prerelease release"
fi
[[ -f "$OPENRC_IMPORT_LOG" ]] || fail "prerelease import was not called"

# Case 3: tampered ZIP -> fail closed, no import.
printf 'openrc-tampered-payload\n' >"$GITHUB_DIR/Xray-linux-64.zip"
rm -f "$OPENRC_IMPORT_LOG"
mkdir -p "$OPENRC_ROOT/work-3"
if xray_openrc_install_version v26.6.6 "$OPENRC_ROOT/work-3" >/dev/null 2>&1; then
  fail "openrc install accepted a tampered ZIP"
fi
[[ ! -f "$OPENRC_IMPORT_LOG" ]] || fail "tampered ZIP still reached offline_import_xray"

# Case 4: API digest and .dgst disagree -> fail closed, no import.
printf 'openrc-xray-zip-payload\n' >"$GITHUB_DIR/Xray-linux-64.zip"
ZIP_SHA="$(sha256sum "$GITHUB_DIR/Xray-linux-64.zip" | awk '{print $1}')"
write_openrc_fixtures v26.6.6 false "sha256:$ZIP_SHA" yes "0000000000000000000000000000000000000000000000000000000000000000"
rm -f "$OPENRC_IMPORT_LOG"
mkdir -p "$OPENRC_ROOT/work-4"
if xray_openrc_install_version v26.6.6 "$OPENRC_ROOT/work-4" >/dev/null 2>&1; then
  fail "openrc install accepted conflicting digests"
fi
[[ ! -f "$OPENRC_IMPORT_LOG" ]] || fail "conflicting digests still reached offline_import_xray"

# Case 5: no API digest and no .dgst -> fail closed.
printf 'openrc-xray-zip-payload\n' >"$GITHUB_DIR/Xray-linux-64.zip"
write_openrc_fixtures v26.6.6 false "" no ""
rm -f "$OPENRC_IMPORT_LOG"
mkdir -p "$OPENRC_ROOT/work-5"
if xray_openrc_install_version v26.6.6 "$OPENRC_ROOT/work-5" >/dev/null 2>&1; then
  fail "openrc install accepted a missing digest"
fi
[[ ! -f "$OPENRC_IMPORT_LOG" ]] || fail "missing digest still reached offline_import_xray"

# Case 6: non-official asset URL -> fail closed before any download.
jq -n --arg tag "v26.6.6" '
  [{
    tag_name: $tag,
    draft: false,
    prerelease: false,
    published_at: "2026-09-08T00:00:00Z",
    assets: [{
      name: "Xray-linux-64.zip",
      browser_download_url: "https://evil.example/Xray-linux-64.zip",
      digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }]
  }]
' >"$MOCK_RELEASES_JSON"
rm -f "$OPENRC_IMPORT_LOG"
mkdir -p "$OPENRC_ROOT/work-6"
if xray_openrc_install_version v26.6.6 "$OPENRC_ROOT/work-6" >/dev/null 2>&1; then
  fail "openrc install accepted a non-official download URL"
fi
[[ ! -f "$OPENRC_IMPORT_LOG" ]] || fail "evil URL still reached offline_import_xray"

PATH="${PATH#"$MOCK_BIN:"}"
# shellcheck disable=SC2034
INIT_SYS="systemd"

# ---------------------------------------------------------------------------
# 9. Automatic rollback: config test fails -> old binary restored
# ---------------------------------------------------------------------------
: >"$SYSTEMD_CALLS"
OLD_SHA="$(sha256sum "$XRAY_BIN" | awk '{print $1}')"
test_config() { return 1; }
INSTALLER_REPLACED_BINARY=0

run_systemd_installer() {
  # Simulate the official installer replacing the binary.
  cat >"$XRAY_BIN" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version|-version) echo "Xray 26.9.9 (NEW-BROKEN)" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$XRAY_BIN"
  INSTALLER_REPLACED_BINARY=1
  return 0
}

if xray_install_selected_version v26.9.9 >/dev/null 2>&1; then
  fail "install reported success although config test failed"
fi
(( INSTALLER_REPLACED_BINARY == 1 )) ||
  fail "test setup did not actually replace the binary"
RESTORED_SHA="$(sha256sum "$XRAY_BIN" | awk '{print $1}')"
[[ "$RESTORED_SHA" == "$OLD_SHA" ]] ||
  fail "old binary was not restored after config test failure"

# ---------------------------------------------------------------------------
# 10. Automatic rollback: service restart fails -> old binary restored
# ---------------------------------------------------------------------------
test_config() { return 0; }
service_restart() { return 1; }
run_systemd_installer() {
  cat >"$XRAY_BIN" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version|-version) echo "Xray 26.9.9 (NEW-2)" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$XRAY_BIN"
  return 0
}
if xray_install_selected_version v26.9.9 >/dev/null 2>&1; then
  fail "install reported success although service restart failed"
fi
RESTORED_SHA="$(sha256sum "$XRAY_BIN" | awk '{print $1}')"
[[ "$RESTORED_SHA" == "$OLD_SHA" ]] ||
  fail "old binary was not restored after service restart failure"

# Service starts but never becomes active -> rollback as well.
service_restart() { return 0; }
xray_service_active() { return 1; }
run_systemd_installer() {
  cat >"$XRAY_BIN" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version|-version) echo "Xray 26.9.9 (NEW-3)" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$XRAY_BIN"
  return 0
}
if xray_install_selected_version v26.9.9 >/dev/null 2>&1; then
  fail "install reported success although the service never became active"
fi
[[ "$(sha256sum "$XRAY_BIN" | awk '{print $1}')" == "$OLD_SHA" ]] ||
  fail "old binary was not restored after inactive service"

# ---------------------------------------------------------------------------
# 11. Backup lands in the managed backup tree
# ---------------------------------------------------------------------------
BACKUP_ROOT="$TEST_ROOT/backups"
xray_backup_core() {
  mkdir -p "$BACKUP_ROOT/xray-core-test"
  cp "$XRAY_BIN" "$BACKUP_ROOT/xray-core-test/xray"
  printf '%s' "$BACKUP_ROOT/xray-core-test"
}
ensure_layout() { :; }
xray_service_active() { return 0; }
service_restart() { return 0; }
test_config() { return 0; }
run_systemd_installer() {
  cat >"$XRAY_BIN" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version|-version) echo "Xray 26.9.9 (NEW-4)" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$XRAY_BIN"
  return 0
}
if ! xray_install_selected_version v26.9.9 >/dev/null 2>&1; then
  fail "successful install path failed"
fi
[[ -f "$BACKUP_ROOT/xray-core-test/xray" ]] ||
  fail "backup was not created in the managed backup tree"

# ---------------------------------------------------------------------------
# 12. update_xray() integration: input guards and issue #8 success reporting
# ---------------------------------------------------------------------------
update_xray_output="$TEST_ROOT/update-out.txt"
INSTALL_LOG="$TEST_ROOT/install-calls.log"
CONFIRM_LOG="$TEST_ROOT/confirm-calls.log"

# Bash suppresses `read -p` prompts when stdin is not a terminal, so use a
# counting wrapper with identical y/N semantics to observe confirmations.
confirm() {
  printf '%s\n' "$1" >>"$CONFIRM_LOG"
  local ans
  read -r ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# Stub the GitHub data layer so update_xray's menu flow can run offline.
xray_github_fetch_releases() { printf '[]' >"$1"; return 0; }
xray_github_asset_name() { printf 'Xray-linux-64.zip'; }
xray_github_latest_published() { printf 'v26.7.28\ttrue'; }
xray_github_latest_stable() { printf 'v26.6.6\tfalse'; }
prepare_download_network() { return 0; }
pkg_install_base() { return 0; }
need_xray() { return 0; }

# update_xray runs in a pipeline subshell, so record installer invocations in
# a file instead of relying on variables propagating back.
xray_install_selected_version() {
  printf '%s\n' "$1" >>"$INSTALL_LOG"
  return "${XRAY_TEST_INSTALL_RC:-0}"
}

# 12a. Install failure must propagate and never print a success message.
#      The default pick is a pre-release downgrade, so confirm both prompts
#      ("y" for pre-release, "y" for downgrade) to actually reach the
#      installer, which then fails.
rm -f "$INSTALL_LOG"
update_xray_fail_rc=0
set +e
XRAY_TEST_INSTALL_RC=1 printf '1\ny\ny\n' | XRAY_TEST_INSTALL_RC=1 update_xray >"$update_xray_output" 2>&1
update_xray_fail_rc=$?
set -e
(( update_xray_fail_rc != 0 )) ||
  fail "update_xray returned 0 although installation failed"
if grep -q '更新完成' "$update_xray_output"; then
  fail "update_xray printed a success message although installation failed"
fi

# 12b. Downgrade selected through the menu is refused by default.
XRAY_BIN="$TEST_ROOT/current-xray"
cat >"$XRAY_BIN" <<'SH'
#!/usr/bin/env bash
echo "Xray 26.9.9 (CURRENT)"
SH
chmod +x "$XRAY_BIN"
CURRENT_SHA="$(sha256sum "$XRAY_BIN" | awk '{print $1}')"

rm -f "$INSTALL_LOG" "$CONFIRM_LOG"
set +e
# default menu pick (empty line) -> v26.7.28 [Pre-release]; confirm Pre-release
# yes; downgrade confirmation defaults to no.
printf '\ny\n\n' | update_xray >"$update_xray_output" 2>&1
downgrade_rc=$?
set -e
(( downgrade_rc != 0 )) || fail "update_xray accepted a downgrade without explicit confirmation"
[[ ! -s "$INSTALL_LOG" ]] || fail "downgrade reached the installer"
grep -q '检测到这是降级操作' "$update_xray_output" ||
  fail "downgrade was not reported before refusing"
# All confirmations go through xray_confirm_install_target exactly once.
[[ "$(wc -l <"$CONFIRM_LOG")" -eq 2 ]] ||
  fail "expected exactly two confirmations: $(cat "$CONFIRM_LOG")"
[[ "$(grep -c 'Pre-release' "$CONFIRM_LOG")" -eq 1 ]] ||
  fail "pre-release confirmation was not shown exactly once"
[[ "$(grep -c '确认继续' "$CONFIRM_LOG")" -eq 1 ]] ||
  fail "downgrade confirmation was not shown exactly once"
[[ "$(grep -c '检测到这是降级操作' "$update_xray_output")" -eq 1 ]] ||
  fail "downgrade warning was not shown exactly once"
[[ "$(sha256sum "$XRAY_BIN" | awk '{print $1}')" == "$CURRENT_SHA" ]] ||
  fail "refused downgrade still modified the binary"

# 12c. Explicit downgrade confirmation installs the requested version.
rm -f "$INSTALL_LOG"
set +e
printf '\ny\ny\n' | update_xray >"$update_xray_output" 2>&1
downgrade_ok_rc=$?
set -e
(( downgrade_ok_rc == 0 )) || fail "explicit downgrade confirmation did not proceed"
[[ "$(cat "$INSTALL_LOG")" == "v26.7.28" ]] ||
  fail "explicit downgrade installed '$(cat "$INSTALL_LOG")' instead of v26.7.28"
grep -q 'Xray Core 更新完成' "$update_xray_output" ||
  fail "successful update did not print the completion summary"

# 12d. Manual version input through the failure menu also passes the
#      downgrade guard (regression: manual path used to bypass it).
rm -f "$INSTALL_LOG"
xray_github_fetch_releases() { return 1; }
xray_release_fetch_failure_menu() { printf 'v26.7.28\ttrue'; }
set +e
printf '\n' | update_xray >"$update_xray_output" 2>&1
manual_downgrade_rc=$?
set -e
(( manual_downgrade_rc != 0 )) ||
  fail "manual downgrade bypassed the downgrade guard"
[[ ! -s "$INSTALL_LOG" ]] || fail "manual downgrade reached the installer"

# 12e. Manual version input with explicit confirmation still proceeds.
rm -f "$INSTALL_LOG"
set +e
printf 'y\ny\n' | update_xray >"$update_xray_output" 2>&1
manual_ok_rc=$?
set -e
(( manual_ok_rc == 0 )) || fail "confirmed manual downgrade did not proceed"
[[ "$(wc -l <"$INSTALL_LOG")" -eq 1 ]] ||
  fail "manual install path did not reach the installer exactly once"

# 12g. Reinstall (same version) is confirmed exactly once and defaults to no.
xray_release_fetch_failure_menu() { return 1; }
xray_github_fetch_releases() { printf '[]' >"$1"; return 0; }
xray_github_latest_published() { printf 'v26.9.9\tfalse'; }
rm -f "$INSTALL_LOG" "$CONFIRM_LOG"
set +e
printf '\n\n' | update_xray >"$update_xray_output" 2>&1
reinstall_rc=$?
set -e
(( reinstall_rc != 0 )) || fail "reinstall was accepted without confirmation"
[[ ! -s "$INSTALL_LOG" ]] || fail "refused reinstall reached the installer"
[[ "$(wc -l <"$CONFIRM_LOG")" -eq 1 && "$(grep -c '重新安装' "$CONFIRM_LOG")" -eq 1 ]] ||
  fail "reinstall confirmation was not shown exactly once: $(cat "$CONFIRM_LOG")"
grep -q '操作类型：重装' "$update_xray_output" ||
  fail "reinstall action was not reported"

rm -f "$INSTALL_LOG" "$CONFIRM_LOG"
set +e
printf '\ny\n' | update_xray >"$update_xray_output" 2>&1
reinstall_ok_rc=$?
set -e
(( reinstall_ok_rc == 0 )) || fail "confirmed reinstall did not proceed"
[[ "$(cat "$INSTALL_LOG")" == "v26.9.9" ]] ||
  fail "confirmed reinstall installed the wrong version"
[[ "$(wc -l <"$CONFIRM_LOG")" -eq 1 ]] ||
  fail "confirmed reinstall asked more than once: $(cat "$CONFIRM_LOG")"

# 12f. Cloudflare mode must not touch GitHub and must not offer version choice.
rm -f "$TEST_ROOT/cloudflare.log"
xray_github_fetch_releases() { fail "Cloudflare mode called the GitHub API"; }
uses_cloudflare_distribution() { return 0; }
cloudflare_install_or_update_xray() { printf 'cloudflare-update\n' >>"$TEST_ROOT/cloudflare.log"; }
set +e
printf '1\n' | update_xray >"$update_xray_output" 2>&1
cf_rc=$?
set -e
(( cf_rc == 0 )) || fail "Cloudflare update path failed"
grep -q '不提供任意 Xray Core 版本选择' "$update_xray_output" ||
  fail "Cloudflare channel did not explain the version policy"
grep -q 'cloudflare-update' "$TEST_ROOT/cloudflare.log" ||
  fail "Cloudflare update was not dispatched"

# ---------------------------------------------------------------------------
# 13. Unsupported architecture falls back to the official default version
# ---------------------------------------------------------------------------
uses_cloudflare_distribution() { return 1; } # undo the 12f stub
xray_github_fetch_releases() { printf '[]' >"$1"; return 0; }
FALLBACK_LOG="$TEST_ROOT/fallback.log"
xray_install_official_default() { printf 'fallback\n' >>"$FALLBACK_LOG"; return 0; }
# Simulate an architecture without a selectable asset.
xray_github_asset_name() { return 1; }
uname() { printf 'mips32'; }

# 13a-1. Refusal: the user must not get a silent fallback to an unpinned
#        target version.
rm -f "$FALLBACK_LOG"
set +e
printf '\n' | update_xray >"$update_xray_output" 2>&1
fallback_refused_rc=$?
set -e
(( fallback_refused_rc != 0 )) || fail "unpinned fallback ran without confirmation"
[[ ! -s "$FALLBACK_LOG" ]] || fail "refused fallback still installed the default version"
grep -q '无法固定目标版本' "$update_xray_output" ||
  fail "unpinned fallback warning missing"

# 13a-2. Explicit confirmation: the official default path is used.
rm -f "$FALLBACK_LOG"
set +e
printf 'y\n' | update_xray >"$update_xray_output" 2>&1
fallback_rc=$?
set -e
(( fallback_rc == 0 )) || fail "unsupported-arch fallback failed"
[[ "$(cat "$FALLBACK_LOG")" == "fallback" ]] ||
  fail "unsupported arch did not use the official default path"
grep -q '暂不支持版本选择' "$update_xray_output" ||
  fail "unsupported arch warning missing"
unset -f uname

# 13b. The official default path keeps backup and rollback semantics.
# Re-source the Core: function stubs above replaced the originals and bash
# cannot "unset" back to a previous definition.
# shellcheck source=../lib/xray-manager-core.sh
source "$ROOT_DIR/lib/xray-manager-core.sh"
# shellcheck disable=SC2034  # consumed by the sourced Core functions
INIT_SYS="systemd"
XRAY_BIN="$TEST_ROOT/fallback-xray"
cat >"$XRAY_BIN" <<'SH'
#!/usr/bin/env bash
echo "Xray 26.9.9 (OLD)"
SH
chmod +x "$XRAY_BIN"
FALLBACK_OLD_SHA="$(sha256sum "$XRAY_BIN" | awk '{print $1}')"
OFFICIAL_CALLS="$TEST_ROOT/official-calls.log"
run_systemd_installer() {
  local IFS=' '
  printf '%s\n' "$*" >>"$OFFICIAL_CALLS"
  cat >"$XRAY_BIN" <<'SH'
#!/usr/bin/env bash
echo "Xray 26.9.9 (OFFICIAL-NEW)"
SH
  chmod +x "$XRAY_BIN"
  return 0
}
download_to_tmp() { : >"$2"; return 0; }
test_config() { return 1; }
service_restart() { return 0; }
xray_service_active() { return 0; }
xray_backup_core() {
  mkdir -p "$TEST_ROOT/fallback-backup"
  cp "$XRAY_BIN" "$TEST_ROOT/fallback-backup/xray"
  printf '%s' "$TEST_ROOT/fallback-backup"
}
ensure_layout() { :; }
: >"$OFFICIAL_CALLS"
set +e
xray_install_official_default >/dev/null 2>&1
official_rc=$?
set -e
(( official_rc != 0 )) || fail "official default path ignored a config test failure"
[[ "$(sha256sum "$XRAY_BIN" | awk '{print $1}')" == "$FALLBACK_OLD_SHA" ]] ||
  fail "official default path did not roll back"
grep -Eq '(^| )install$' "$OFFICIAL_CALLS" ||
  fail "official default install call should not pin a version: $(cat "$OFFICIAL_CALLS")"
grep -q -- '--version' "$OFFICIAL_CALLS" &&
  fail "official default path unexpectedly passed --version"

test_config() { return 0; }
: >"$OFFICIAL_CALLS"
if ! xray_install_official_default >/dev/null 2>&1; then
  fail "official default success path failed"
fi

# ---------------------------------------------------------------------------
# 14. install_or_repair_xray fallbacks require explicit confirmation too
# ---------------------------------------------------------------------------
detect_platform() { :; }
prepare_existing_xray_config() { return 0; }
prepare_download_network() { return 0; }
pkg_install_base() { :; }
need_xray() { return 0; }
install_manager_command() { :; }
systemctl() { :; }

# 14a. GitHub API unavailable: default answer must abort without installing.
: >"$OFFICIAL_CALLS"
xray_github_fetch_releases() { return 1; }
set +e
printf '\n' | install_or_repair_xray >"$update_xray_output" 2>&1
install_fetch_rc=$?
set -e
(( install_fetch_rc != 0 )) || fail "install fallback ran without confirmation"
[[ ! -s "$OFFICIAL_CALLS" ]] || fail "refused install fallback still reached the installer"
grep -q '无法固定目标版本' "$update_xray_output" ||
  fail "install fallback warning missing"

# 14b. Explicit confirmation proceeds with the unpinned official default.
: >"$OFFICIAL_CALLS"
set +e
printf 'y\n' | install_or_repair_xray >"$update_xray_output" 2>&1
install_fetch_ok_rc=$?
set -e
(( install_fetch_ok_rc == 0 )) || fail "confirmed install fallback failed: $(cat "$update_xray_output")"
grep -Eq '(^| )install$' "$OFFICIAL_CALLS" ||
  fail "install fallback should not pin a version: $(cat "$OFFICIAL_CALLS")"
grep -q -- '--version' "$OFFICIAL_CALLS" &&
  fail "install fallback unexpectedly passed --version"

# 14c. Unsupported architecture takes the same confirmation path.
: >"$OFFICIAL_CALLS"
xray_github_fetch_releases() { printf '[]' >"$1"; return 0; }
xray_github_asset_name() { return 1; }
uname() { printf 'mips32'; }
set +e
printf '\n' | install_or_repair_xray >"$update_xray_output" 2>&1
install_arch_rc=$?
set -e
(( install_arch_rc != 0 )) || fail "unsupported-arch install fallback ran without confirmation"
[[ ! -s "$OFFICIAL_CALLS" ]] || fail "refused unsupported-arch fallback reached the installer"
grep -q '暂不支持版本选择' "$update_xray_output" ||
  fail "unsupported-arch install warning missing"

: >"$OFFICIAL_CALLS"
set +e
printf 'y\n' | install_or_repair_xray >"$update_xray_output" 2>&1
install_arch_ok_rc=$?
set -e
(( install_arch_ok_rc == 0 )) || fail "confirmed unsupported-arch fallback failed"
grep -Eq '(^| )install$' "$OFFICIAL_CALLS" ||
  fail "unsupported-arch fallback should not pin a version: $(cat "$OFFICIAL_CALLS")"
unset -f uname

echo "Xray version selection tests passed."
