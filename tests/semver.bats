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

@test "_semver_satisfies: tilde blocks a minor bump (BUG: fixed in Phase 1)" {
    skip "tilde constraint is non-functional — case pattern '~)' undergoes tilde expansion; fixed with the Phase 1 semver work"
    ! _semver_satisfies "~1.2.3" "1.3.0"
    ! _semver_satisfies "~1.2.3" "2.0.0"
}

@test "_semver_satisfies: v-prefixed versions (BUG: fixed in Phase 1)" {
    skip "v-prefix collapses to major 0; fixed in Phase 1"
    _semver_satisfies "^1.0.0" "v1.5.0"
    ! _semver_satisfies "<2.0.0" "v3.0.0"
}

@test "_semver_satisfies: comma range conjunction (BUG: fixed in Phase 1)" {
    skip "comma ranges silently drop the upper bound; fixed in Phase 1"
    _semver_satisfies ">=0.1.2,<0.2" "0.1.5"
    ! _semver_satisfies ">=0.1.2,<0.2" "0.9.0"
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
