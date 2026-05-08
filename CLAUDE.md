# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**Hoist** is a single-file Bash script (`hoist.sh`) that auto-updates or notifies about Docker containers managed by Docker Compose. It reads Docker container labels to decide what to do with each running container.

There is no build system, no test suite, and no linter configuration. Requires `docker` (with `compose` subcommand) and `jq`.

## Config File

`hoist.conf.example` documents all available settings. At startup, `hoist.sh` sources the first config found at: `$HOIST_CONFIG` → `./hoist.conf` → `/etc/hoist/hoist.conf`. CLI flags override config values. Config is sourced before arg parsing so the load order is: defaults → config → CLI.

## Running

```bash
bash hoist.sh [--tag <tag>] [--dry-run] [--parallel <N>] [--list] [--update]
```

- `--tag` filters which label set to act on (e.g. `--tag nightly` reads `com.sumguy.hoist.nightly.*` labels)
- `--dry-run` shows what would be pulled/updated without making any changes or sending notifications (implies `--verbose`)
- `--verbose` logs containers skipped for missing hoist labels
- `--parallel N` uses `xargs -P N` to process containers concurrently
- `--list` / `--status` prints a table of running containers + their hoist labels and cached digest, then exits before any pulls
- `--update` triggers interactive self-update from the latest GitHub release; `--force` skips the prompt; `--version` prints `HOIST_VERSION` and exits

## Architecture

The script processes all running Docker containers in a single pass:

1. **Maintenance window check** — if `MAINTENANCE_WINDOW` is set in config and the current time is outside the window, exits cleanly (0) before doing anything; `--dry-run` bypasses this
2. **Container discovery** — `docker ps` lists all running containers
3. **Label inspection** — one `docker inspect` call per container, all fields extracted via `jq` in one pass
4. **Image pull** — `docker compose pull` via `compose_pull_wrapper`
5. **Update/notify decision** — compares the pulled image digest against the running container's digest; acts only if they differ
6. **Action** — either `compose_up_wrapper` (recreate container) or webhook/script notification

### Label namespace

All behavior is controlled by Docker labels on containers:

| Label | Effect |
|---|---|
| `com.sumguy.hoist[.TAG].update` | `true` = pull and recreate container |
| `com.sumguy.hoist[.TAG].notify` | `true` = send notification only, no recreate |
| `com.sumguy.hoist[.TAG].discord.webhook` | Discord embed webhook URL |
| `com.sumguy.hoist[.TAG].generic.webhook` | Generic JSON webhook URL |
| `com.sumguy.hoist[.TAG].slack.webhook` | Slack incoming webhook URL |
| `com.sumguy.hoist[.TAG].script.update` | Shell command run before container recreate |
| `com.sumguy.hoist[.TAG].script.notify` | Shell command run before webhook notification |
| `com.sumguy.hoist[.TAG].registry.authfile` | JSON file with `username`, `password`, `registry` |

A container can have both `update` and `notify` set — it will update AND send notifications.

### Notification deduplication

Notification state is persisted in `${CACHE_LOCATION}/hoist-<safe-name>.notified` — a file containing the last-notified image digest. This prevents re-notifying for the same image version on repeated runs. `<safe-name>` is the container name with non-`[:alnum:]._-` characters replaced by `_`.

### Run summary

Each `process_container` invocation appends outcome tokens (`updated`, `update_failed`, `notified`, `no_change`, `skipped`, `would_update`, `would_notify`) to `${CACHE_LOCATION}/hoist-<safe-name>.run-result`. After all containers finish, `print_summary` aggregates them into a single one-line summary. Result files are wiped at the start of each run.

### Self-update

On every run (unless `UPDATE_CHECK=off`), `_self_update_check` queries the GitHub releases API for `KingPin/hoist`. Three modes:

- `notify` (default): logs availability + fires global webhooks (Discord/Slack/generic) once per new version. A sentinel file `${CACHE_LOCATION}/hoist-self-v<version>.notified` suppresses repeats.
- `update`: silently downloads, SHA256-verifies against `hoist.sh.sha256`, and atomically replaces the script via `mv`. Webhooks still fire first.
- `off`: skip entirely.

`--update` invokes the same path interactively (prompts before replacing; `--force` skips the prompt; `--dry-run` shows what would happen without writing). HTTP errors are distinguished: `000` = network failure, `404` = no releases yet, other non-200 = API error.

### List mode

`--list`/`--status` short-circuits after container discovery: it calls `list_containers` (a parallel jq parse + cached-digest lookup) and exits before `setup_environment`, the maintenance-window check, or any pulls.

### Environment variable injection for custom scripts

When `script.update` or `script.notify` runs, these `HOIST_*` env vars are set:

`HOIST_CONTAINER`, `HOIST_IMAGE`, `HOIST_OLD_IMAGE_ID`, `HOIST_NEW_IMAGE_ID`, `HOIST_OLD_VERSION`, `HOIST_NEW_VERSION`, `HOIST_OLD_REVISION`, `HOIST_NEW_REVISION`, `HOIST_COMPOSE_SERVICE`, `HOIST_COMPOSE_WORKDIR`

### Parallel mode caveat

When `--parallel N` (N > 1) is used, functions and variables are exported via `export -f` so subshells spawned by `xargs` can access them. The canonical export list lives in `setup_environment` (hoist.sh) — any new helper function called from `process_container` (or its callees) must be added there, or it will silently break in parallel mode while still working serially.
