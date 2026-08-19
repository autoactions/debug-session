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

src_root="$(mktemp -d)"
unmount_test_binds() {
    local path
    for path in "$home/.agents" "$home/.empty" "$home/.grok/sessions" "$home/.grok/config.toml"; do
        unmount_home_bind "$path"
    done
}
trap 'unmount_test_binds; rm -rf -- "$home" "$src_root"' EXIT

mkdir -p "$src_root/drive/dotfiles/agents" "$src_root/drive/other" "$src_root/koofr/Home/.grok/sessions"
printf 'agent\n' >"$src_root/drive/dotfiles/agents/readme"
printf 'cfg\n' >"$src_root/koofr/Home/.grok/config.toml"

install_home_bind "$home/.agents" "$src_root/drive/dotfiles/agents" dir ||
    fail 'install_home_bind failed for a missing destination'
mountpoint -q "$home/.agents" || fail 'install_home_bind did not create a directory mount'
[[ ! -L "$home/.agents" ]] || fail 'install_home_bind created a symlink'
[[ -f "$home/.agents/readme" ]] || fail 'directory bind did not expose source files'
home_bind_matches "$home/.agents" "$src_root/drive/dotfiles/agents" ||
    fail 'directory bind does not match the source'

install_home_bind "$home/.agents" "$src_root/drive/dotfiles/agents" dir ||
    fail 'install_home_bind was not idempotent for the same source'

install_home_bind "$home/.agents" "$src_root/drive/other" dir ||
    fail 'install_home_bind did not replace a wrong bind'
home_bind_matches "$home/.agents" "$src_root/drive/other" ||
    fail 'wrong bind was not replaced'
[[ ! -e "$home/.agents/readme" ]] || fail 'replaced bind still shows the old source'

mkdir -p "$home/.empty"
install_home_bind "$home/.empty" "$src_root/drive/dotfiles/agents" dir ||
    fail 'install_home_bind did not replace an empty directory'
mountpoint -q "$home/.empty" || fail 'empty directory was not replaced with a bind'
[[ ! -L "$home/.empty" ]] || fail 'empty directory was replaced with a symlink'

mkdir -p "$home/.full/keep"
if install_home_bind "$home/.full" "$src_root/drive/dotfiles/agents" dir; then
    fail 'install_home_bind replaced a non-empty directory'
fi
[[ -d "$home/.full/keep" ]] || fail 'non-empty directory was disturbed'

printf 'x\n' >"$home/.file"
if install_home_bind "$home/.file" "$src_root/drive/dotfiles/agents" dir; then
    fail 'install_home_bind replaced a regular file'
fi
[[ -f "$home/.file" ]] || fail 'regular file was disturbed'

unmount_home_bind "$home/.agents"
rmdir "$home/.agents" 2>/dev/null || rm -f -- "$home/.agents"
ln -s /tmp "$home/.agents"
install_home_bind "$home/.agents" "$src_root/drive/dotfiles/agents" dir ||
    fail 'install_home_bind did not replace a leftover symlink'
[[ ! -L "$home/.agents" ]] || fail 'leftover symlink was not replaced'
mountpoint -q "$home/.agents" || fail 'leftover symlink was not replaced with a bind'

mkdir -p "$home/.grok"
install_home_bind "$home/.grok/sessions" "$src_root/koofr/Home/.grok/sessions" dir ||
    fail 'install_home_bind failed for a nested destination'
mountpoint -q "$home/.grok/sessions" || fail 'nested destination is not a mountpoint'
[[ ! -L "$home/.grok/sessions" ]] || fail 'nested destination is a symlink'

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

install_home_bind "$home/.grok/config.toml" "$src_root/koofr/Home/.grok/config.toml" file ||
    fail 'install_home_bind failed for a file destination'
mountpoint -q "$home/.grok/config.toml" || fail 'file destination is not a mountpoint'
[[ ! -L "$home/.grok/config.toml" ]] || fail 'file destination is a symlink'
[[ "$(cat -- "$home/.grok/config.toml")" == $'cfg' ]] || fail 'file bind did not expose source contents'

unmount_home_bind "$home/.grok/config.toml"
install_home_bind "$home/.grok/config.toml" "$src_root/koofr/Home/.grok/config.toml" file ||
    fail 'install_home_bind did not reuse an empty file placeholder'
mountpoint -q "$home/.grok/config.toml" || fail 'empty file placeholder was not bound'

printf 'local\n' >"$home/.grok/auth.json"
if install_home_bind "$home/.grok/auth.json" "$src_root/koofr/Home/.grok/config.toml" file; then
    fail 'install_home_bind replaced a non-empty local file'
fi
[[ "$(cat -- "$home/.grok/auth.json")" == $'local' ]] || fail 'non-empty local file was disturbed'

RCLONE_HOME_LINKS=$'.agents/=drive/dotfiles/agents/\n.grok/sessions/=koofr/Home/.grok/sessions/\n.grok/config.toml=koofr/Home/.grok/config.toml'
export RCLONE_HOME_LINKS
cleanup_rclone_home_mounts
if mountpoint -q "$home/.agents" 2>/dev/null || mountpoint -q "$home/.grok/sessions" 2>/dev/null ||
    mountpoint -q "$home/.grok/config.toml" 2>/dev/null; then
    fail 'cleanup_rclone_home_mounts left home binds mounted'
fi

ln -s -- rclone/drive/leftover "$home/.agents"
cleanup_rclone_home_mounts
[[ ! -L "$home/.agents" ]] || fail 'cleanup_rclone_home_mounts left a leftover symlink'

[[ "$(rclone_writeback_wait_seconds)" == 120 ]] ||
    fail 'rclone write-back wait is not 120 seconds'

printf 'rclone home links contract: PASS\n'
