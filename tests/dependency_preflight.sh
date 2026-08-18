#!/usr/bin/env bash
set -euo pipefail

check_url() {
    local name="$1"
    local url="$2"
    if ! curl --retry 3 --retry-all-errors -fsSL -A 'debug-session-preflight' -o /dev/null "$url"; then
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
check_url 'Tailscale Windows stable index' 'https://pkgs.tailscale.com/stable/?mode=json'
check_url 'VS Code apt repository' 'https://packages.microsoft.com/repos/code/dists/stable/Release'
check_url 'VS Code Windows release index' 'https://update.code.visualstudio.com/api/releases/stable'
check_url 'Node.js distribution index' 'https://nodejs.org/dist/index.json'
check_url 'Herdr latest manifest' 'https://herdr.dev/latest.json'
check_url 'rclone Linux amd64 package' 'https://downloads.rclone.org/rclone-current-linux-amd64.zip'
check_url 'rclone Windows amd64 package' 'https://downloads.rclone.org/rclone-current-windows-amd64.zip'
check_url 'WinFsp GitHub latest release' 'https://api.github.com/repos/winfsp/winfsp/releases/latest'

npm view '@openai/codex' version >/dev/null
npm view '@xai-official/grok' version >/dev/null
git ls-remote --exit-code https://github.com/ohmyzsh/ohmyzsh.git HEAD >/dev/null

printf 'Dependency preflight: PASS\n'
