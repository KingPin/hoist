#!/usr/bin/env bats
# Baseline semver behavior. Cases added in Phase 1 (v-prefix, comma ranges,
# pre-release ordering) extend this file alongside their fixes.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
}

@test "_semver_gt: numeric ordering, not lexical (1.10.0 > 1.9.0)" {
    _semver_gt 1.10.0 1.9.0
    ! _semver_gt 1.9.0 1.10.0
}

@test "_semver_gt: equal is not greater" {
    ! _semver_gt 1.2.3 1.2.3
}

@test "_semver_eq: exact triple" {
    _semver_eq 1.2.3 1.2.3
    ! _semver_eq 1.2.3 1.2.4
}

@test "_semver_satisfies: caret allows same-major upgrades" {
    _semver_satisfies "^1.2.3" "1.5.0"
    ! _semver_satisfies "^1.2.3" "2.0.0"
}

@test "_semver_satisfies: tilde allows patch upgrades within the minor" {
    _semver_satisfies "~1.2.3" "1.2.9"
}

@test "_semver_satisfies: tilde blocks a minor bump" {
    ! _semver_satisfies "~1.2.3" "1.3.0"
    ! _semver_satisfies "~1.2.3" "2.0.0"
}

@test "_semver_satisfies: v-prefixed versions" {
    _semver_satisfies "^1.0.0" "v1.5.0"
    ! _semver_satisfies "<2.0.0" "v3.0.0"
    _semver_satisfies "^v1.0.0" "1.5.0"
}

@test "_semver_satisfies: comma range conjunction" {
    _semver_satisfies ">=0.1.2,<0.2" "0.1.5"
    ! _semver_satisfies ">=0.1.2,<0.2" "0.9.0"
    ! _semver_satisfies ">=0.1.2,<0.2" "0.1.0"
    # whitespace around parts is tolerated
    _semver_satisfies ">=1.0.0, <2.0.0" "1.4.0"
}

@test "_semver_compare: zero-padded fields do not trip octal arithmetic" {
    [[ $(_semver_compare "1.08.0" "1.9.0") == -1 ]]
    [[ $(_semver_compare "1.09.0" "1.09.0") == 0 ]]
}

@test "_semver_compare: release outranks pre-release at equal triple" {
    [[ $(_semver_compare "1.0.0" "1.0.0-rc.1") == 1 ]]
    [[ $(_semver_compare "1.0.0-rc.1" "1.0.0") == -1 ]]
}

@test "_semver_satisfies: pre-release below the >= boundary is excluded" {
    ! _semver_satisfies ">=1.0.0" "1.0.0-rc.1"
    _semver_satisfies "<1.0.0" "1.0.0-rc.1"
}

@test "_semver_satisfies: comparison operators" {
    _semver_satisfies ">=1.2.3" "1.2.3"
    _semver_satisfies ">1.2.3" "1.2.4"
    _semver_satisfies "<2.0.0" "1.9.9"
    _semver_satisfies "<=1.2.3" "1.2.3"
    _semver_satisfies "=1.2.3" "1.2.3"
    ! _semver_satisfies ">1.2.3" "1.2.3"
}

@test "_semver_satisfies: caret-on-0.x is hoist's intentional npm divergence" {
    # ^0.1.2 allows any 0.x >= 0.1.2 (documented divergence from npm)
    _semver_satisfies "^0.1.2" "0.5.0"
}

@test "_semver_satisfies: empty candidate version fails open" {
    _semver_satisfies "^1.2.3" ""
}
