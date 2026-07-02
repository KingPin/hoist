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
- `--dry-run` reports which containers are *eligible* to update/notify without pulling, recreating, or notifying — fully read-only (implies `--verbose`)
- `--verbose` logs containers skipped for missing hoist labels
- `--parallel N` uses a bash worker pool (`process_container "$c" &` + `wait -n`) to process containers concurrently
- `--list` / `--status` prints a table of running containers + their hoist labels and cached digest, then exits before any pulls
- `--update` triggers interactive self-update from the latest GitHub release; `--force` skips the prompt; `--force-update-check` ignores the 6h self-update-check cache for one run; `--version` prints `HOIST_VERSION` and exits
- `--cron <action>` manages a scheduled run; actions are `install | remove | print | status`. Bare `--cron` opens an interactive menu. Non-interactive runs of `install` need `--schedule <preset|expr>` and, for system scope, `--user <name>` (and `--backend cron|systemd` if both are present). Non-root users are also asked `--scope user|system`; root always defaults to system scope. `--docker-host <uri>` is an optional override for user-scope installs that pins `DOCKER_HOST` into the generated unit (use when the calling shell doesn't have `DOCKER_HOST` set, or to override auto-detect).

## Architecture

The script processes all running Docker containers in a single pass. After taking an exclusive run lock (`_acquire_run_lock`, see below), it discovers containers via `docker ps`, then runs each through `process_container`.

`process_container` (`hoist.sh:2495`) is a slim orchestrator: it declares the per-container locals and calls six single-responsibility helpers that populate/read those locals through bash's dynamic scope (the same mechanism the `&`-spawned parallel worker pool relies on), so ~40 metadata/status values aren't threaded through argument lists:

1. **`_get_container_metadata`** (`hoist.sh:2102`) — one `docker inspect` per container, all fields extracted via `jq` (NUL-delimited) in one pass; validates script paths. Appends `update_failed` + returns 1 on inspect/parse failure.
2. **`_registry_login`** (authfile-based `docker login`; side-effect only)
3. **`_pull_and_compare_digest`** (`hoist.sh:2252`) — in `--dry-run` this is fully read-only (NO pull): it sets `would_update`/`would_notify` and returns. Live: `docker compose pull` via `compose_pull_wrapper`, then `docker image inspect` for the new digest. Appends `update_failed` + writes the group `.failed` flag on pull failure.
4. **`_evaluate_policies`** (`hoist.sh:2311`) — constraint pin + group-abort gates (tokens `constraint_blocked`, `group_aborted`)
5. **`_apply_update`** (`hoist.sh:2346`) — acts only if the pulled digest differs and no policy blocked: `script.update`, `compose_up_wrapper`, healthcheck wait, rollback on failure
6. **`_dispatch_notifications`** (`hoist.sh:2421`) — dedup-digest check, `script.notify`, per-channel sends, rollup, persist `.notified`

`process_container` owns the result-file writes and the early returns (dedup, pause).

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
| `com.sumguy.hoist[.TAG].pause_until` | ISO date/datetime; skip container until current time ≥ value (token: `paused`). Unparseable = fail-open with warning |
| `com.sumguy.hoist[.TAG].constraint` | Semver pin (`^`, `~`, `>=`, `<=`, `>`, `<`, `=`, exact) checked against new image's `org.opencontainers.image.version`. Violation = skip update + notify (token: `constraint_blocked`). Missing version label = fail-open. **Caret on 0.x.y differs from npm**: hoist's `^0.1.2` allows any `0.x` ≥ `0.1.2`; npm's restricts to `0.1.z`. Use `~0.1.2` (or `>=0.1.2,<0.2`) for npm-style behavior |
| `com.sumguy.hoist[.TAG].group` | Free-form group name. Any member's pull failure writes `${CACHE_LOCATION}/hoist-group-<group>.failed` and aborts updates for the rest (token: `group_aborted`). Soft atomicity under `--parallel`: a sibling may finish before its peer fails |
| `com.sumguy.hoist[.TAG].healthcheck.wait` | `true` to poll `docker inspect .State.Health.Status` after `compose up`. On `unhealthy`/`exited`/timeout: emits `unhealthy` token and triggers rollback if enabled. **Caveat:** if the image defines no `HEALTHCHECK`, this falls back to `.State.Status` — only `running` vs `exited` are observable, not real health. A warning is logged in that case |
| `com.sumguy.hoist[.TAG].healthcheck.timeout` | Per-container override of `HEALTHCHECK_TIMEOUT` (seconds). Polls every `HEALTHCHECK_INTERVAL` seconds (default 2) |
| `com.sumguy.hoist[.TAG].rollback` | `true` re-aliases the prior image SHA back onto the original tag and re-runs `compose up --pull never` on update failure or unhealthy. Old SHA must still be present locally — `PRUNE_IMAGES=true` may remove it (token: `rollback_failed`). Tokens: `rolled_back`, `rollback_failed`. Default from config `ROLLBACK_DEFAULT` (default `false`) |

A container can have both `update` and `notify` set — it will update AND send notifications.

### Notification deduplication

Notification state is persisted in `${CACHE_LOCATION}/hoist-<safe-name>.notified` — a file containing the last-notified image digest. This prevents re-notifying for the same image version on repeated runs. `<safe-name>` is the container name with non-`[:alnum:]._-` characters replaced by `_`.

### Run summary

Each `process_container` invocation appends outcome tokens (`updated`, `update_failed`, `notified`, `no_change`, `skipped`, `not_compose_managed`, `would_update`, `would_notify`, `paused`, `constraint_blocked`, `group_aborted`, `unhealthy`, `rolled_back`, `rollback_failed`) to `${CACHE_LOCATION}/hoist-<safe-name>.run-result`. After all containers finish, `print_summary` aggregates them into a single one-line summary. Result files (and `hoist-group-*.failed` flags) are wiped at the start of each run. The end-of-run Healthchecks.io ping is `/fail` if any container produced `update_failed`, `unhealthy`, or `rollback_failed`; otherwise success. **`not_compose_managed`** flags a container with hoist `update`/`notify` labels but no `com.docker.compose.*` metadata — it's logged unconditionally and can't be acted on.

When `SUMMARY_LIST_NAMES` is true (default), the summary also names which containers landed in the `updated`/`update_failed` buckets, e.g. `4 updated [web, api, db, cache] (1 failed: worker)`, instead of just counts — the other buckets stay counts-only to avoid bloating the line on routine runs. `process_container` writes each container's raw name once, up front, to a sibling `${CACHE_LOCATION}/hoist-<safe-name>.name` file (wiped alongside `.run-result`/`.rollup` at run start); `print_summary` joins it back in only for containers whose `.run-result` contained `updated` or `update_failed`. Set `SUMMARY_LIST_NAMES=false` to keep the old count-only text (e.g. for scripts that parse the summary line verbatim).

### Run lock and exit code

`_acquire_run_lock` (`hoist.sh:417`) takes an exclusive `flock` on `${CACHE_LOCATION}/hoist.lock` at startup (with an `mkdir`-plus-stale-PID fallback when `flock` is absent). A second run that finds the lock held logs and exits 0 rather than racing over shared state; `--list`/`--status` skips the lock. **flock fd handoff:** bash sets no close-on-exec on the `{_LOCK_FD}` redirection fd, so docker/compose children and `&`-spawned workers would otherwise inherit it and keep the lock held — a Ctrl+C that orphans a `docker compose pull` subprocess would wedge every later run with "Another hoist run holds the lock". So after acquiring, hoist hands the held fd to a single childless holder process (`( exec sleep … ) &`, `disown`ed so the parallel pool's `wait`/`wait -n` ignore it), closes its own copy of the fd, and arms an EXIT trap (also reached via `_on_signal`'s `exit`) that kills the holder — releasing the lock the instant hoist truly exits, regardless of orphaned docker children. After `print_summary`, hoist **exits non-zero** if any container produced `update_failed`, `unhealthy`, or `rollback_failed` (drives `Type=oneshot` systemd, cron `MAILTO`, CI). Boolean gates (`update`/`notify`/`rollback`/`healthcheck.wait`, `ROLLBACK_DEFAULT`) are routed through `_is_true`, which accepts `true|1|yes|on` case-insensitively.

### Self-update

On every run (unless `UPDATE_CHECK=off`), `_self_update_check` queries the GitHub releases API for `KingPin/hoist`. Three modes:

- `notify` (default): logs availability + fires global webhooks (Discord/Slack/generic) once per new version. A sentinel file `${CACHE_LOCATION}/hoist-self-v<version>.notified` suppresses repeats.
- `update`: silently downloads, SHA256-verifies against `hoist.sh.sha256`, and atomically replaces the script via `mv`. Webhooks still fire first.
- `off`: skip entirely.

`--update` invokes the same path interactively (prompts before replacing; `--force` skips the prompt; `--dry-run` shows what would happen without writing). HTTP errors are distinguished: `000` = network failure, `404` = no releases yet, other non-200 = API error.

The non-interactive check is cached in `${CACHE_LOCATION}/hoist-self-update-check.cache` (epoch + version) for `UPDATE_CHECK_CACHE_TTL` seconds (default 6h) so cron/timer-fired runs don't hit the API every time. The cache survives the run-start state wipe (its name doesn't match the `.run-result`/`.rollup`/`.failed` globs). `--force-update-check` bypasses it for one run; interactive `--update` always checks live.

