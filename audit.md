# Codebase Audit — 2026-06-11

**Scope:** hoist.sh (2274 lines), install.sh, .github/workflows/release.yml, hoist.conf.example, examples/ansible/. All three pillars: security (OWASP), correctness (concurrency/races/logic), performance/maintainability.
**Method:** Five parallel research subagents; every finding verified by reading the cited line. Coordinator spot-checked 6 findings (all confirmed).
**Status:** Findings only — no code changes in this pass.

## Executive Summary

- Critical: 0
- High: 6
- Medium: 11
- Low: 13
- Info: several (positive observations + doc drift)

The script is well-written overall — secrets use `--password-stdin`, webhooks avoid `-L` to prevent credential leakage on redirect, self-update verifies SHA256, jq webhook payloads use `--arg` (no JSON injection), and the parallel worker pool is correctly guarded for bash ≥ 4.3. The high-value findings are **correctness bugs**, not security holes: two features (maintenance window, rollback) are effectively broken, and several config/CLI paths silently make the wrong update/skip decision.

**Top 5 by ROI (severity × ease-of-fix):**

1. **Rollback never works** — `docker compose up --no-pull` is not a valid flag (`hoist.sh:406`). One-word fix.
2. **Maintenance window fails open** — octal arithmetic on zero-padded HHMM (`hoist.sh:218-231`). Updates fire outside the window for most of the day.
3. **`--tag` / `--parallel` with no value swallow the next flag** — `hoist --tag --dry-run` runs **live** (`hoist.sh:69,71`).
4. **Config `TAG=production` never matches labels** — CLI prepends `.` but config sourcing doesn't, so every container is skipped (`hoist.sh:68-69`). Affects the shipped Ansible example.
5. **Documented range constraint `>=0.1.2,<0.2` silently drops the upper bound** (`hoist.sh:289-298`).

---

## Correctness

### High

