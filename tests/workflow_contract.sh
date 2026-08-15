#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linux_workflow="$repo_root/.github/workflows/linux.yml"
windows_workflow="$repo_root/.github/workflows/windows.yml"
validation_workflow="$repo_root/.github/workflows/validate.yml"
smoke_workflow="$repo_root/.github/workflows/smoke.yml"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local text="$2"
    grep -Fq -- "$text" "$file" || fail "$file does not contain policy invariant: $text"
}

assert_not_contains() {
    local file="$1"
    local text="$2"
    if grep -Fq -- "$text" "$file"; then
        fail "$file retains removed public interface: $text"
    fi
}

for workflow in "$linux_workflow" "$windows_workflow"; do
    assert_not_contains "$workflow" 'actions/cache'
    assert_contains "$workflow" 'contents: read'
    # shellcheck disable=SC2016
    assert_contains "$workflow" 'timeout-minutes: 360'
    assert_contains "$workflow" 'SESSION_DEADLINE_EPOCH'
    assert_contains "$workflow" '330'
    # shellcheck disable=SC2016
    assert_contains "$workflow" 'SESSION_PASSWORD: ${{ secrets.SESSION_PASSWORD }}'
    assert_contains "$workflow" 'session_profile:'
    assert_contains "$workflow" 'default: core'
    assert_not_contains "$workflow" 'session_deadline:'
    assert_not_contains "$workflow" '350'
    # shellcheck disable=SC2016
    assert_contains "$workflow" 'if: ${{ always() }}'
    assert_not_contains "$workflow" 'RDP_PASSWORD'
    assert_not_contains "$workflow" 'optional_applications'
    assert_not_contains "$workflow" 'legitimate_use_case'
    assert_not_contains "$workflow" 'use_case_description'
done

assert_contains "$linux_workflow" 'access_profile:'
assert_contains "$linux_workflow" '- mini'
assert_contains "$linux_workflow" '- full'
assert_contains "$linux_workflow" 'default: mini'
assert_not_contains "$linux_workflow" 'xfce-rdp'
assert_not_contains "$linux_workflow" '- ssh'
assert_contains "$linux_workflow" 'bash scripts/linux.sh run'
assert_contains "$windows_workflow" './scripts/windows.ps1 run'
assert_contains "$windows_workflow" 'enable_wsl:'
assert_not_contains "$windows_workflow" 'Experimentally'
assert_not_contains "$smoke_workflow" 'experimental'
assert_not_contains "$windows_workflow" 'wsl_applications'
assert_not_contains "$windows_workflow" 'disable_search_index'
assert_not_contains "$windows_workflow" 'disable_onedrive'
assert_not_contains "$windows_workflow" 'use_dark_theme'
assert_not_contains "$windows_workflow" 'configure_desktop'

assert_contains "$validation_workflow" 'bash tests/dependency_preflight.sh'
assert_contains "$validation_workflow" 'bash tests/workflow_contract.sh'
assert_contains "$validation_workflow" 'bash tests/script_contract.sh'
assert_contains "$validation_workflow" 'bash tests/rclone_contract.sh'
assert_contains "$validation_workflow" 'bash tests/rclone_home_links_contract.sh'
assert_contains "$validation_workflow" 'bash tests/tailscale_protocol.sh'
assert_contains "$validation_workflow" './tests/windows_contract.ps1'
assert_contains "$smoke_workflow" 'workflow_dispatch:'
assert_contains "$smoke_workflow" 'SESSION_PROFILE: developer'
assert_contains "$smoke_workflow" 'bash scripts/linux.sh run'
assert_contains "$smoke_workflow" './scripts/windows.ps1 run'
assert_contains "$smoke_workflow" 'debug-session-smoke-linux'
assert_contains "$smoke_workflow" 'debug-session-smoke-windows'
assert_not_contains "$smoke_workflow" 'ChocolateyInstall'

for workflow in "$linux_workflow" "$windows_workflow" "$smoke_workflow"; do
    # shellcheck disable=SC2016
    assert_contains "$workflow" 'RCLONE_CONFIG: ${{ secrets.RCLONE_CONFIG }}'
    # shellcheck disable=SC2016
    assert_contains "$workflow" 'RCLONE_HOME_LINKS: ${{ vars.RCLONE_HOME_LINKS }}'
    assert_not_contains "$workflow" 'enable_rclone'
    assert_not_contains "$workflow" 'HOME_REMAPS'
    assert_not_contains "$workflow" 'REMOTE_NAME'
    # shellcheck disable=SC2016
    assert_contains "$workflow" 'TAILSCALE_OAUTH_CLIENT_ID: ${{ secrets.TAILSCALE_OAUTH_CLIENT_ID }}'
    # shellcheck disable=SC2016
    assert_contains "$workflow" 'TAILSCALE_OAUTH_CLIENT_SECRET: ${{ secrets.TAILSCALE_OAUTH_CLIENT_SECRET }}'
    assert_contains "$workflow" 'TAILSCALE_TAGS: tag:debug-session'
    assert_not_contains "$workflow" 'TAILSCALE_AUTH_KEY'
    assert_not_contains "$workflow" 'TAILSCALE_API_KEY'
done

printf 'Workflow policy contract: PASS\n'
