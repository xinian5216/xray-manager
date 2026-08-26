#!/usr/bin/env bash
# Resolve and verify Xray GitHub release assets. Fail closed on any digest/source anomaly.
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage:
  bash scripts/verify-xray-asset.sh --json FILE --tag TAG --name NAME [--print-url|--print-sha256]
  bash scripts/verify-xray-asset.sh --json FILE --tag TAG --name NAME --file FILE [--dgst FILE]
EOF
}

JSON_FILE=""
TAG=""
ASSET_NAME=""
DOWNLOADED=""
DGST_FILE=""
PRINT_URL=0
PRINT_SHA256=0

while (($#)); do
  case "$1" in
    --json) JSON_FILE="${2:?--json requires a file}"; shift 2 ;;
    --tag) TAG="${2:?--tag requires a tag}"; shift 2 ;;
    --name) ASSET_NAME="${2:?--name requires an asset name}"; shift 2 ;;
    --file) DOWNLOADED="${2:?--file requires a path}"; shift 2 ;;
    --dgst) DGST_FILE="${2:?--dgst requires a path}"; shift 2 ;;
    --print-url) PRINT_URL=1; shift ;;
    --print-sha256) PRINT_SHA256=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$JSON_FILE" && -n "$TAG" && -n "$ASSET_NAME" ]] || {
  usage >&2
  exit 2
}

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Rejected tag: $TAG" >&2
  exit 1
}

[[ "$ASSET_NAME" =~ ^Xray-linux-(64|arm64-v8a)\.zip$ ]] || {
  echo "Rejected asset name: $ASSET_NAME" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 1
  fi
}

normalize_sha256() {
  local value="${1,,}"
  value="${value#sha256:}"
  value="${value#sha2-256=}"
  value="${value//[[:space:]]/}"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$value"
}

parse_dgst_sha256() {
  local file="$1" line value seen=""
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^SHA2-256=[[:space:]]*([0-9A-Fa-f]{64})[[:space:]]*$ ]] || continue
    value="$(normalize_sha256 "${BASH_REMATCH[1]}")" || {
      echo "Malformed SHA2-256 in $file" >&2
      return 1
    }
    if [[ -n "$seen" && "$seen" != "$value" ]]; then
      echo "Conflicting SHA2-256 digests in $file" >&2
      return 1
    fi
    seen="$value"
  done <"$file"
  [[ -n "$seen" ]] || {
    echo "No SHA2-256 digest in $file" >&2
    return 1
  }
  printf '%s' "$seen"
}

release_json="$(
  jq -ce --arg tag "$TAG" --arg name "$ASSET_NAME" '
    def items:
      if type == "array" then .[]
      elif type == "object" and has("tag_name") then .
      else empty
      end;
    def matches($asset):
      (.name == $name) and
      ((.browser_download_url | type) == "string");
    [ items | select(.tag_name == $tag and .draft != true and .prerelease != true) ] as $rels
    | if ($rels | length) != 1 then
        error("expected exactly one release for \($tag), found \($rels | length)")
      else
        $rels[0] as $rel
        | [ $rel.assets[]? | select(matches($name)) ] as $assets
        | if ($assets | length) != 1 then
            error("expected exactly one asset \($name), found \($assets | length)")
          else
            $assets[0] + {tag_name: $rel.tag_name}
          end
      end
  ' "$JSON_FILE" 2>/dev/null || true
)"

if ! jq -e 'type == "object" and (.name | type) == "string" and ((.browser_download_url | type) == "string") and ((.browser_download_url | length) > 0)' >/dev/null 2>&1 <<<"$release_json"; then
  echo "Unable to resolve unique $ASSET_NAME for $TAG" >&2
  exit 1
fi

url="$(jq -r '.browser_download_url' <<<"$release_json")"
expected_url="https://github.com/XTLS/Xray-core/releases/download/${TAG}/${ASSET_NAME}"
if [[ "$url" != "$expected_url" ]]; then
  echo "Rejected download URL for $ASSET_NAME: $url" >&2
  exit 1
fi

api_digest="$(jq -r '.digest // empty' <<<"$release_json")"
expected=""
if [[ -n "$api_digest" ]]; then
  expected="$(normalize_sha256 "$api_digest")" || {
    echo "Malformed GitHub API digest for $ASSET_NAME: $api_digest" >&2
    exit 1
  }
fi

if [[ -n "$DGST_FILE" ]]; then
  dgst_digest="$(parse_dgst_sha256 "$DGST_FILE")" || exit 1
  if [[ -n "$expected" && "$expected" != "$dgst_digest" ]]; then
    echo "GitHub API digest and .dgst disagree for $ASSET_NAME" >&2
    exit 1
  fi
  expected="${expected:-$dgst_digest}"
fi

if [[ -z "$expected" ]]; then
  if (( PRINT_SHA256 )) || [[ -n "$DOWNLOADED" ]]; then
    echo "No usable SHA256 digest for $ASSET_NAME (API digest and .dgst both missing)" >&2
    exit 1
  fi
fi

if (( PRINT_URL )); then
  printf '%s\n' "$url"
fi
if (( PRINT_SHA256 )); then
  printf '%s\n' "$expected"
fi

if [[ -n "$DOWNLOADED" ]]; then
  [[ -f "$DOWNLOADED" ]] || {
    echo "Downloaded file missing: $DOWNLOADED" >&2
    exit 1
  }
  actual="$(sha256_file "$DOWNLOADED")" || exit 1
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA256 mismatch for $ASSET_NAME" >&2
    echo "expected $expected" >&2
    echo "actual   $actual" >&2
    exit 1
  fi
  printf '%s\n' "$actual"
elif (( PRINT_URL == 0 && PRINT_SHA256 == 0 )); then
  echo "Specify --file, --print-url or --print-sha256" >&2
  exit 2
fi
