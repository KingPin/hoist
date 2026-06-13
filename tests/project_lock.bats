#!/usr/bin/env bats
# Per-project serialization. _with_project_lock must run the wrapped command,
# return its exit status, and grant mutual exclusion to concurrent callers that
# share a workdir key (so sibling compose operations in --parallel mode cannot
# race on the same project).

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
    CACHE_LOCATION="${BATS_TEST_TMPDIR}"
}

@test "_with_project_lock: runs the command and forwards its exit code" {
    run _with_project_lock "/srv/app" bash -c 'exit 0'
    [ "$status" -eq 0 ]
    run _with_project_lock "/srv/app" bash -c 'exit 7'
    [ "$status" -eq 7 ]
}

@test "_with_project_lock: serializes concurrent holders of the same key" {
    # Each worker appends B(egin), sleeps, then E(nd). If the lock holds, the
    # trace is two non-overlapping B..E pairs (BEBE), never interleaved (BBEE).
    local trace="${BATS_TEST_TMPDIR}/trace"
    : > "$trace"
    worker() {
        _with_project_lock "/srv/app" bash -c '
            printf B >> "'"$trace"'"
            sleep 0.3
            printf E >> "'"$trace"'"
        '
    }
    worker & worker &
    wait
    run cat "$trace"
    [ "$output" = "BEBE" ]
}

@test "_with_project_lock: refuses a symlinked lock file and does not run the command" {
    # Pre-plant the lock path as a symlink to a victim file (shared-/tmp attack).
    # The lock must be refused: the wrapped command never runs and the victim is
    # left untouched. Key derivation mirrors the function (cksum of the workdir).
    local key lock target ran
    key=$(cksum <<< "/srv/evil"); key=${key%% *}
    lock="${CACHE_LOCATION}/hoist-project-${key}.lock"
    target="${BATS_TEST_TMPDIR}/victim"
    : > "$target"
    ln -s "$target" "$lock"
    ran="${BATS_TEST_TMPDIR}/ran"
    run _with_project_lock "/srv/evil" bash -c "echo CLOBBERED > '$target'; : > '$ran'"
    [ "$status" -ne 0 ]
    [ ! -f "$ran" ]       # wrapped command never executed
    [ ! -s "$target" ]    # victim left empty — not clobbered through the symlink
}

@test "_with_project_lock: different keys run concurrently" {
    # Distinct workdirs must NOT serialize: overlapping execution yields BBEE.
    local trace="${BATS_TEST_TMPDIR}/trace2"
    : > "$trace"
    _with_project_lock "/srv/a" bash -c 'printf B >> "'"$trace"'"; sleep 0.3; printf E >> "'"$trace"'"' &
    _with_project_lock "/srv/b" bash -c 'printf B >> "'"$trace"'"; sleep 0.3; printf E >> "'"$trace"'"' &
    wait
    run cat "$trace"
    [ "$output" = "BBEE" ]
}
