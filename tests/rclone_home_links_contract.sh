#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linux_script="$repo_root/scripts/linux.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# shellcheck disable=SC1090,SC1091
source "$linux_script"

future_deadline=$(( $(date +%s) + 300 ))

validate_with_links() {
    ACCESS_PROFILE=mini SESSION_PROFILE=core SESSION_DEADLINE_EPOCH="$future_deadline" \
        SESSION_PASSWORD='12345678' RCLONE_HOME_LINKS="$1" bash "$linux_script" validate
}

expect_validate_ok() {
    local spec="$1"
    validate_with_links "$spec" >/dev/null || fail "validation rejected valid RCLONE_HOME_LINKS: $spec"
}

expect_validate_fail() {
    local spec="$1"
    local needle="$2"
    local output
    if output="$(validate_with_links "$spec" 2>&1)"; then
        fail "validation accepted invalid RCLONE_HOME_LINKS: $spec"
    fi
    [[ "$output" == *"$needle"* ]] ||
        fail "validation error for [$spec] was [$output], expected to contain [$needle]"
}

expect_validate_ok ''
expect_validate_ok $'# comment\n\n.agents/=drive/dotfiles/agents/\n.grok/=drive/dotfiles/grok/'
expect_validate_ok $'.agents/ = drive/foo/ \ncodex/=drive/bar/'
expect_validate_ok $'.agents/=drive/dotfiles/agents/\r\n.grok/=drive/dotfiles/grok/'
expect_validate_ok '.grok/sessions/=koofr/Home/.grok/sessions/'
expect_validate_ok $'.agents/=koofr/Home/.agents/\n.grok/sessions/=koofr/Home/.grok/sessions/\n.grok/memory/=koofr/Home/.grok/memory/'
expect_validate_ok '.agents/extra/=drive/foo/'
expect_validate_ok '.grok/config.toml=koofr/Home/.grok/config.toml'
expect_validate_ok '.grok/auth.json=koofr/Home/.grok/auth.json'

expect_validate_fail $'.agents/=drive/a/\n.agents/=drive/b/' 'duplicate target'
expect_validate_fail $'.grok/=drive/g/\n.grok/sessions/=drive/g/sessions/' 'conflicts'
expect_validate_fail $'.grok/sessions/=drive/g/s/\n.grok/=drive/g/' 'conflicts'
expect_validate_fail '.agents/=koofr/Home/.agents' 'directory marker mismatch'
expect_validate_fail '.agents=koofr/Home/.agents/' 'directory marker mismatch'
expect_validate_fail 'agents' 'missing ='
expect_validate_fail '.agents/=/drive/foo/' 'source is invalid'
expect_validate_fail '.agents/=../drive/foo/' 'source is invalid'
expect_validate_fail '.agents/=drive/../foo/' 'source is invalid'
expect_validate_fail '.agents/=drive/./foo/' 'source is invalid'
expect_validate_fail '.agents/=drive//foo/' 'source is invalid'
expect_validate_fail 'rclone/=drive/foo/' 'target is invalid'
expect_validate_fail 'rclone/foo/=drive/foo/' 'target is invalid'
expect_validate_fail './=drive/foo/' 'target is invalid'
expect_validate_fail '../=drive/foo/' 'target is invalid'
expect_validate_fail '-agents/=drive/foo/' 'target is invalid'
expect_validate_fail '.grok/../sessions/=drive/s/' 'target is invalid'
expect_validate_fail '.grok//sessions/=drive/s/' 'target is invalid'
expect_validate_fail '.agents/=' 'source is invalid'
expect_validate_fail 'file:.grok/config.toml=koofr/Home/.grok/config.toml' 'target is invalid'

