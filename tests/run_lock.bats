#!/usr/bin/env bats
# Run lock hardening. _acquire_run_lock opens ${CACHE_LOCATION}/hoist.lock with
# an exec redirect that would follow (and truncate) a pre-planted symlink on a
# shared /tmp. A symlink at the lock path is hostile/broken — distinct from a
# legitimately held lock — so hoist must refuse to run (exit 1) and leave the
# link target untouched.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
    CACHE_LOCATION="${BATS_TEST_TMPDIR}"
}

@test "_acquire_run_lock: refuses a symlinked lock path and does not clobber the target" {
    local lock="${CACHE_LOCATION}/hoist.lock"
    local target="${BATS_TEST_TMPDIR}/victim"
    : > "$target"
    ln -s "$target" "$lock"
    run _acquire_run_lock
    [ "$status" -eq 1 ]
    [ ! -s "$target" ]    # link target left empty — the exec redirect never ran
}

@test "_acquire_run_lock: a fresh (non-symlink) lock path is acquired cleanly" {
    run _acquire_run_lock
    [ "$status" -eq 0 ]
}
