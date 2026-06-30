#!/usr/bin/env bash
# Local smoke tests for run.sh (no network, upload: false paths).
set -u
cd "$(dirname "$0")/.." || exit 1
failures=0

run_case() {
  local name="$1" expected="$2"
  shift 2
  local out
  # These cases feed a plain command as `run` (they test collect/upload/validate,
  # not the rperf wrapping), so default record=false — a case can override with
  # PRPERF_RECORD=true in its own env args.
  out="$(GITHUB_STEP_SUMMARY=/dev/null PRPERF_RECORD=false "$@" bash ./run.sh 2>&1)"
  local code=$?
  if [ "$code" -ne "$expected" ]; then
    echo "FAIL $name: exit $code (expected $expected)"
    # sed cleanly indents each line of the captured output
    # shellcheck disable=SC2001
    echo "$out" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A profile with the new (meta-embedding) format
printf '{"meta":{"format_version":1},"summary":{"total_ms":1}}' | gzip > "$tmp/new.json.gz"
# A profile in the old format
printf '{"mode":"cpu","aggregated_samples":[]}' | gzip > "$tmp/old.json.gz"

run_case "measure + collect, upload disabled" 0 \
  env PRPERF_RUN="cp $tmp/new.json.gz \"\$PRPERF_DIR/\"" PRPERF_COUNT=2 \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

run_case "old rperf format is a clear error" 1 \
  env PRPERF_RUN="cp $tmp/old.json.gz \"\$PRPERF_DIR/\"" PRPERF_COUNT=1 \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

run_case "no profile produced is an error" 1 \
  env PRPERF_RUN="true" PRPERF_COUNT=1 \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

run_case "failing measurement command fails" 1 \
  env PRPERF_RUN="false" PRPERF_COUNT=1 \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

run_case "missing id-token permission is a clear error" 1 \
  env PRPERF_RUN="cp $tmp/new.json.gz \"\$PRPERF_DIR/\"" PRPERF_COUNT=1 \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=true

run_case "invalid count is rejected" 1 \
  env PRPERF_RUN="true" PRPERF_COUNT=zero \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

run_case "unsafe benchmark name is rejected" 1 \
  env PRPERF_RUN="true" PRPERF_COUNT=1 PRPERF_BENCHMARK="../etc" \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

run_case "named benchmark measures + collects" 0 \
  env PRPERF_RUN="cp $tmp/new.json.gz \"\$PRPERF_DIR/\"" PRPERF_COUNT=1 \
      PRPERF_BENCHMARK=boot PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

run_case "prepare_run runs before measuring" 0 \
  env PRPERF_PREPARE_RUN="echo prepared" \
      PRPERF_RUN="cp $tmp/new.json.gz \"\$PRPERF_DIR/\"" PRPERF_COUNT=1 \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

run_case "prepare_run failure fails the step" 1 \
  env PRPERF_PREPARE_RUN="false" \
      PRPERF_RUN="cp $tmp/new.json.gz \"\$PRPERF_DIR/\"" PRPERF_COUNT=1 \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

# record: true wiring — a fake `rperf` on PATH answers `--print-env`, and the
# action must source it, become root, and exec the command verbatim (here a cp
# that produces the profile). No real rperf / network needed.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/rperf" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" --print-env "*) echo "export RPERF_FAKE=1"; exit 0 ;;
  *" --version "*)   echo "rperf 9.9.9"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$tmp/bin/rperf"
run_case "record=true sources --print-env and execs the command verbatim" 0 \
  env PRPERF_RECORD=true PATH="$tmp/bin:$PATH" \
      PRPERF_RUN="cp $tmp/new.json.gz \"\$PRPERF_DIR/\"" PRPERF_COUNT=1 \
      PRPERF_SERVER=http://unused PRPERF_UPLOAD=false

[ "$failures" -eq 0 ] || exit 1
echo "all smoke tests passed"
