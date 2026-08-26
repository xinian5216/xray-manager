#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../xray-manager.sh
source "$ROOT_DIR/xray-manager.sh"

PROJECT_VERSION="1.8.1"
[[ "$(manager_version_action 1.8.1 1.8.2)" == "upgrade" ]]
[[ "$(manager_version_action v1.8.1 2.0.0)" == "upgrade" ]]
[[ "$(manager_version_action 1.8.1 1.8.1)" == "reinstall" ]]
[[ "$(manager_version_action 1.8.1 1.7.9)" == "downgrade" ]]
[[ "$(manager_version_action 2.0.0 1.99.99)" == "downgrade" ]]
if manager_version_action 1.8 1.8.1 >/dev/null 2>&1; then
  echo "Version parser unexpectedly accepted a missing patch component" >&2
  exit 1
fi
if manager_version_action 1.8.1 01.8.2 >/dev/null 2>&1; then
  echo "Version parser unexpectedly accepted a leading zero" >&2
  exit 1
fi
if manager_version_action 1.8.1 '1.8.2;id' >/dev/null 2>&1; then
  echo "Version parser unexpectedly accepted shell syntax" >&2
  exit 1
fi

ALLOW_DOWNGRADE=0
if approve_target_version 1.7.9 >/dev/null 2>&1; then
  echo "Downgrade was accepted without explicit authorization" >&2
  exit 1
fi
ALLOW_DOWNGRADE=1
approve_target_version 1.7.9 >/dev/null

LOCK_DIR="$TEST_ROOT/manager.lock"
MANAGER_LOCK_HELD=0
acquire_manager_lock "first operation"
[[ "$(cat "$LOCK_DIR/operation")" == "first operation" ]]
if (
  MANAGER_LOCK_HELD=0
  acquire_manager_lock "second operation"
) >/dev/null 2>&1; then
  echo "Concurrent manager operation unexpectedly acquired the lock" >&2
  exit 1
fi
release_manager_lock
[[ ! -e "$LOCK_DIR" ]]

mkdir -m 700 "$LOCK_DIR"
printf '999999999\n' >"$LOCK_DIR/pid"
printf 'stale operation\n' >"$LOCK_DIR/operation"
printf '2000-01-01T00:00:00Z\n' >"$LOCK_DIR/started"
MANAGER_LOCK_HELD=0
acquire_manager_lock "replacement operation" >/dev/null
[[ "$(cat "$LOCK_DIR/operation")" == "replacement operation" ]]
release_manager_lock

mkdir -m 700 "$LOCK_DIR"
printf '999999999\n' >"$LOCK_DIR/pid"
printf 'stale operation\n' >"$LOCK_DIR/operation"
printf '2000-01-01T00:00:00Z\n' >"$LOCK_DIR/started"
printf 'keep\n' >"$LOCK_DIR/unknown"
MANAGER_LOCK_HELD=0
if acquire_manager_lock "unsafe cleanup" >/dev/null 2>&1; then
  echo "Lock cleanup unexpectedly removed an unknown file" >&2
  exit 1
fi
[[ -f "$LOCK_DIR/unknown" ]]

rm -f "$LOCK_DIR/unknown"
rmdir "$LOCK_DIR"

with_manager_lock "wrapped operation" true
[[ ! -e "$LOCK_DIR" ]]

(
  # shellcheck source=../lib/xray-manager-core.sh
  source "$ROOT_DIR/lib/xray-manager-core.sh"
  LOCK_DIR="$TEST_ROOT/core.lock"
  MANAGER_LOCK_HELD=0
  with_manager_lock "Core mutation" true
  [[ ! -e "$LOCK_DIR" ]]
)

echo "Version policy and global lock regression tests passed."

