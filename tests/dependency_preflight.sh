#!/usr/bin/env bash
set -euo pipefail

check_url() {
    local name="$1"
    local url="$2"
    if ! curl --retry 3 --retry-all-errors -fsSL -o /dev/null "$url"; then
        printf 'Dependency unavailable: %s (%s)\n' "$name" "$url" >&2
        return 1
    fi
}

codename="$(awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
[[ -n "$codename" ]] || {
    printf 'Ubuntu VERSION_CODENAME is unavailable\n' >&2
    exit 1
}

check_url 'Tailscale Ubuntu signing key' "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg"
check_url 'Tailscale Ubuntu repository' "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list"
check_url 'Tailscale Chocolatey package' 'https://community.chocolatey.org/packages/tailscale'
check_url '7-Zip Chocolatey package' 'https://community.chocolatey.org/packages/7zip'
check_url 'VS Code Chocolatey package' 'https://community.chocolatey.org/packages/vscode'
check_url 'VS Code apt repository' 'https://packages.microsoft.com/repos/code/dists/stable/Release'

npm view '@openai/codex' version >/dev/null
npm view '@xai-official/grok' version >/dev/null
git ls-remote --exit-code https://github.com/ohmyzsh/ohmyzsh.git HEAD >/dev/null

printf 'Dependency preflight: PASS\n'
