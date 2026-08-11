#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

releases_file="${1:?GitHub releases JSON path is required}"
fallback_version="${2:?Fallback Xray version is required}"
delay_days="${3:-14}"
now_epoch="${4:-$(date -u +%s)}"

[[ "$fallback_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$delay_days" =~ ^[0-9]+$ ]]
[[ "$now_epoch" =~ ^[0-9]+$ ]]

cutoff_epoch=$((now_epoch - delay_days * 86400))
selected="$(
  jq -r --argjson cutoff "$cutoff_epoch" '
    [
      .[]
      | select(.draft == false and .prerelease == false)
      | select(.published_at != null)
      | . + {published_epoch: (.published_at | fromdateiso8601)}
      | select(.published_epoch <= $cutoff)
    ]
    | sort_by(.published_epoch)
    | last
    | .tag_name // empty
  ' "$releases_file" 2>/dev/null || true
)"

if [[ "$selected" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' "$selected"
else
  printf '%s\n' "$fallback_version"
fi
