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
- `--cron <action>` manages a scheduled run; actions are `install | remove | print | status`. Bare `--cron` opens an interactive menu. Non-interactive runs of `install` need `--schedule <preset|expr>` and `--user <name>` (and `--backend cron|systemd` if both are present on the host)

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
| `com.sumguy.hoist[.TAG].telegram.bot_token` / `.telegram.chat_id` | Telegram bot credentials |
| `com.sumguy.hoist[.TAG].gotify.url` | Gotify message URL (token in query string) |
| `com.sumguy.hoist[.TAG].ntfy.url` / `.ntfy.token` | ntfy.sh topic URL + optional bearer token |
| `com.sumguy.hoist[.TAG].teams.webhook` | Microsoft Teams incoming webhook |
| `com.sumguy.hoist[.TAG].matrix.homeserver` / `.matrix.room_id` / `.matrix.token` | Matrix room credentials |
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

### Cron subcommand

`--cron <action>` manages hoist's own scheduled run. Actions: `install`, `remove`, `print` (dry-print the unit/crontab to stdout), `status`. Bare `--cron` opens an interactive menu.

Two backends, auto-detected by `_detect_scheduler` (`hoist.sh:486-506`):

- **cron** — writes `/etc/cron.d/hoist` (a single file, with managed marker on line 1).
- **systemd** — writes `/etc/systemd/system/hoist.service` + `hoist.timer`, then `daemon-reload` + `enable --now hoist.timer`.

On hosts where only one is present, the backend is chosen for you. On hosts with both (`detected == both`), non-interactive runs require `--backend`.

Non-interactive contract (`hoist.sh:850-857`): `install` needs `--schedule` (preset `30min|hourly|6hourly|daily|weekly` or a raw cron / `OnCalendar` expression) and `--user`. If any required value is missing and stdin isn't a TTY, hoist prints a clear error and exits — it never hangs waiting for input.

Idempotency is marker-based: every managed file gets `# Managed by hoist --cron install` on line 1 (`_CRON_MARKER`, `hoist.sh:457`). `install` refuses to overwrite a file that doesn't carry the marker; `remove` refuses to delete one that doesn't. Re-running `install` is safe — it always rewrites the unit/cron file (and emits `Installed …`), so config-management tools should expect "changed" on every run rather than try to fake idempotence on top.

Privilege handling lives in `_sudo_if_needed` (`hoist.sh:461-475`): walks up to the nearest existing ancestor of the target path and only escalates to `sudo` when that path isn't writable. Plays cleanly with Ansible `become` and the standalone `install.sh`.

`systemd-analyze` is **only** required when validating a custom `OnCalendar` expression on the systemd backend (`hoist.sh:537-546`). Presets short-circuit validation. macOS targets aren't supported — `_launchd_doc` (`hoist.sh:755-764`) prints a pointer to `docs/scheduling.md` and returns 2.

A worked Ansible playbook that drives `--cron install` through this contract lives in `examples/ansible/`.

### Parallel mode

`--parallel N` uses a bash worker pool (`process_container "$c" &` + `wait -n`) inside the same shell process. Forked subshells inherit functions and variables natively, so no `export -f` is needed — new helpers Just Work. Bash 4.3+ is required for `wait -n`. Per-container state goes through cache files (`.notified`, `.run-result`, `.rollup`) since variables modified in a `&` subshell don't propagate back to the parent.

### Notification channels and rollup

Per-container labels: discord, slack, generic, telegram, gotify, ntfy, teams, matrix. Each channel also has a `GLOBAL_*` fallback in config. When `WEBHOOK_ROLLUP=true`, channels listed in `WEBHOOK_ROLLUP_CHANNELS` get one summary message at end of run (using the `GLOBAL_*` URL) instead of per-container sends — per-container labels for those channels are ignored.

`HEALTHCHECKS_PING_URL` triggers a `/start` ping at run start, the bare URL on success at run end, or `/fail` if any container's update failed. Best-effort.