RCLONE_HOME_LINKS=$'# keep\n.agents/=drive/dotfiles/agents/\n.grok/config.toml=drive/grok/config.toml'
mapfile -t parsed < <(parse_rclone_home_links)
(( ${#parsed[@]} == 2 )) || fail "parsed ${#parsed[@]} mappings, expected 2"
[[ "${parsed[0]}" == $'.agents\tdrive/dotfiles/agents\tdir' ]] || fail "first mapping was ${parsed[0]}"
[[ "${parsed[1]}" == $'.grok/config.toml\tdrive/grok/config.toml\tfile' ]] || fail "second mapping was ${parsed[1]}"

home="$(mktemp -d)"
trap 'rm -rf -- "$home"' EXIT
HOME="$home"
export HOME

if rclone_has_live_mounts; then
    fail 'rclone_has_live_mounts was true with an empty home'
fi

RCLONE_HOME_LINKS='.agents/=drive/dotfiles/agents/'
export RCLONE_HOME_LINKS
enable_output="$(enable_rclone_home_links 2>&1)" || fail 'enable_rclone_home_links failed when no mounts exist'
[[ "$enable_output" == *'rclone mounts are unavailable; skipping home links'* ]] ||
    fail "missing no-mount skip warning: $enable_output"
[[ ! -e "$home/.agents" ]] || fail 'home link was created without a live rclone mount'

install_home_symlink "$home/.agents" 'rclone/drive/dotfiles/agents' ||
    fail 'install_home_symlink failed for a missing destination'
[[ "$(readlink -- "$home/.agents")" == 'rclone/drive/dotfiles/agents' ]] ||
    fail 'install_home_symlink did not create a relative home link'

[[ "$(rclone_home_link_relative_target "$home/.agents" 'drive/dotfiles/agents')" == 'rclone/drive/dotfiles/agents' ]] ||
    fail 'top-level home link relative target is wrong'
mkdir -p "$home/.grok"
[[ "$(rclone_home_link_relative_target "$home/.grok/sessions" 'koofr/Home/.grok/sessions')" == '../rclone/koofr/Home/.grok/sessions' ]] ||
    fail 'nested home link relative target is wrong'
install_home_symlink "$home/.grok/sessions" '../rclone/koofr/Home/.grok/sessions' ||
    fail 'install_home_symlink failed for a nested destination'
[[ "$(readlink -- "$home/.grok/sessions")" == '../rclone/koofr/Home/.grok/sessions' ]] ||
    fail 'install_home_symlink did not create a nested relative home link'

install_home_symlink "$home/.agents" 'rclone/drive/dotfiles/agents' ||
    fail 'install_home_symlink was not idempotent for the same target'

install_home_symlink "$home/.agents" 'rclone/drive/other' ||
    fail 'install_home_symlink did not replace a wrong symlink'
[[ "$(readlink -- "$home/.agents")" == 'rclone/drive/other' ]] ||
    fail 'wrong symlink was not replaced'

mkdir -p "$home/.empty"
install_home_symlink "$home/.empty" 'rclone/drive/empty' ||
    fail 'install_home_symlink did not replace an empty directory'
[[ "$(readlink -- "$home/.empty")" == 'rclone/drive/empty' ]] ||
    fail 'empty directory was not replaced with a symlink'

mkdir -p "$home/.full/keep"
if install_home_symlink "$home/.full" 'rclone/drive/full'; then
    fail 'install_home_symlink replaced a non-empty directory'
fi
[[ -d "$home/.full/keep" ]] || fail 'non-empty directory was disturbed'

printf 'x\n' >"$home/.file"
if install_home_symlink "$home/.file" 'rclone/drive/file'; then
    fail 'install_home_symlink replaced a regular file'
fi
[[ -f "$home/.file" ]] || fail 'regular file was disturbed'

mkdir -p "$home/rclone/koofr/Home/.grok"
ensure_rclone_home_link_source "$home/rclone/koofr/Home/.grok/config.toml" file ||
    fail 'ensure_rclone_home_link_source failed to create a missing file'
[[ -f "$home/rclone/koofr/Home/.grok/config.toml" ]] || fail 'missing file source was not created as a file'
ensure_rclone_home_link_source "$home/rclone/koofr/Home/.grok/sessions" dir ||
    fail 'ensure_rclone_home_link_source failed to create a missing directory'
[[ -d "$home/rclone/koofr/Home/.grok/sessions" ]] || fail 'missing directory source was not created as a directory'
mkdir -p "$home/rclone/koofr/Home/.grok/auth.json"
ensure_rclone_home_link_source "$home/rclone/koofr/Home/.grok/auth.json" file ||
    fail 'ensure_rclone_home_link_source failed to recover an empty file-named directory'
[[ -f "$home/rclone/koofr/Home/.grok/auth.json" ]] || fail 'empty file-named directory was not converted to a file'
install_home_symlink "$home/.grok/config.toml" '../rclone/koofr/Home/.grok/config.toml' ||
    fail 'install_home_symlink failed for a file destination'
[[ "$(readlink -- "$home/.grok/config.toml")" == '../rclone/koofr/Home/.grok/config.toml' ]] ||
    fail 'install_home_symlink did not create a file home link'

[[ "$(rclone_writeback_wait_seconds)" == 120 ]] ||
    fail 'rclone write-back wait is not 120 seconds'

printf 'rclone home links contract: PASS\n'
