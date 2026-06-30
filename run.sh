#!/usr/bin/env bash
# prperf-action driver: run the measurement command N times under rperf, collect
# the generated .json.gz profiles, upload them with an OIDC token, and — for a
# public (install-free) repo — write the Check Run + sticky comment with the
# workflow token. Installed repos are written server-side by the prperf App.
#
# Failure policy:
# - the measurement command failing fails the step (a broken benchmark is
#   the user's signal to act on)
# - upload / Check-Run / comment problems NEVER fail the step (warnings only) —
#   prperf must not block anyone's CI
set -u

count="${PRPERF_COUNT:-3}"
server="${PRPERF_SERVER%/}"
upload="${PRPERF_UPLOAD:-true}"
record="${PRPERF_RECORD:-true}"
rperf_version="${PRPERF_RPERF_VERSION:-}"
benchmark="${PRPERF_BENCHMARK:-default}"
thresholds="${PRPERF_THRESHOLDS:-}"
comment="${PRPERF_COMMENT:-on_threshold}"
prepare_run="${PRPERF_PREPARE_RUN:-}"
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

# Write (or update) the Check Run and sticky comment for a public repo, using
# GH_TOKEN. The server already rendered them (it stored the profiles but cannot
# write as the App with no installation); we ask /checks/render for the payload
# — aggregated across every benchmark for this head sha — and write it. Each
# call upserts the same Check Run (matched by head sha + name) and the same
# comment (matched by a hidden marker), so multiple benchmark steps fill in one
# Check Run. Everything here is best-effort: never fail the step.
write_check_run() {
  local oidc="$1"
  local head_sha base_ref base_sha pr_number payload
  head_sha="$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")"
  base_ref="$(jq -r '.pull_request.base.ref // empty' "$GITHUB_EVENT_PATH")"
  base_sha="$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")"
  pr_number="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
  [ -n "$head_sha" ] || { echo "::warning::no PR head sha; skipping Check Run"; return; }

  payload="$(curl -sf -X POST "$server/api/v1/checks/render" \
    -H "Authorization: Bearer $oidc" -H "Content-Type: application/json" \
    -d "$(jq -n --arg h "$head_sha" --arg br "$base_ref" --arg bs "$base_sha" \
            '{head_sha:$h, base_ref:$br, base_sha:$bs}')")" || {
    echo "::warning::could not render the Check Run (server error); skipping"
    return
  }

  local name title summary
  name="$(jq -r '.check_run.name' <<<"$payload")"
  title="$(jq -r '.check_run.title' <<<"$payload")"
  summary="$(jq -r '.check_run.summary' <<<"$payload")"

  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::warning::no token to write the Check Run. Add 'permissions: checks: write'" \
         "and 'pull-requests: write' (public repos are written with the workflow token)."
    return
  fi

  # Upsert the Check Run: PATCH the existing one for this head sha+name, else
  # POST. The body is built with jq and sent via --input - so the nested
  # `output` object is real JSON (gh's -f does not parse bracket nesting).
  local existing
  existing="$(gh api "repos/$GITHUB_REPOSITORY/commits/$head_sha/check-runs" \
    -q ".check_runs[] | select(.name==\"$name\") | .id" 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then
    jq -n --arg t "$title" --arg s "$summary" \
      '{status:"completed", conclusion:"success", output:{title:$t, summary:$s}}' \
      | gh api -X PATCH "repos/$GITHUB_REPOSITORY/check-runs/$existing" --input - >/dev/null 2>&1 \
      || echo "::warning::could not update the Check Run (need 'checks: write')"
  else
    jq -n --arg n "$name" --arg sha "$head_sha" --arg t "$title" --arg s "$summary" \
      '{name:$n, head_sha:$sha, status:"completed", conclusion:"success", output:{title:$t, summary:$s}}' \
      | gh api -X POST "repos/$GITHUB_REPOSITORY/check-runs" --input - >/dev/null 2>&1 \
      || echo "::warning::could not create the Check Run (need 'checks: write')"
  fi

  # Sticky comment: upsert by hidden marker when the server says to post one.
  if [ "$(jq -r '.comment.post' <<<"$payload")" = "true" ] && [ -n "$pr_number" ]; then
    local marker body cid
    marker="$(jq -r '.comment.marker' <<<"$payload")"
    body="$(jq -r '.comment.body' <<<"$payload")"
    cid="$(gh api "repos/$GITHUB_REPOSITORY/issues/$pr_number/comments" --paginate \
      -q ".[] | select(.body | contains(\"$marker\")) | .id" 2>/dev/null | head -1)"
    if [ -n "$cid" ]; then
      jq -n --arg b "$body" '{body:$b}' \
        | gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$cid" --input - >/dev/null 2>&1 \
        || echo "::warning::could not update the PR comment (need 'pull-requests: write')"
    else
      jq -n --arg b "$body" '{body:$b}' \
        | gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$pr_number/comments" --input - >/dev/null 2>&1 \
        || echo "::warning::could not post the PR comment (need 'pull-requests: write')"
    fi
  fi
}

# A directory the measurement command may use via --snapshot-dir "$PRPERF_DIR";
# profiles written anywhere in the workspace are found too.
PRPERF_DIR="$(mktemp -d)"
export PRPERF_DIR

marker="$(mktemp)"
profiles=()

# One-time setup before measuring (generate fixtures, seed a DB, build assets).
# Not measured; it runs before the marker, so anything it writes is never
# collected as a profile. A failure here fails the step.
if [ -n "$prepare_run" ]; then
  echo "::group::prepare_run"
  if ! bash -c "$prepare_run"; then
    echo "::endgroup::"
    echo "::error::prepare_run failed"
    exit 1
  fi
  echo "::endgroup::"
fi

# With record=true we measure WITHOUT touching the user's command: rperf's
# `--print-env` tells us the env a profiled process auto-starts from, we source
# it, become the session root, and exec the command verbatim. So a `bundle exec`
# command stays bundler-managed and a plain `ruby …` stays plain — the action
# never adds `bundle exec`. rperf must be loadable in the profiled process:
#   - Bundler project -> from the bundle. If rperf is not in it, `bundle add`
#     rescues most cases (frozen lockfile / Ruby<3.4 / no compiler -> warn).
#   - no Gemfile      -> a standalone gem-installed rperf.
# `rperf_env` is the command that emits the env (run once per measurement).
rperf_env=()
if [ "$record" = "true" ]; then
  if [ -n "${BUNDLE_GEMFILE:-}" ] || [ -f Gemfile ] || [ -f gems.rb ]; then
    if ! bundle exec rperf --version >/dev/null 2>&1; then
      echo "::group::bundle add rperf"
      bundle add rperf >/dev/null 2>&1 \
        || echo "::warning::could not add rperf to the bundle (frozen lockfile, Ruby < 3.4," \
                "or no compiler). A 'bundle exec' or bin/rails benchmark needs rperf in your" \
                "Gemfile (a 'group :rperf' is fine)."
      echo "::endgroup::"
    fi
    bundle exec rperf --version >/dev/null 2>&1 && rperf_env=(bundle exec rperf)
  fi
  if [ "${#rperf_env[@]}" -eq 0 ]; then
    if ! command -v rperf >/dev/null 2>&1; then
      echo "::group::install rperf"
      if [ -n "$rperf_version" ]; then
        gem install --no-document rperf -v "$rperf_version"
      else
        gem install --no-document rperf
      fi
      echo "::endgroup::"
    fi
    rperf_env=(rperf)
  fi
fi

export PRPERF_RUN
printenv_cmd=""
[ "$record" = "true" ] && \
  printenv_cmd="${rperf_env[*]} record --snapshot-dir $(printf '%q' "$PRPERF_DIR") --print-env"

for n in $(seq 1 "$count"); do
  echo "::group::rperf run $n/$count"
  touch "$marker"
  # The labels end up in meta.labels (rperf reads RPERF_META_LABELS). `bench`
  # selects the comparison series on the server; `run` is the repeat.
  labels="{\"bench\":\"$benchmark\",\"run\":$n}"
  measure_ok=1
  if [ "$record" = "true" ]; then
    # Source rperf's env, then become the session root (export the pid that will
    # exec the command, so that process — not this shell's child — is root) and
    # exec the command verbatim. `eval "exec …"` keeps the user's quoting.
    env RPERF_META_LABELS="$labels" bash -c '
      _env="$('"$printenv_cmd"')" || { echo "::error::rperf --print-env failed" >&2; exit 1; }
      eval "$_env"
      export RPERF_ROOT_PROCESS=$$
      eval "exec $PRPERF_RUN"
    ' || measure_ok=
  else
    # record=false: the user invokes rperf themselves; run verbatim.
    env RPERF_META_LABELS="$labels" bash -c "$PRPERF_RUN" || measure_ok=
  fi
  if [ -z "$measure_ok" ]; then
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
  echo "::error::no .json.gz profile was produced — make the command write one" \
       "(rperf record writes to \$PRPERF_DIR). With record: false, your command" \
       "must run 'rperf record --snapshot-dir \"\$PRPERF_DIR\" -- ...' itself."
  exit 1
fi
echo "collected ${#profiles[@]} profile(s)"

# rperf >= 0.11.1 embeds meta/summary as the leading JSON keys; older versions
# produce profiles the server cannot use.
if ! zcat -- "${profiles[0]}" 2>/dev/null | head -c 4096 | grep -q '"meta"'; then
  echo "::error::profile has no embedded meta/summary — rperf >= 0.11.1 is required" \
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
write_mode=""
uploaded=0
for f in "${profiles[@]}"; do
  response="$(mktemp)"
  http_code="$(curl -s -o "$response" -w '%{http_code}' -X POST "$server/api/v1/upload" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/gzip" \
    -H "X-Prperf-Default-Thresholds: $default_thresholds_b64" \
    -H "X-Prperf-Thresholds: $thresholds_b64" -H "X-Prperf-Comment: $comment" \
    --data-binary "@$f" || echo 000)"
  if [ "$http_code" = "201" ]; then
    uploaded=$((uploaded + 1))
    view_url="$(jq -r '.view_url // empty' "$response")"
    write_mode="$(jq -r '.write_mode // empty' "$response")"
  else
    # Any non-201 is a warning only (CI is never failed). Surface the server's
    # message when it sent one (install hint, plan limit, format_version, …).
    msg="$(jq -r '.error // empty' "$response" 2>/dev/null)"
    if [ -n "$msg" ]; then
      echo "::warning::upload rejected ($http_code): $msg"
    else
      echo "::warning::upload of $(basename "$f") failed (HTTP $http_code)"
    fi
  fi
done

# Public, install-free repo on a PR: the server stored the profiles but does not
# write the Check Run (no App installation to write as) — write_mode "action".
# (write_mode "server" = installed repo, already written by the App.)
if [ "$uploaded" -gt 0 ] && [ "$write_mode" = "action" ] \
   && [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ -n "${GITHUB_EVENT_PATH:-}" ]; then
  write_check_run "$token"
fi

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