### Release process

`HOIST_VERSION` (`hoist.sh:2`) is the source of truth. Cutting a release: bump `HOIST_VERSION`, merge to `master`, then `git tag -a vX.Y.Z <merge-commit> && git push origin vX.Y.Z`. The `release.yml` workflow (triggered on `v*` tags) checks out the tag, generates `hoist.sh.sha256` + `hoist.conf.example.sha256`, and creates the GitHub release with all four files attached and auto-generated notes. **Do not run `gh release create` manually** — the workflow does it on tag push and a manual call will 422. Use `gh release edit` to refine the auto-generated body.

### List mode

`--list`/`--status` short-circuits after container discovery: it calls `list_containers` (a parallel jq parse + cached-digest lookup) and exits before `setup_environment`, the maintenance-window check, or any pulls.

### Environment variable injection for custom scripts

When `script.update` or `script.notify` runs, these `HOIST_*` env vars are set:

`HOIST_CONTAINER`, `HOIST_IMAGE`, `HOIST_OLD_IMAGE_ID`, `HOIST_NEW_IMAGE_ID`, `HOIST_OLD_VERSION`, `HOIST_NEW_VERSION`, `HOIST_OLD_REVISION`, `HOIST_NEW_REVISION`, `HOIST_COMPOSE_SERVICE`, `HOIST_COMPOSE_WORKDIR`

