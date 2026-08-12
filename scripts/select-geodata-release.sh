#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

releases_file="${1:?GitHub releases JSON path is required}"
delay_days="${2:-7}"
now_epoch="${3:-$(date -u +%s)}"

[[ -s "$releases_file" ]] || {
  echo "GeoData releases JSON is empty or missing: $releases_file" >&2
  exit 1
}
[[ "$delay_days" =~ ^[0-9]+$ ]]
[[ "$now_epoch" =~ ^[0-9]+$ ]]

cutoff_epoch=$((now_epoch - delay_days * 86400))
selected="$(
  jq -ce --argjson cutoff "$cutoff_epoch" '
    def valid_asset($name):
      [
        .assets[]?
        | select(
            .name == $name and
            (.browser_download_url | type) == "string" and
            (.browser_download_url | length) > 0
          )
      ]
      | length == 1;

    [
      .[]
      | select(type == "object")
      | select(.draft == false and .prerelease == false)
      | select(.published_at != null and (.assets | type) == "array")
      | select(
          valid_asset("geoip.dat") and
          valid_asset("geoip.dat.sha256sum") and
          valid_asset("geosite.dat") and
          valid_asset("geosite.dat.sha256sum")
        )
      | . + {
          published_epoch: (
            try (.published_at | fromdateiso8601)
            catch null
          )
        }
      | select(.published_epoch != null and .published_epoch <= $cutoff)
    ]
    | sort_by(.published_epoch)
    | last
  ' "$releases_file" 2>/dev/null || true
)"

if ! jq -e '
  type == "object" and
  (.tag_name | type) == "string" and
  (.tag_name | length) > 0
' >/dev/null 2>&1 <<<"$selected"; then
  echo "No complete GeoData release has passed the ${delay_days}-day observation period" >&2
  exit 1
fi

printf '%s\n' "$selected"
