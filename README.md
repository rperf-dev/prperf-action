# prperf-action

Runs your Ruby benchmark under [rperf](https://github.com/ko1/rperf) in CI and
uploads the profiles to a prperf server, which compares the PR against the base
branch. The base-vs-PR result is reported on a GitHub **Check Run** (and a sticky
PR comment when your thresholds are exceeded). It never blocks CI.

**Public repositories need no App install** — the action writes the Check Run
and comment with the workflow token. **Private repositories** install the
[prperf GitHub App](https://github.com/apps/prperf) so it can write the Check
Run server-side (free during the beta; paid plans come later).

Requirements:

- **rperf >= 0.11.1.** In a Bundler project, put `rperf` in your `Gemfile` (a
  `group :rperf` is fine) — the action measures with the bundle's rperf. With no
  Gemfile, the action installs rperf for you. Profiles must embed `meta`/`summary`;
  the action fails with a clear error on older formats.
- **`permissions`** on the job:
  - `id-token: write` — uploads authenticate with the OIDC token (no secrets)
  - `checks: write` and `pull-requests: write` — write the Check Run / comment
    (public repos; harmless to include for private)
  - `contents: read` — checkout
- For **private** repos: the prperf GitHub App installed on the repository.

## Usage

One workflow, triggered on both `pull_request` (the comparison target) and
`push` to the default branch (the comparison **base** — without it there is
nothing to compare against). prperf tells them apart from the OIDC token's ref;
list both `main` and `master` so it works either way.

```yaml
# .github/workflows/prperf.yml
name: prperf
on:
  push:
    branches: [ main, master ]   # records the base (default branch)
  pull_request:                  # compared against the base

jobs:
  bench:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write          # OIDC upload auth (no secrets)
      checks: write            # write the Check Run (public repos)
      pull-requests: write     # write the sticky comment (public repos)
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - uses: rperf-dev/prperf-action@v1
        with:
          run: ruby bench/main.rb   # ← just your command; the action wraps it in rperf
```

You write only the command you want to profile. The action wraps it in
`rperf record` for you (using the bundle's rperf, or one it installs when there
is no Gemfile). To take control of the rperf invocation yourself, set
`record: false` and write the full `rperf record ... -- ...` command in `run`.

## Inputs

| Input | Description | Default |
|---|---|---|
| `run` | Measurement command (required) — just the command to profile (e.g. `bin/rails runner ""`). The action wraps it in `rperf record`. With `record: false`, write the full `rperf record ... -- ...` yourself. | — |
| `record` | Wrap `run` in `rperf record` (uses the bundle's rperf, else an installed one). Set `false` to run `run` verbatim. | `true` |
| `rperf_version` | rperf version to install on the no-Gemfile path. Empty = latest. Ignored when a Gemfile is present or `record: false`. | `""` |
| `prepare_run` | One-time setup command, run ONCE before measuring and NOT measured (e.g. generate fixtures, seed a DB). A failure fails the step. | `""` |
| `count` | Number of measurement runs (each gets a `run=N` label; the server compares the median) | `3` |
| `benchmark` | Name of this benchmark series (e.g. `boot`, `endpoint1`). One commit can carry several, each compared independently. | `default` |
| `thresholds` | YAML thresholds for THIS benchmark; overrides the job-level defaults per key (see below). | `""` |
| `comment` | Sticky PR comment mode: `always` / `on_threshold` / `never`. | `on_threshold` |
| `server` | prperf server origin | `https://prperf.atdot.net` |
| `upload` | Set `false` to measure without uploading | `true` |
| `token` | Token used to write the Check Run/comment on public repos. | `${{ github.token }}` |

Everything — measurement commands and all threshold/comment policy — lives
in the workflow; there is no separate config file.

## Preparation (optional)

Need a one-time setup before measuring — generating fixtures, seeding a DB,
building assets? Put it in `prepare_run`. It runs once, before the measurement,
and is not itself measured; a failure fails the step. Use a fixed seed or input
so each run starts from the same state.

```yaml
      - uses: rperf-dev/prperf-action@v1
        with:
          prepare_run: bin/rails db:prepare db:seed   # once, before measuring
          run: ruby bench/request.rb
```

## Multiple benchmarks

A single commit can be measured by several benchmarks — use one action step
per benchmark, giving each a distinct `benchmark` name. The server compares
each benchmark against its own base and shows all of them in one Check Run.
Since the one workflow runs on both `push` and `pull_request`, each series'
base and PR runs share a `benchmark` name automatically — which is what gives
each series a baseline.

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
    permissions:
      contents: read
      id-token: write
      checks: write
      pull-requests: write
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
          run: bin/rails runner ""
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
          run: ruby bench/endpoint1.rb
          thresholds: |
            alloc: "+5%"               # tightens the global +10% for endpoint1
```

## Behavior and limitations

- The measurement command failing **fails the step**; upload, Check-Run, and
  comment problems (plan limits, missing permissions, server errors) only emit
  warnings — prperf never blocks your CI.
- A link to the uploaded profile is written to the job's step summary.
- **PRs from forks cannot upload**: GitHub does not grant `id-token: write`
  to fork-triggered workflows, so no OIDC token exists there (and the workflow
  token is read-only). Same-repo branch PRs work normally.