### Cron subcommand

`--cron <action>` manages hoist's own scheduled run. Actions: `install`, `remove`, `print` (dry-print the unit/crontab to stdout), `status`. Bare `--cron` opens an interactive menu.

Two backends, auto-detected by `_detect_scheduler` (`hoist.sh:999`):

Two scopes, chosen via `--scope user|system` (non-root users are prompted; root always gets system):

- **system scope** — installs to system-wide paths, may require sudo:
  - **cron** backend: writes `/etc/cron.d/hoist` (single file, managed marker on line 1).
  - **systemd** backend: writes `/etc/systemd/system/hoist.service` + `hoist.timer`, then `daemon-reload` + `enable --now hoist.timer`.
  - On hosts with only one backend, it is chosen automatically. On hosts with both, non-interactive runs require `--backend`.
- **user scope** — systemd only, no sudo needed:
  - Writes `~/.config/systemd/user/hoist.service` + `hoist.timer` (respects `$XDG_CONFIG_HOME`).
  - No `User=` directive (user units run as the owning user). No docker dependency in `[Unit]` (user units cannot depend on system units). Timer uses `WantedBy=default.target`.
  - Enabled with `systemctl --user enable --now hoist.timer`.
  - After install, hoist suggests `loginctl enable-linger $USER` if linger is not already set (needed for the timer to survive without an active login session).
  - **Rootless docker auto-pin**: at install time, `_detect_user_docker_host` (`hoist.sh:1316`) checks two things — whether `DOCKER_HOST` is set in the caller's env and is *not* already exported into `systemctl --user show-environment`. If both hold, the install bakes `Environment=DOCKER_HOST=<value>` into `hoist.service` so the timer-fired run matches the user's interactive shell. (It no longer probes `docker context show`.) Context-based rootless setups need nothing — they already work via `~/.docker/config.json`.
  - **Explicit `--docker-host <uri>`** wins over auto-detect. Use when `DOCKER_HOST` isn't set in the calling shell (non-interactive automation, Ansible) or when auto-detect would pick the wrong socket. Only valid with `--scope user`; passing it with system scope errors out. Source is logged as `--docker-host flag` vs `rootless docker detected` so install logs make the origin obvious.
  - If systemd is not available and `--scope user` is requested, hoist prints cron setup instructions and optionally generates the `/etc/cron.d/hoist` file for the user to place manually.

