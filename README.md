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
| `count` | Number of measurement runs (each gets a `run=N` label; the server compares the median) | `3` |
| `benchmark` | Name of this benchmark series (e.g. `boot`, `endpoint1`). One commit can carry several benchmarks, each compared independently. | `default` |
| `server` | prperf server origin | `https://rperf.atdot.net` |
| `upload` | Set `false` to measure without uploading | `true` |

## Multiple benchmarks

A single commit can be measured by several benchmarks — use one action step
per benchmark, giving each a distinct `benchmark` name. The server compares
each benchmark against its own base and shows all of them in one Check Run.

```yaml
- uses: rperf-dev/prperf-action@v1
  with:
    benchmark: boot
    run: bundle exec rperf record --snapshot-dir "$PRPERF_DIR" -- bin/rails runner ""
- uses: rperf-dev/prperf-action@v1
  with:
    benchmark: render
    run: bundle exec rperf record --snapshot-dir "$PRPERF_DIR" -- ruby bench/render.rb
```

Thresholds in `.prperf.yml` apply to every benchmark (relative thresholds
like `+10%` generalize across them). Use the same `benchmark` names in your
PR and base (default-branch) workflows so each series has a baseline.

## Behavior and limitations

- The measurement command failing **fails the step**; upload problems
  (plan limits, rate limits, server errors) only emit warnings — prperf
  never blocks your CI.
- A link to the uploaded profile is written to the job's step summary.
- **PRs from forks cannot upload**: GitHub does not grant `id-token: write`
  to fork-triggered workflows, so no OIDC token exists there. Same-repo
  branch PRs work normally.
- Thresholds and comment behavior are configured in the repository's
  `.prperf.yml` — see the server documentation.
