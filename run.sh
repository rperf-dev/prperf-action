#!/usr/bin/env bash
# prperf-action driver: run the measurement command N times, collect the
# generated .json.gz profiles, upload them with an OIDC token.
#
# Failure policy:
# - the measurement command failing fails the step (a broken benchmark is
#   the user's signal to act on)
# - upload problems NEVER fail the step (warnings only) — prperf must not
#   block anyone's CI
set -u

count="${PRPERF_COUNT:-3}"
server="${PRPERF_SERVER%/}"
upload="${PRPERF_UPLOAD:-true}"
benchmark="${PRPERF_BENCHMARK:-default}"
thresholds="${PRPERF_THRESHOLDS:-}"
comment="${PRPERF_COMMENT:-on_threshold}"
# Global defaults shared by every benchmark, set once as a job-level env var
# (ambient, not an action input). The per-step `thresholds` overrides it.
default_thresholds="${PRPERF_DEFAULT_THRESHOLDS:-}"

if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
  echo "::error::count must be a positive integer, got '$count'"
  exit 1
fi

if ! [[ "$benchmark" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "::error::benchmark must match [A-Za-z0-9._-]+, got '$benchmark'"
  exit 1
fi

# A directory the measurement command may use via --snapshot-dir "$PRPERF_DIR";
# profiles written anywhere in the workspace are found too.
PRPERF_DIR="$(mktemp -d)"
export PRPERF_DIR

marker="$(mktemp)"
profiles=()

for n in $(seq 1 "$count"); do
  echo "::group::rperf run $n/$count"
  touch "$marker"
  # The labels end up in meta.labels (rperf reads RPERF_META_LABELS; same
  # mechanism as --label, but injectable without rewriting the user command).
  # `bench` selects the comparison series on the server; `run` is the repeat.
  if ! RPERF_META_LABELS="{\"bench\":\"$benchmark\",\"run\":$n}" bash -c "$PRPERF_RUN"; then
    echo "::endgroup::"
    echo "::error::measurement command failed on run $n"
    exit 1
  fi
  echo "::endgroup::"

  while IFS= read -r -d '' f; do
    profiles+=("$f")
  done < <(find "$PRPERF_DIR" "$PWD" -name '*.json.gz' -newer "$marker" \
             -not -path "$PWD/.git/*" -print0 2>/dev/null)
done

if [ "${#profiles[@]}" -eq 0 ]; then
  echo "::error::no .json.gz profile was produced — make the command write one," \
       "e.g.: bundle exec rperf record --snapshot-dir \"\$PRPERF_DIR\" -- ruby bench.rb"
  exit 1
fi
echo "collected ${#profiles[@]} profile(s)"

# rperf >= 0.10 embeds meta/summary as the leading JSON keys; older versions
# produce profiles the server cannot use.
if ! zcat -- "${profiles[0]}" 2>/dev/null | head -c 4096 | grep -q '"meta"'; then
  echo "::error::profile has no embedded meta/summary — rperf >= 0.10 is required" \
       "(found an older profile format)"
  exit 1
fi

[ "$upload" = "true" ] || { echo "upload: false — skipping upload"; exit 0; }

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::error::OIDC token unavailable. Add 'permissions: id-token: write' to the job." \
       "Note: workflows triggered by PRs from forks never get OIDC tokens."
  exit 1
fi

token="$(curl -sf -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=rperf-ci" | jq -r '.value')"
if [ -z "$token" ] || [ "$token" = "null" ]; then
  echo "::warning::could not obtain an OIDC token; skipping upload"
  exit 0
fi

# Threshold/comment policy travels with the upload (the server parses,
# validates and merges global ⊕ override). base64 keeps multi-line YAML safe
# in a header; `tr -d` drops the newlines some base64 implementations wrap at.
thresholds_b64="$(printf '%s' "$thresholds" | base64 | tr -d '\n')"
default_thresholds_b64="$(printf '%s' "$default_thresholds" | base64 | tr -d '\n')"

view_url=""
uploaded=0
for f in "${profiles[@]}"; do
  response="$(mktemp)"
  http_code="$(curl -s -o "$response" -w '%{http_code}' -X POST "$server/api/v1/upload" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/gzip" \
    -H "X-Prperf-Default-Thresholds: $default_thresholds_b64" \
    -H "X-Prperf-Thresholds: $thresholds_b64" -H "X-Prperf-Comment: $comment" \
    --data-binary "@$f" || echo 000)"
  case "$http_code" in
    201)
      uploaded=$((uploaded + 1))
      view_url="$(jq -r '.view_url // empty' "$response")"
      ;;
    402|429)
      echo "::warning::upload rejected ($http_code): $(jq -r '.error // empty' "$response")"
      ;;
    *)
      echo "::warning::upload of $(basename "$f") failed (HTTP $http_code)"
      ;;
  esac
done

{
  echo "### prperf"
  echo ""
  if [ "$uploaded" -gt 0 ]; then
    echo "Uploaded $uploaded/${#profiles[@]} profile(s)."
    [ -n "$view_url" ] && echo "" && echo "[Open in viewer]($server$view_url)"
  else
    echo "No profiles were uploaded (see job log warnings)."
  fi
} >> "$GITHUB_STEP_SUMMARY"

exit 0