Non-interactive contract: `install` needs `--schedule` (preset `30min|hourly|6hourly|daily|weekly` or a raw cron / `OnCalendar` expression). System scope also requires `--user`. Non-root callers additionally need `--scope`. If any required value is missing and stdin isn't a TTY, hoist prints a clear error and exits — it never hangs waiting for input.

Idempotency is marker-based: every managed file gets `# Managed by hoist --cron install` on line 1 (`_CRON_MARKER`). `install` refuses to overwrite a file that doesn't carry the marker; `remove` refuses to delete one that doesn't. Re-running `install` is safe — it always rewrites the unit/cron file (and emits `Installed …`), so config-management tools should expect "changed" on every run rather than try to fake idempotence on top.

Privilege handling lives in `_sudo_if_needed`: walks up to the nearest existing ancestor of the target path and only escalates to `sudo` when that path isn't writable. User-scope installs write to `~HOME` and never call `_sudo_if_needed`. Plays cleanly with Ansible `become` and the standalone `install.sh`.

`systemd-analyze` is **only** required when validating a custom `OnCalendar` expression on the systemd backend (`hoist.sh:1072-1077`). Presets short-circuit validation. macOS targets aren't supported — `_launchd_doc` (`hoist.sh:1432`) prints a pointer to `docs/scheduling.md` and returns 2.

A worked Ansible playbook that drives `--cron install` through this contract lives in `examples/ansible/`.

### Parallel mode

`--parallel N` uses a bash worker pool (`process_container "$c" &` + `wait -n`) inside the same shell process. Forked subshells inherit functions and variables natively, so no `export -f` is needed — new helpers Just Work. Bash 4.3+ is required for `wait -n`. Per-container state goes through cache files (`.notified`, `.run-result`, `.rollup`) since variables modified in a `&` subshell don't propagate back to the parent.

When `PARALLEL > 1`, `compose_pull_wrapper` (`hoist.sh:393`) passes `--quiet` to `docker compose pull` so sibling containers' progress bars don't interleave into unreadable output. Hoist's own per-container `Checking...` / `Pulling image...` log lines still print, so the run never looks hung. Serial runs (`PARALLEL=1`, the default) keep Docker's verbose progress output.

### Notification channels and rollup

Per-container labels: discord, slack, generic, telegram, gotify, ntfy, teams, matrix. Each channel also has a `GLOBAL_*` fallback in config. When `WEBHOOK_ROLLUP=true`, channels listed in `WEBHOOK_ROLLUP_CHANNELS` get one summary message at end of run (using the `GLOBAL_*` URL) instead of per-container sends — per-container labels for those channels are ignored.

`HEALTHCHECKS_PING_URL` triggers a `/start` ping at run start, the bare URL on success at run end, or `/fail` if any container's update failed. Best-effort.
