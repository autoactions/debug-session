#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linux_script="$repo_root/scripts/linux.sh"
linux_workflow="$repo_root/.github/workflows/linux.yml"
windows_workflow="$repo_root/.github/workflows/windows.yml"
smoke_workflow="$repo_root/.github/workflows/smoke.yml"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# shellcheck disable=SC1090,SC1091
source "$linux_script"

if ! rclone_config_present; then
    :
else
    fail 'rclone_config_present was true with an empty RCLONE_CONFIG'
fi

RCLONE_CONFIG='placeholder'
rclone_config_present || fail 'rclone_config_present was false when RCLONE_CONFIG was set'
unset RCLONE_CONFIG

rclone_remote_mountable 'drive' || fail 'safe remote name drive was rejected'
rclone_remote_mountable 'crypt-data' || fail 'safe remote name crypt-data was rejected'
rclone_remote_mountable '' && fail 'empty remote name was accepted'
rclone_remote_mountable '.' && fail 'remote name . was accepted'
rclone_remote_mountable '..' && fail 'remote name .. was accepted'
rclone_remote_mountable 'bad/name' && fail 'remote name with slash was accepted'
rclone_remote_mountable 'bad\name' && fail 'remote name with backslash was accepted'

home="$(mktemp -d)"
trap 'rm -rf -- "$home"' EXIT
HOME="$home"
export HOME

RCLONE_CONFIG="$(printf '%s\n' \
    '[drive]' \
    'type = drive' \
    'token = {"access_token":"secret"}' \
    '' \
    '[crypt]' \
    'type = crypt' \
    'remote = drive:hidden' \
    '' \
    '[notyet]' \
    'token = ignore' \
    '' \
    '[bad/name]' \
    'type = s3' \
    '' \
    '[aliasbox]' \
    'type = alias' \
    'remote = drive:docs')"
export RCLONE_CONFIG

write_rclone_config || fail 'write_rclone_config failed'
config_path="$(rclone_config_path)"
[[ -f "$config_path" ]] || fail 'rclone.conf was not written'
[[ "$RCLONE_CONFIG" == "$config_path" ]] ||
    fail 'RCLONE_CONFIG was not pointed at the written config file after write'
perms="$(stat -c '%a' "$config_path")"
[[ "$perms" == 600 ]] || fail "rclone.conf mode is $perms, expected 600"
if grep -Fq 'access_token' <<<"$(ls -l "$config_path")"; then
    fail 'rclone.conf listing unexpectedly included secret text'
fi

mapfile -t remotes < <(list_rclone_remotes_from_config)
expected=(drive crypt 'bad/name' aliasbox)
(( ${#remotes[@]} == ${#expected[@]} )) || fail "parsed remotes [${remotes[*]}], expected [${expected[*]}]"
for i in "${!expected[@]}"; do
    [[ "${remotes[$i]}" == "${expected[$i]}" ]] || fail "parsed remotes [${remotes[*]}], expected [${expected[*]}]"
done
rclone_remote_mountable 'bad/name' && fail 'remote name with slash was accepted after parsing'

future_deadline=$(( $(date +%s) + 300 ))
ACCESS_PROFILE=mini SESSION_PROFILE=core SESSION_DEADLINE_EPOCH="$future_deadline" \
    SESSION_PASSWORD='12345678' bash "$linux_script" validate >/dev/null ||
    fail 'Linux validation failed when RCLONE_CONFIG was unset'

ACCESS_PROFILE=mini SESSION_PROFILE=core SESSION_DEADLINE_EPOCH="$future_deadline" \
    SESSION_PASSWORD='12345678' RCLONE_CONFIG='not-an-ini' bash "$linux_script" validate >/dev/null ||
    fail 'Linux validation failed when RCLONE_CONFIG was invalid'

grep -Fq 'enable_rclone_mounts' "$linux_script" || fail 'Linux does not provision rclone mounts'
grep -Fq -- '--vfs-cache-mode writes' "$linux_script" || fail 'Linux does not use vfs-cache-mode writes'
grep -Fq -- '--allow-other' "$linux_script" && fail 'Linux enables FUSE allow-other'
grep -Fq 'downloads.rclone.org/rclone-current-linux-' "$linux_script" ||
    fail 'Linux does not install rclone from the official current package'
grep -Fq 'fuse3' "$linux_script" || fail 'Linux does not install fuse3'
grep -Fq 'cleanup_rclone_mounts' "$linux_script" || fail 'Linux does not clean up rclone mounts'

run_core="$(grep -nF 'enable_core_session' "$linux_script" | tail -n1 | cut -d: -f1)"
run_rclone="$(grep -nF 'enable_rclone_mounts' "$linux_script" | tail -n1 | cut -d: -f1)"
run_xfce="$(grep -nF 'enable_xfce_rdp' "$linux_script" | tail -n1 | cut -d: -f1)"
run_dev="$(grep -nF 'install_developer_profile' "$linux_script" | tail -n1 | cut -d: -f1)"
[[ -n "$run_core" && -n "$run_rclone" && -n "$run_xfce" && -n "$run_dev" ]] ||
    fail 'Linux run_session is missing core, rclone, xfce, or developer steps'
(( run_core < run_rclone && run_rclone < run_xfce && run_rclone < run_dev )) ||
    fail 'Linux does not mount rclone after Core Session ready and before XFCE/Developer'

cleanup_rclone_line="$(grep -nF 'cleanup_rclone_mounts' "$linux_script" | tail -n1 | cut -d: -f1)"
cleanup_logout_line="$(grep -nF 'tailscale logout' "$linux_script" | tail -n1 | cut -d: -f1)"
[[ -n "$cleanup_rclone_line" && -n "$cleanup_logout_line" && "$cleanup_rclone_line" -lt "$cleanup_logout_line" ]] ||
    fail 'Linux does not clean up rclone mounts before Tailscale logout'

for workflow in "$linux_workflow" "$windows_workflow" "$smoke_workflow"; do
    # shellcheck disable=SC2016
    grep -Fq 'RCLONE_CONFIG: ${{ secrets.RCLONE_CONFIG }}' "$workflow" ||
        fail "$workflow does not pass RCLONE_CONFIG as an environment variable"
    grep -Fq 'enable_rclone' "$workflow" && fail "$workflow adds an enable_rclone input"
    grep -Fq 'REMOTE_NAME' "$workflow" && fail "$workflow still references REMOTE_NAME"
    grep -Fq "echo '\${{ secrets.RCLONE_CONFIG }}'" "$workflow" &&
        fail "$workflow writes RCLONE_CONFIG through echo of the secret expression"
done

grep -Fq 'rclone_config_present' "$linux_script" || fail 'Linux does not skip rclone when the secret is empty'

printf 'rclone contract: PASS\n'
