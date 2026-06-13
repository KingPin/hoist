#!/usr/bin/env bats
# Symlink guard for state files in a shared CACHE_LOCATION (/tmp). A planted
# symlink at our predictable filename must never be written through.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
    CACHE_LOCATION="${BATS_TEST_TMPDIR}"
}

@test "_state_path_safe: a non-existent path is safe to write" {
    run _state_path_safe "${BATS_TEST_TMPDIR}/hoist-new.notified"
    [ "$status" -eq 0 ]
}

@test "_state_path_safe: an existing regular file is safe to write" {
    : > "${BATS_TEST_TMPDIR}/hoist-real.notified"
    run _state_path_safe "${BATS_TEST_TMPDIR}/hoist-real.notified"
    [ "$status" -eq 0 ]
}

@test "_state_path_safe: a symlink is refused" {
    ln -s /etc/shadow "${BATS_TEST_TMPDIR}/hoist-evil.notified"
    run _state_path_safe "${BATS_TEST_TMPDIR}/hoist-evil.notified"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
}

@test "_state_path_safe: a symlink to a non-existent target is still refused" {
    ln -s /nonexistent/target "${BATS_TEST_TMPDIR}/hoist-dangling.notified"
    run _state_path_safe "${BATS_TEST_TMPDIR}/hoist-dangling.notified"
    [ "$status" -ne 0 ]
}
