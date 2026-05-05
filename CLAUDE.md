# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**Hoist** is a single-file Bash script (`hoist.sh`) that auto-updates or notifies about Docker containers managed by Docker Compose. It reads Docker container labels to decide what to do with each running container.

There is no build system, no test suite, and no linter configuration. Requires `docker` (with `compose` subcommand) and `jq`.

## Config File

`hoist.conf.example` documents all available settings. At startup, `hoist.sh` sources the first config found at: `$HOIST_CONFIG` → `./hoist.conf` → `/etc/hoist/hoist.conf`. CLI flags override config values. Config is sourced before arg parsing so the load order is: defaults → config → CLI.

## Running

```bash
bash hoist.sh [--tag <tag>] [--dry-run] [--parallel <N>]
```

- `--tag` filters which label set to act on (e.g. `--tag nightly` reads `com.sumguy.hoist.nightly.*` labels)
- `--dry-run` shows what would be pulled/updated without making any changes or sending notifications
- `--parallel N` uses `xargs -P N` to process containers concurrently

## Architecture

The script processes all running Docker containers in a single pass:

1. **Container discovery** — `docker ps` lists all running containers
2. **Label inspection** — one `docker inspect` call per container, all fields extracted via `jq` in one pass
3. **Image pull** — `docker compose pull` via `compose_pull_wrapper`
4. **Update/notify decision** — compares the pulled image digest against the running container's digest; acts only if they differ
5. **Action** — either `compose_up_wrapper` (recreate container) or webhook/script notification

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

Notification state is persisted in `/tmp/hoist-<container-name>.notified` — a file containing the last-notified image digest. This prevents re-notifying for the same image version on repeated runs.

### Environment variable injection for custom scripts

When `script.update` or `script.notify` runs, these `HOIST_*` env vars are set:

`HOIST_CONTAINER`, `HOIST_IMAGE`, `HOIST_OLD_IMAGE_ID`, `HOIST_NEW_IMAGE_ID`, `HOIST_OLD_VERSION`, `HOIST_NEW_VERSION`, `HOIST_OLD_REVISION`, `HOIST_NEW_REVISION`, `HOIST_COMPOSE_SERVICE`, `HOIST_COMPOSE_WORKDIR`

### Parallel mode caveat

When `--parallel N` (N > 1) is used, functions and variables are exported via `export -f` so subshells spawned by `xargs` can access them. Any new helper functions added to the script must be added to the `export -f` list in `setup_environment` if they need to work in parallel mode.
