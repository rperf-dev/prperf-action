# prperf-action

Runs your Ruby benchmark under [rperf](https://github.com/ko1/rperf) in CI
and uploads the profiles to a [prperf](https://github.com/rperf-dev/server)
server, which posts the base-vs-PR comparison to a GitHub Check Run (and a
PR comment when your thresholds are exceeded).

Requirements:

- **rperf >= 0.10** in your bundle (profiles must embed `meta`/`summary`;
  the action fails with a clear error on older versions)
- **`permissions: id-token: write`** on the job — uploads authenticate with
  the GitHub Actions OIDC token, so there are no API keys or secrets
- the [prperf GitHub App](https://github.com/apps/prperf) installed on the
  repository

## Usage

Two workflows: one for PRs (the comparison target), one for pushes to the
default branch (the comparison **base** — without it there is nothing to
compare against).

```yaml
# .github/workflows/prperf-pr.yml
name: prperf
on: pull_request

jobs:
  bench:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # required: OIDC upload auth
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - uses: rperf-dev/prperf-action@v1
        with:
          run: bundle exec rperf record --snapshot-dir "$PRPERF_DIR" -- ruby bench/main.rb
```

```yaml
# .github/workflows/prperf-main.yml
name: prperf (base)
on:
  push:
    branches: [ main ]

jobs:
  bench:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - uses: rperf-dev/prperf-action@v1
        with:
          run: bundle exec rperf record --snapshot-dir "$PRPERF_DIR" -- ruby bench/main.rb
```

## Inputs

| Input | Description | Default |
|---|---|---|
| `run` | Measurement command (required). Must produce `.json.gz` profile(s); `$PRPERF_DIR` is provided as a convenient `--snapshot-dir` target. | — |
| `prepare_run` | One-time setup command, run ONCE before the measurement runs and NOT measured (e.g. generate fixtures, seed a DB, build assets). A failure fails the step. | `""` |
| `count` | Number of measurement runs (each gets a `run=N` label; the server compares the median) | `3` |
| `benchmark` | Name of this benchmark series (e.g. `boot`, `endpoint1`). One commit can carry several benchmarks, each compared independently. | `default` |
| `thresholds` | YAML thresholds for THIS benchmark; overrides the job-level defaults per key (see below). | `""` |
| `comment` | Sticky PR comment mode: `always` / `on_threshold` / `never`. | `on_threshold` |
| `server` | prperf server origin | `https://prperf.atdot.net` |
| `upload` | Set `false` to measure without uploading | `true` |

Everything — measurement commands and all threshold/comment policy — lives
in the workflow; there is no separate config file.

## Multiple benchmarks

A single commit can be measured by several benchmarks — use one action step
per benchmark, giving each a distinct `benchmark` name. The server compares
each benchmark against its own base and shows all of them in one Check Run.
Use the same `benchmark` names in your PR and base (default-branch)
workflows so each series has a baseline.

## Thresholds (optional)

Thresholds are opt-in. With none, the Check Run still shows the numbers — you
add thresholds only when you want a ⚠️ and (per `comment`) a PR comment on a
regression. Exceeding one never fails the build.

The simplest setup, and all most projects need: one global block for every
benchmark, in a job-level `env`. The steps need nothing extra.

```yaml
jobs:
  bench:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    env:
      PRPERF_DEFAULT_THRESHOLDS: |     # applies to every benchmark
        alloc: "+10%"
        total_ms: "+20%"
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - uses: rperf-dev/prperf-action@v1
        with:
          benchmark: boot
          run: bundle exec rperf record --snapshot-dir "$PRPERF_DIR" -- bin/rails runner ""
```

Threshold keys: `alloc` / `gc_count` / `total_ms` / `cpu_ms` with a value
`"+N%"` (relative) or `"+N"` (absolute), and `method` (a mapping of method
name to `"N%"` absolute self-time share). Bad entries are ignored with a
warning on the Check Run.

### Per-benchmark overrides (advanced)

If one benchmark needs different thresholds, add a `thresholds` input on its
step — it overrides the global defaults per key. Most projects won't need this.

```yaml
      - uses: rperf-dev/prperf-action@v1
        with:
          benchmark: endpoint1
          run: bundle exec rperf record --snapshot-dir "$PRPERF_DIR" -- ruby bench/endpoint1.rb
          thresholds: |
            alloc: "+5%"               # tightens the global +10% for endpoint1
```

## Behavior and limitations

- The measurement command failing **fails the step**; upload problems
  (plan limits, rate limits, server errors) only emit warnings — prperf
  never blocks your CI.
- A link to the uploaded profile is written to the job's step summary.
- **PRs from forks cannot upload**: GitHub does not grant `id-token: write`
  to fork-triggered workflows, so no OIDC token exists there. Same-repo
  branch PRs work normally.
