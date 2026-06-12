# Tests

Unit tests for `hoist.sh`'s pure functions, using [bats-core](https://github.com/bats-core/bats-core)
(vendored as a git submodule under `tests/bats`).

`hoist.sh` guards its entry point with `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`, so the
test helper can `source` it to exercise individual functions without running the tool.

## Running

```bash
git submodule update --init --recursive   # first time, to fetch bats
tests/bats/bin/bats tests/
```

## Coverage

- `semver.bats` — version comparison and constraint satisfaction
- `maintenance_window.bats` — maintenance-window predicate
- `argparse.bats` — CLI flag parsing and TAG normalization
- `bool.bats` — boolean label normalization