#### Rollback uses nonexistent `docker compose up --no-pull` — rollback always fails — `hoist.sh:406`
**What:** `( cd "$workdir" && docker compose up -d --no-pull "$service" ) >/dev/null 2>&1`. `--no-pull` is a `compose build` flag, not a `compose up` flag (`up` has `--pull <policy>`). Compose exits "unknown flag", swallowed by the redirect.
**Why it matters:** Every rollback emits `rollback_failed` — the feature has never worked. Worse, line 397 already re-tagged the old SHA onto the image name *before* this step, so a failed rollback leaves the tag pointing at the old image while the broken new container keeps running, and the next run's digest compare is confused. README.md:191 documents the broken flag verbatim.
**Fix:** Use `docker compose up -d --pull never "$service"` (or omit the pull flag — `up` won't pull an image already present). Stop discarding stderr in the rollback path so flag errors surface. Consider undoing the re-tag when `up` fails.

#### Maintenance window comparisons break on leading-zero times (bash octal) — `hoist.sh:218-231`
**What:** `start`/`end`/`current` are zero-padded `HHMM` strings compared with `[[ -le ]]`, which does arithmetic eval. Leading-zero values parse as octal; any value containing 8/9 after a leading zero is a hard error (`[[ "0900" -le "1700" ]]` → `value too great for base`, returns false). When a comparison errors, neither the `if` nor `else` branch exits, so execution falls through to "Within maintenance window, proceeding."
**Why it matters:** The exact example in `hoist.conf.example:32` (`02:00-06:00`) misbehaves for every run between 00:00–09:59. Containers get pulled/recreated *outside* the configured window — defeating the whole feature — with only a cryptic stderr line.
**Fix:** Force base-10 (`$((10#$start))`) or compare the fixed-width strings lexically with `<`/`>`. Validate `MAINTENANCE_WINDOW` format once at startup and fail loudly on garbage.

#### `--tag` / `--parallel` with a missing value swallow the next flag; unknown flags silently ignored — `hoist.sh:69,71,64-163`
**What:** `--tag) shift; [[ -n "$1" && "$1" != "--"* ]] && TAG=".$1"`. With no value, `shift` consumed the next token, the guard rejects it, and the loop's trailing `shift` discards it. `hoist --tag --dry-run` drops `--dry-run` and runs **live**. Same for `--parallel`. The `case` has no `*)` arm, so typos (`--dryrun`) are silently ignored.
**Why it matters:** A one-character slip turns an intended dry-run into real container recreations — the worst failure mode for this tool. (Newer flags like `--only` already use the safe `${2:-}` peek pattern; only these two legacy flags lag.)
**Fix:** Convert `--tag`/`--parallel` to the peek-then-shift pattern used by `--only` (error exit 2 on missing/invalid value), and add a `*)` arm that errors on unknown options.

#### Config-file `TAG=` lacks the leading dot the CLI adds — label lookups never match — `hoist.sh:68-69` vs `hoist.conf.example:22`
**What:** CLI parsing does `TAG=".$val"`, but config is sourced raw. `hoist.conf.example:22` documents `# TAG=production` and the shipped `examples/ansible/templates/hoist.conf.j2` renders `TAG="{{ hoist_tag }}"`. With `TAG=production`, jq looks up `com.sumguy.hoistproduction.update` — a label that cannot exist.
**Why it matters:** Anyone setting the tag via config (including via the documented Ansible workflow) gets every container skipped as "no hoist labels," fleet-wide, with no error.
**Fix:** After config load and after arg parsing, if `TAG` is non-empty and doesn't begin with `.`, prepend one. Keeps both `production` and `.production` working.

#### Semver: `v`-prefixed versions collapse to major 0 — wrong constraint verdicts — `hoist.sh:262-264,302-304`
**What:** `_semver_gt`/`_semver_eq` strip from the first non-digit (`av=${av%%[!0-9]*}`), so component `"v1"` → `""` → 0. Many images publish `org.opencontainers.image.version` as `v1.2.3`. `^1.0.0` vs candidate `v1.5.0` is wrongly blocked; `<2.0.0` vs `v3.0.0` is wrongly allowed (v3→0).
**Why it matters:** Wrong update/skip decisions on a common real-world version format.
**Fix:** Strip a leading `v`/`V` from both constraint base and candidate in `_semver_satisfies` before splitting; apply the same suffix-stripping in the caret/tilde major-component equality check instead of raw string compare.

#### Documented range form `>=0.1.2,<0.2` is silently misparsed — upper bound ignored — `hoist.sh:289-298` vs `README.md:179`
**What:** `_semver_satisfies` has no comma handling. `>=0.1.2,<0.2` matches the `">="*` case with `base="0.1.2,<0.2"`, which suffix-strips down to plain `>=0.1.2`. README.md:179 and CLAUDE.md explicitly recommend this form for npm-style 0.x pinning.
**Why it matters:** A user following the docs gets no upper bound — `0.9.0` satisfies "`>=0.1.2,<0.2`" and updates, exactly the bump the pin meant to block. Silent fail-open on the strictest constraint.
**Fix:** Implement comma-conjunction (split on `,`, require all parts), or remove the range form from the docs and have `_semver_satisfies` warn + treat comma-bearing constraints as unparseable.

### Medium

#### Self-update `mv` is non-atomic / overwrites inode across filesystems — `hoist.sh:514,569`
**What:** Temp file is `mktemp /tmp/hoist-update-XXXXXX`; `/tmp` is usually tmpfs while the script is on the root fs. Cross-fs `mv` falls back to copy-into-existing-inode (verified) rather than an atomic `rename()`. With `UPDATE_CHECK=update` the replacement runs (line ~2193) *before* the rest of the script executes.
**Why it matters:** Bash reads scripts incrementally from the open fd; rewriting the inode mid-run can execute shifted bytes (read-ahead may mask it — luck, not guarantee), and a concurrent cron run can exec a half-copied file. (`install.sh` is safe — GNU `install` creates a new inode.)
**Fix:** `mktemp` in `$(dirname "$script_path")` so the final `mv` is always a same-fs atomic rename.

#### `docker image inspect` result unchecked — empty digest fabricates an "update" — `hoist.sh:1886-1903`
**What:** `image_inspect=$(docker image inspect "$image_name")` has no `||` guard (unlike the container inspect at 1719). On failure docker prints `[]`; jq's `.[0] | .Id` then yields `null`→empty and exits 0, so the guard at 1893 doesn't fire. `image_digest=""` ≠ running digest → spurious recreate + notification with empty new-image ID, and an empty `.notified` cache that guarantees a duplicate notification next run.
**Fix:** Guard the inspect exit status like the container inspect (token `update_failed`, return 1), and treat an empty `image_digest` as a hard error before the digest compare.

#### No run lock — overlapping runs corrupt each other's state — `hoist.sh:2236-2237`
**What:** No lockfile anywhere. A second invocation immediately `rm -f`s all `*.run-result`, `*.rollup`, and `hoist-group-*.failed` files while run A's workers are still appending. Run A loses tokens (summary undercounts; `/fail` HC decision can wrongly report success), loses group-abort flags mid-run, and both runs do concurrent `compose pull`/`up` on the same projects; run B's prune can delete the image run A needs for rollback.
**Fix:** Take an exclusive `flock -n` on `${CACHE_LOCATION}/hoist.lock` at startup; exit or wait if held. `--list` doesn't need it.

#### `docker ps` failure is treated as a successful zero-container run — `hoist.sh:2198,2261-2274`
**What:** `readarray -t containers < <(docker ps ... | sort)` ignores docker failure (the pipe masks it; no `pipefail`). Daemon down → empty list → "Processing 0 containers," clean summary, success HC ping.
**Why it matters:** Monitoring sees a healthy run when nothing was checked — the exact outage you'd want flagged. Startup only checks the binary exists, not daemon reachability.
**Fix:** Capture `docker ps` exit status (avoid the pipe or check `PIPESTATUS`); on failure log, ping `/fail`, exit non-zero.

#### Script exits 0 even when updates failed / unhealthy / rollback failed — `hoist.sh:2270-2274`
**What:** The last statement is the HC ping (ends in `|| true`); nothing maps failures to an exit code. `process_container` return values are ignored in both loops.
**Why it matters:** cron `MAILTO`, the `Type=oneshot` systemd unit, Ansible, and CI all key off exit status. A run where every update failed reports success everywhere except the optional HC ping.
**Fix:** After `print_summary`, reuse the existing failure-token grep (line 2270) to `exit 1` when any `update_failed`/`unhealthy`/`rollback_failed` token exists.

#### `compose_pull_wrapper`/`compose_up_wrapper` `cd` leaks into the main shell — `hoist.sh:237,243`
**What:** Both `cd "$1"` without a subshell. With `--parallel 1` (default), `process_container` runs in the main process, so cwd permanently moves to the last compose workdir (rollback at 406 correctly subshells; these don't).
**Why it matters:** Relative `LOG_FILE`/`CACHE_LOCATION` scatter across compose project dirs mid-run, breaking dedup/summary/notified lookups. Behavior differs between parallel and sequential modes.
**Fix:** `( cd "$1" && docker compose ... )` like the rollback path, or use `docker compose --project-directory "$1"` and drop the `cd`.

#### Multi-line label values shift the entire `readarray` field mapping — `hoist.sh:1739-1808`
**What:** 30 jq outputs are split by newline into `_vals`. A label value containing `\n` (legal in Docker labels; plausible in `script.*` or pasted URLs) shifts every subsequent field by one.
**Why it matters:** Misattributed fields produce wrong webhooks/flags; a stray `true` landing in the `rollback`/`healthcheck.wait` slot silently flips behavior. Fail-open pause/constraint paths hide it.
**Fix:** Emit NUL-delimited jq output and `readarray -d ''`, or emit one JSON object and pull fields individually.

#### Compose project-level race in parallel mode — `hoist.sh:235-245,1836-1844`
**What:** The `mkdir` dedup is keyed `workdir:service`, collapsing only replicas of one service. Two *different* services from the same project run as concurrent workers, each doing `compose up --always-recreate-deps` in the same project dir.
**Why it matters:** `--always-recreate-deps` recreates dependencies; concurrent `up`s with overlapping graphs hit "name already in use" or tear down each other's freshly-updated containers — flaky `update_failed` + rollbacks dependent on scheduling.
**Fix:** Serialize per compose project (per-project `flock`), or group by `working_dir` so one worker owns a project. Alternatively make `--always-recreate-deps` configurable.

#### Boolean labels accept only lowercase literal `true` — `hoist.sh:1835,1934,1957,2155`
**What:** All gates are `[[ $x == true ]]`. YAML `"True"`, `"TRUE"`, `"1"`, `"yes"` are treated as false and the container is silently skipped (logged as "no hoist labels"). Same for `ROLLBACK_DEFAULT`/`healthcheck.wait`.
**Fix:** Add an `_is_true()` helper (lowercase + accept `true|1|yes`), or warn when an update/notify label is present but its value isn't a recognized boolean.

#### Labeled but non-compose containers reported as "no hoist labels" — `hoist.sh:1835,2068`
**What:** The action block is gated on compose metadata; a `docker run` container with `com.sumguy.hoist.update=true` hits the `else` branch whose only (verbose-only) output is "Skipped (no hoist labels)".
**Why it matters:** The user opted in; hoist ignores it forever while asserting the labels don't exist, and the README troubleshooting table sends them the wrong way.
**Fix:** When hoist labels are present but compose metadata is missing, log an unconditional warning ("has hoist labels but is not compose-managed") and emit a distinct token.

#### Dry-run summary counts every labeled container as "would update/notify" — `hoist.sh:1867-1871`
**What:** Dry-run appends `would_update`/`would_notify` unconditionally, before any digest knowledge, and skips the constraint check. 30 up-to-date containers report "30 would update."
**Fix:** Make dry-run run the read-only policy evaluation it can (pause/constraint against current version) and report realistically, or rename the tokens to "would be checked."

### Low

- **Sanitization collisions** in compose dedup keys / group flag names — `tr -cs` squeezing maps distinct inputs to the same filename; second container silently skipped; unrelated groups merged (`hoist.sh:1837-1840,1878`). Hash the raw key instead.
- **Concurrent `docker login`** from parallel workers can clobber `~/.docker/config.json`; login exit status unchecked; `jq -r .password` on a bad authfile yields literal `null` (`hoist.sh:1856-1862`). Validate authfile fields up front; serialize or pre-login in the parent.
- **`^`/`~` pre-release equality admits rc builds** — `_semver_eq` strips suffixes so `2.0.0-rc1 == 2.0.0`, satisfying `>=2.0.0` (`hoist.sh:271-281`).
- **`_validate_cron_expr` is field-count-only** — rejects valid `@daily`, accepts garbage `a b c d e` that silently never runs; weak to embedded newlines (`hoist.sh:763-768`).
- **Out-of-window runs send no HC ping at all** — false "down" alerts when pairing `MAINTENANCE_WINDOW` with `HEALTHCHECKS_PING_URL` (`hoist.sh:2239`).
- **`--cron print` ignores `--scope user`** — always renders the system unit, misleading the "generate and place yourself" workflow (`hoist.sh:1384-1416`).
- **Rollup channel list breaks on spaces after commas** — `WEBHOOK_ROLLUP_CHANNELS="discord, slack"` half-disables the feature (`hoist.sh:1624,1663`).
- **`--update --force` exits "Already up to date"** — contradicts help/README, which say force reinstalls (`hoist.sh:630-631` vs `131`).
- **DOCKER_HOST pin skipped when a non-default context coexists with DOCKER_HOST** — wrong call exactly where divergence is possible (`hoist.sh:1019-1022`).
- **SIGTERM leaves compose children running; exit hardcoded 130** — trap kills only `jobs -p`, not the process group (`hoist.sh:180`).
- **`install.sh` INT trap cleans up but doesn't exit** — continues and reports a misleading "network failure" after Ctrl-C (`install.sh:74`).
- **`jq`/`docker stop`/`script.*` exit codes unchecked at startup/runtime** — a failing pre-update hook doesn't block the update (undocumented); missing jq surfaces as N per-container errors instead of one clear message (`hoist.sh:183,1941,1953`).
- **World-writable default `CACHE_LOCATION=/tmp`** with predictable filenames — local user can pre-create `hoist-group-<g>.failed` to veto updates or plant a symlink (`hoist.sh:6`).

---

## Security (OWASP)

No Critical or High findings. The security agents initially rated the cron/systemd "injection" paths High, but the input (`--schedule`, `--user`, `OnCalendar`) is supplied by the operator running `--cron install`, who already holds the privilege to write any unit — it crosses no trust boundary. Downgraded to Low validation gaps.

### Low

- **Cron/systemd unit generation lacks newline/quoting validation** — `--schedule`/`OnCalendar`/`--user` interpolated unquoted; a newline could inject extra directives (`hoist.sh:807,893,906`). Operator-controlled, so robustness not escalation. Reject newlines in `_validate_cron_expr`/`_validate_user` and quote the heredoc values.
- **Registry authfile read without permission check** — only existence/absoluteness checked, not `0600` (`hoist.sh:1851-1861`). Warn or refuse on group/world-readable authfiles.
- **Cron/systemd unit files installed `0644`** (world-readable) — units carry the binary path and pinned `DOCKER_HOST`, not secrets, so impact is low (`hoist.sh:836,942`). `0640` is sufficient and still satisfies cron.d's not-group-writable rule.
- **Self-update temp file mode not explicitly set** — relies on stat of the running script; defaults to `0755` if stat fails, briefly exposing unverified content (`hoist.sh:514-571`). `chmod 0600` after `mktemp`.
- **`_sudo_if_needed` TOCTOU** — walks ancestors with `-e` then `-w`; a symlink swap between checks could mis-target (`hoist.sh:694-707`). Low (needs local write + timing). Reject symlinks or `realpath -e`.
- **Cache dedup `mkdir` race in /tmp** — local user can pre-create the dir to skip a service (DoS) (`hoist.sh:1840`). Move cache to a `0700` protected dir.
- **curl lacks `--proto =https`** on self-update and webhooks — defense-in-depth against downgrade (HTTPS URLs already fail on downgrade) (`hoist.sh:527-537`).

### Info (by design / positive)

- Config file is sourced → arbitrary code by design; document that `HOIST_CONFIG` must not point at an attacker-writable path (`hoist.sh:60`).
- `docker login --password-stdin` (no argv exposure); webhooks deliberately omit `-L` to avoid credential leak on redirect; jq `--arg` webhook payloads (no JSON injection); SHA256 verified before self-replace; release.yml doesn't interpolate tag names into `run:` blocks. All verified clean.
- Self-update checksum and payload share one origin (GitHub) — SHA256 protects against corruption/MITM, not a compromised release; GPG signing would close that gap (out of scope).

---

## Performance / Maintainability

### High

- **Monolithic `process_container` (367 lines, `hoist.sh:1710-2076`)** — inspection, pull, digest, healthcheck, policy, login, compose, and all 8 notification channels in one function. Extract `_get_container_metadata`, `_pull_and_compare`, `_evaluate_policies`, `_send_notifications`, `_apply_update` — also unblocks a bats harness.
- **8× notification dispatch boilerplate (`hoist.sh:2023-2074`)** and **8× near-identical send functions (`hoist.sh:1471-1607`, ~107 lines)** — replace per-channel guards with an associative-array dispatch table, and extract a `_send_webhook <endpoint> <payload> <content_type>` helper handling curl/timeout/error-logging once. Cuts ~150 lines and makes new channels trivial.
- **No cross-container image-pull dedup (`hoist.sh:1837-1844`)** — dedup is per `workdir:service`; many containers sharing one image still pull it repeatedly. Pre-compute the unique-image set and pull once before the loop.

### Medium

- **Self-update hits GitHub API every run (`hoist.sh:574-677`)** — 60 req/hr unauthenticated limit caps fleet size on tight cron; adds curl latency to every invocation. Cache last-check timestamp + result, skip within ~6h, add `--force-update-check`.
- **Two docker inspects + two jq passes per container (`hoist.sh:1719,1887`)** — consolidate; cache the image inspect within a run.
- **`HEALTHCHECK_INTERVAL` is read from config but `_wait_for_healthy` hardcodes `sleep 2` (`hoist.sh:346-381`)** — wire the variable in (latent config bug), or remove it from the example.

### Low

- `tr` subshells for filename sanitization in hot loops — replace with bash parameter expansion `${var//[^[:alnum:]._-]/_}` (already requires bash 4.3+) (`hoist.sh:1713,1839,1878`).
- Long `_cron_install_orchestrate` (118 lines) and `_self_update_check` (104 lines) — split into per-backend / testable helpers.

---

## Areas explicitly checked and clean

- `.run-result` / `.rollup` append atomicity (per-container files, single `printf >>`, aggregation only after `wait`).
- Container `safe_name` collisions (Docker name charset ⊂ tr keep-set; only free-form group names / dedup keys collide).
- `wait -n` worker pool, bash ≥ 4.3 guard, running-count accounting.
- Healthcheck poll loop arithmetic and mid-poll container removal (fail-safe).
- Notification dedup `.notified` semantics; rollup mode; HC.io fail-token grep (anchored, correct).
- `_parse_to_epoch` portability chain (GNU → gdate → BSD); `pause_until` fail-open as documented.
- Caret-on-0.x intentional npm divergence; self-update version compare is semantic + upgrade-only with `v`-prefix stripped on the release tag.
- Tag-mode label reads (no untagged fallback, consistent across `process_container` and `list_containers`).
- Marker idempotency + remove symmetry across all three backends; `--docker-host` scope enforcement; cron non-interactive contract vs the Ansible playbook.
- install.sh: `set -euo pipefail`, checksum-before-install, 404 handling for optional assets, TTY gating; replacing a running hoist is safe (GNU `install` new inode).
- No dead code; all declared functions invoked; all documented config variables are referenced (except the `HEALTHCHECK_INTERVAL` wiring gap noted above).

## Methodology

Five subagents ran concurrently: two security (injection/quoting; secrets/integrity/privilege), two correctness (concurrency/races; business-logic — the latter empirically verified bash octal behavior, compose flag support, and semver function outputs), one performance/maintainability. shellcheck was not installed on the host, so correctness findings are from manual reading. The coordinator spot-checked 6 findings against the source (maintenance window, rollback flag, `--tag`/`--parallel` parsing, config `TAG` dot, unchecked image inspect, cron validation) — all confirmed; 0 required correction. Cron/systemd "injection" findings were downgraded from High to Low after threat-model review (operator-supplied input, no privilege boundary crossed).
