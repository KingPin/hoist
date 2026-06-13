#!/usr/bin/env bats
# Username validation feeds the cron/systemd heredocs, where values are
# interpolated (not quotable). Reject newlines and shell metacharacters before
# the value can inject a directive into a generated unit file.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
}

@test "_validate_user: a username with an embedded newline is rejected" {
    run _validate_user $'root\n0 0 * * * root rm -rf /'
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid username"* ]]
}

@test "_validate_user: shell metacharacters are rejected" {
    run _validate_user 'bad;rm -rf /'
    [ "$status" -ne 0 ]
    run _validate_user 'a b'
    [ "$status" -ne 0 ]
    run _validate_user 'x$(touch pwned)'
    [ "$status" -ne 0 ]
}

@test "_validate_user: a well-formed name passes the charset gate" {
    # Use an account that exists on essentially every system so the downstream
    # getent/id lookup also succeeds; the charset gate is what we're exercising.
    run _validate_user "root"
    [ "$status" -eq 0 ]
}
