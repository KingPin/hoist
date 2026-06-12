#!/usr/bin/env bats
# Boolean label/config normalization. Gates (update/notify/rollback/
# healthcheck.wait, ROLLBACK_DEFAULT) route through _is_true so user-supplied
# capitalization and synonyms behave consistently.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
}

@test "_is_true: canonical true" {
    _is_true "true"
}

@test "_is_true: case-insensitive and synonyms" {
    _is_true "True"
    _is_true "TRUE"
    _is_true "1"
    _is_true "yes"
    _is_true "YES"
    _is_true "on"
}

@test "_is_true: false-ish values are not true" {
    ! _is_true "false"
    ! _is_true "False"
    ! _is_true "0"
    ! _is_true "no"
    ! _is_true ""
}

@test "_is_true: unrecognized values are not true" {
    ! _is_true "maybe"
    ! _is_true "truthy"
}
