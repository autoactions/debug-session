#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linux_script="$repo_root/scripts/linux.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

future_deadline=$(( $(date +%s) + 300 ))

expect_success() {
    local access_profile="$1"
    local session_profile="$2"
    ACCESS_PROFILE="$access_profile" SESSION_PROFILE="$session_profile" \
        SESSION_DEADLINE_EPOCH="$future_deadline" SESSION_PASSWORD='12345678' \
        bash "$linux_script" validate >/dev/null
}

expect_failure() {
    local access_profile="$1"
    local session_profile="$2"
    local deadline="$3"
    if ACCESS_PROFILE="$access_profile" SESSION_PROFILE="$session_profile" \
        SESSION_DEADLINE_EPOCH="$deadline" SESSION_PASSWORD='12345678' \
        bash "$linux_script" validate >/dev/null 2>&1; then
        fail "validation accepted access=$access_profile profile=$session_profile deadline=$deadline"
    fi
}

for access_profile in mini full; do
    for session_profile in core developer; do
        expect_success "$access_profile" "$session_profile"
    done
done

expect_failure ssh core "$future_deadline"
expect_failure xfce-rdp core "$future_deadline"
expect_failure min core "$future_deadline"
expect_failure mini workstation "$future_deadline"
expect_failure mini core invalid
expect_failure mini core "$(( $(date +%s) - 1 ))"

if ACCESS_PROFILE=minii SESSION_PROFILE=core bash "$linux_script" validate >/dev/null 2>&1; then
    fail 'validation accepted a missing Session Deadline'
fi
if bash "$linux_script" unknown >/dev/null 2>&1; then
    fail 'the Linux script accepted an unknown command'
fi

password_error="$({
    ACCESS_PROFILE=mini SESSION_PROFILE=core SESSION_DEADLINE_EPOCH="$future_deadline" \
        SESSION_PASSWORD='1234567' bash "$linux_script" validate
} 2>&1)" && fail 'Linux validation accepted a 7-character session password'
[[ "$password_error" == *'SESSION_PASSWORD must contain at least 8 characters'* ]] ||
    fail 'Linux validation did not explain the 8-character password minimum'

ACCESS_PROFILE=mini SESSION_PROFILE=core SESSION_DEADLINE_EPOCH="$future_deadline" \
    SESSION_PASSWORD='12345678' bash "$linux_script" validate >/dev/null ||
    fail 'Linux validation rejected an 8-character session password'

password_error="$({
    ACCESS_PROFILE=mini SESSION_PROFILE=core SESSION_DEADLINE_EPOCH="$future_deadline" \
        SESSION_PASSWORD=$'12345678\nsecond-line' bash "$linux_script" validate
} 2>&1)" && fail 'Linux validation accepted a multiline session password'
[[ "$password_error" == *'SESSION_PASSWORD must be a single line'* ]] ||
    fail 'Linux validation did not explain the single-line password requirement'

bash "$linux_script" cleanup >/dev/null ||
    fail 'Linux cleanup failed without OAuth credentials'

run_error="$(
    ACCESS_PROFILE=mini SESSION_PROFILE=core SESSION_DEADLINE_EPOCH="$future_deadline" \
        SESSION_PASSWORD='12345678' TAILSCALE_HOSTNAME=debug-session-linux \
        bash "$linux_script" run 2>&1
)" && fail 'Linux run accepted a missing OAuth client ID'
[[ "$run_error" == *'Required environment variable TAILSCALE_OAUTH_CLIENT_ID is empty'* ]] ||
    fail 'Linux run did not require TAILSCALE_OAUTH_CLIENT_ID'
[[ "$run_error" != *'apt-get'* ]] || fail 'Linux run reached apt-get before the OAuth client check'

grep -Fq 'core_package_present tailscale' "$linux_script" ||
    fail 'Linux does not check for a preinstalled Tailscale before installing'
grep -Fq 'core_package_present sshd' "$linux_script" ||
    fail 'Linux does not check for a preinstalled OpenSSH Server before installing'

install_line="$(grep -nF 'sudo install -d -o root -g root -m 0755 /run/sshd' "$linux_script" | cut -d: -f1)"
sshd_test_line="$(grep -nF 'sudo sshd -t' "$linux_script" | cut -d: -f1)"
[[ -n "$install_line" && -n "$sshd_test_line" && "$install_line" -lt "$sshd_test_line" ]] ||
    fail 'Linux does not create /run/sshd with root:root 0755 before checking sshd configuration'

ready_line="$(grep -nF 'Core Session ready' "$linux_script" | cut -d: -f1)"
rdp_listener_line="$(grep -nF 'assert_private_listener 3389' "$linux_script" | cut -d: -f1)"
[[ -n "$ready_line" && -n "$rdp_listener_line" && "$ready_line" -lt "$rdp_listener_line" ]] ||
    fail 'Linux does not announce Core Session ready before verifying the RDP listener'

grep -Fq '/usr/local/bin/stop-session' "$linux_script" ||
    fail 'Linux does not install the stop-session command on PATH'
if grep -Fq 'STOP_SESSION_HERE' "$linux_script"; then
    fail 'Linux still writes the STOP_SESSION_HERE instruction file'
fi

printf 'Linux input behavior: PASS\n'
