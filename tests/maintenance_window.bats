#!/usr/bin/env bats
# Maintenance-window predicate and format validation. The predicate is pure
# (takes the current time as an argument) so these tests never touch the clock.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
}

@test "_in_maintenance_window: inside a same-day window" {
    _in_maintenance_window "02:00-06:00" "0300"
}

@test "_in_maintenance_window: start is inclusive, end is exclusive" {
    _in_maintenance_window "02:00-06:00" "0200"
    ! _in_maintenance_window "02:00-06:00" "0600"
}

@test "_in_maintenance_window: outside a same-day window" {
    ! _in_maintenance_window "02:00-06:00" "0130"
    ! _in_maintenance_window "02:00-06:00" "0700"
}

@test "_in_maintenance_window: zero-padded times do not trip octal arithmetic" {
    # 0800/0900 are invalid octal — the old [[ -le ]] form errored on these.
    ! _in_maintenance_window "02:00-06:00" "0900"
    ! _in_maintenance_window "02:00-06:00" "0800"
    _in_maintenance_window "08:00-09:30" "0900"
}

@test "_in_maintenance_window: window spanning midnight" {
    _in_maintenance_window "22:00-06:00" "2300"
    _in_maintenance_window "22:00-06:00" "0500"
    ! _in_maintenance_window "22:00-06:00" "1200"
    _in_maintenance_window "22:00-06:00" "2200"
    ! _in_maintenance_window "22:00-06:00" "0600"
}

@test "_validate_maintenance_window: empty is allowed" {
    _validate_maintenance_window ""
}

@test "_validate_maintenance_window: well-formed window passes" {
    _validate_maintenance_window "02:00-06:00"
    _validate_maintenance_window "23:59-00:00"
}

@test "_validate_maintenance_window: malformed window is rejected" {
    ! _validate_maintenance_window "2:00-6:00"
    ! _validate_maintenance_window "02:00to06:00"
    ! _validate_maintenance_window "25:00-06:00"
    ! _validate_maintenance_window "02:60-06:00"
    ! _validate_maintenance_window "0200-0600"
}
