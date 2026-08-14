#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linux_script="$repo_root/scripts/linux.sh"
windows_script="$repo_root/scripts/windows.ps1"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# Leftover-name rule: the reserved hostname, or that name plus '-' and
# one or more digits. Both platform scripts must keep this behavior;
# this file is the only test copy of the rule.
is_reserved_hostname_leftover() {
    local reserved="$1"
    local candidate="$2"
    [[ "$candidate" == "$reserved" ]] && return 0
    local prefix="$reserved-"
    [[ "$candidate" == "$prefix"* ]] || return 1
    local suffix="${candidate#"$prefix"}"
    [[ "$suffix" =~ ^[0-9]+$ ]]
}

cases="$repo_root/tests/reserved_hostname_cases.tsv"
[[ -f "$cases" ]] || fail "missing reserved hostname cases: $cases"

while IFS=$'\t' read -r reserved candidate expected; do
    [[ -n "$reserved" && "$reserved" != \#* ]] || continue
    if is_reserved_hostname_leftover "$reserved" "$candidate"; then
        matched=1
    else
        matched=0
    fi
    [[ "$matched" == "$expected" ]] ||
        fail "leftover rule mismatch for $candidate under $reserved (got $matched, want $expected)"
done < "$cases"

grep -Fq 're.escape(reserved)' "$linux_script" ||
    fail 'Linux leftover matching no longer treats reserved-name plus digits as leftovers'

grep -Fq '200|204|404' "$linux_script" ||
    fail 'Linux device delete no longer treats HTTP 200, 204, and 404 as success'

grep -Fq 'Test-ReservedHostnameLeftover' "$windows_script" ||
    fail 'Windows leftover matching helper is missing'

# shellcheck disable=SC2016
grep -Fq 'Substring($prefix.Length)' "$windows_script" ||
    fail 'Windows leftover matching no longer requires a numeric suffix'

# shellcheck disable=SC2016
if ! grep -Fq '$status -ne 404' "$windows_script"; then
    fail 'Windows device delete no longer treats HTTP 404 as success'
fi

printf 'Tailscale reserved-name protocol: PASS\n'
