#!/usr/bin/env bash
# Hoist installer
#
# WARNING: This script downloads and installs hoist to your system.
# Always inspect scripts before piping curl|sh:
#   curl -fsSL https://raw.githubusercontent.com/KingPin/hoist/master/install.sh | less
#
# Env vars:
#   HOIST_VERSION         Pin to a release tag (e.g. v1.2.0). Default: latest release.
#   INSTALL_DIR           Where to install the binary. Default: /usr/local/bin
#   CONFIG_DIR            Where to install config files. Default: /etc/hoist
#   HOIST_NONINTERACTIVE  Set to 1 to skip the post-install scheduling prompt.

set -euo pipefail

HOIST_REPO="KingPin/hoist"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/hoist}"
HOIST_VERSION="${HOIST_VERSION:-}"

err()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }
info() { echo ">> $*"; }

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        err "neither sha256sum nor shasum available"
    fi
}

# Run command with sudo iff the nearest existing ancestor of target isn't writable.
# Walking up handles deeply nested missing paths (e.g. INSTALL_DIR=$HOME/.local/bin
# when $HOME/.local doesn't exist yet — mkdir -p would succeed without sudo).
_sudo_if_needed() {
    local target="$1"; shift
    local probe="$target"
    while [[ ! -e "$probe" && "$probe" != "/" ]]; do
        probe="$(dirname "$probe")"
    done
    if [[ -w "$probe" ]]; then
        "$@" || err "step failed (target: $target): $*"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@" || err "privileged step failed or was cancelled (target: $target): $*"
    else
        err "cannot write to $target and sudo is not available"
    fi
}

command -v curl >/dev/null 2>&1 || err "curl is required"
command -v docker >/dev/null 2>&1 || warn "docker not found — install it before running hoist"
command -v jq     >/dev/null 2>&1 || warn "jq not found — install it before running hoist"

if [[ -z ${BASH_VERSINFO+x} || ${BASH_VERSINFO[0]} -lt 4 ]]; then
    warn "hoist requires bash 4+ at runtime (current: ${BASH_VERSION:-unknown})."
    warn "  macOS: brew install bash, then ensure the Homebrew bash is first in PATH"
    warn "         (e.g. /opt/homebrew/bin or /usr/local/bin). Verify with: bash --version"
fi

if [[ -n $HOIST_VERSION ]]; then
    url_prefix="https://github.com/${HOIST_REPO}/releases/download/${HOIST_VERSION}"
    info "Installing hoist ${HOIST_VERSION}"
else
    url_prefix="https://github.com/${HOIST_REPO}/releases/latest/download"
    info "Installing hoist (latest release)"
fi

tmp=$(mktemp -d -t hoist.XXXXXX 2>/dev/null) \
    || tmp=$(mktemp -d "${TMPDIR:-/tmp}/hoist.XXXXXX") \
    || err "failed to create temp directory"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP

# hoist.sh is required; hoist.conf.example is best-effort so the installer still
# works against releases that predate the conf.example asset. We use -w to
# distinguish HTTP 404 (asset genuinely missing) from network/proxy/DNS errors.
_fetch() {
    local asset="$1" optional="${2:-false}" http
    http=$(curl -sSL --max-time 60 --connect-timeout 10 \
        -H "User-Agent: hoist-installer" \
        -w '%{http_code}' \
        -o "${tmp}/${asset}" "${url_prefix}/${asset}" 2>/dev/null) || http="000"
    case "$http" in
        200) return 0 ;;
        000) err "network failure downloading ${asset} (timeout, DNS, or connection refused)" ;;
        404)
            if [[ $optional == true ]]; then
                warn "release does not include ${asset} — skipping config seeding"
                return 1
            fi
            err "release asset ${asset} not found at ${url_prefix}/" ;;
        *) err "HTTP ${http} downloading ${asset} from ${url_prefix}/" ;;
    esac
}

have_conf=true
info "Downloading release assets from ${url_prefix}/"
_fetch hoist.sh
_fetch hoist.sh.sha256
_fetch hoist.conf.example         true || have_conf=false
[[ $have_conf == true ]] && { _fetch hoist.conf.example.sha256 true || have_conf=false; }

info "Verifying checksums"
verify_targets=("hoist.sh")
[[ $have_conf == true ]] && verify_targets+=("hoist.conf.example")
for f in "${verify_targets[@]}"; do
    expected=$(awk '{print $1}' "${tmp}/${f}.sha256")
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || err "malformed SHA256 for ${f}"
    actual=$(_sha256 "${tmp}/${f}") || err "cannot compute SHA256 for ${f}"
    [[ $expected == "$actual" ]] || err "SHA256 mismatch for ${f} (expected ${expected}, got ${actual})"
done

info "Installing binary to ${INSTALL_DIR}/hoist"
_sudo_if_needed "$INSTALL_DIR" mkdir -p "$INSTALL_DIR"
_sudo_if_needed "${INSTALL_DIR}/hoist" install -m 0755 "${tmp}/hoist.sh" "${INSTALL_DIR}/hoist"

if [[ $have_conf == true ]]; then
    info "Installing config to ${CONFIG_DIR}/"
    _sudo_if_needed "$CONFIG_DIR" mkdir -p "$CONFIG_DIR"
    _sudo_if_needed "${CONFIG_DIR}/hoist.conf.example" \
        install -m 0644 "${tmp}/hoist.conf.example" "${CONFIG_DIR}/hoist.conf.example"

    if [[ ! -e "${CONFIG_DIR}/hoist.conf" ]]; then
        info "Seeding ${CONFIG_DIR}/hoist.conf from example"
        _sudo_if_needed "${CONFIG_DIR}/hoist.conf" \
            install -m 0644 "${tmp}/hoist.conf.example" "${CONFIG_DIR}/hoist.conf"
    else
        info "${CONFIG_DIR}/hoist.conf already exists — leaving untouched"
    fi
fi

echo
info "Hoist installed successfully."
"${INSTALL_DIR}/hoist" --version 2>/dev/null || true
echo
echo "Next steps:"
if [[ $have_conf == true ]]; then
    echo "  - Review/edit ${CONFIG_DIR}/hoist.conf"
else
    echo "  - This release didn't ship hoist.conf.example as an asset; grab it from"
    echo "    https://github.com/${HOIST_REPO}/blob/master/hoist.conf.example and place it at"
    echo "    ${CONFIG_DIR}/hoist.conf if you want a system-wide config"
fi
echo "  - Add com.sumguy.hoist.* labels to containers you want managed"
echo "  - Docs: https://github.com/${HOIST_REPO}#usage"

if [[ -t 0 && -t 1 && "${HOIST_NONINTERACTIVE:-0}" != 1 ]]; then
    echo
    read -rp "Install a scheduled run for hoist now? [y/N] " _setup_ans
    if [[ ${_setup_ans,,} == y ]]; then
        exec "${INSTALL_DIR}/hoist" --cron install
    fi
fi
