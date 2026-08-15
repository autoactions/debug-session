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

validate_with_workspaces() {
    ACCESS_PROFILE=mini SESSION_PROFILE=core SESSION_DEADLINE_EPOCH="$future_deadline" \
        SESSION_PASSWORD='12345678' GIT_WORKSPACES="$1" bash "$linux_script" validate
}

expect_validate_ok() {
    local spec="$1"
    validate_with_workspaces "$spec" >/dev/null || fail "validation rejected valid GIT_WORKSPACES: $spec"
}

expect_validate_fail() {
    local spec="$1"
    local needle="$2"
    local output
    if output="$(validate_with_workspaces "$spec" 2>&1)"; then
        fail "validation accepted invalid GIT_WORKSPACES: $spec"
    fi
    [[ "$output" == *"$needle"* ]] ||
        fail "validation error for [$spec] was [$output], expected to contain [$needle]"
}

expect_validate_ok ''
expect_validate_ok $'# comment\n\nhttps://github.com/org/proj-a\nhttps://github.com/org/proj-b.git'
expect_validate_ok $'my-app = https://github.com/org/proj-c \n'
expect_validate_ok $'https://github.com/org/proj-a\r\nhttps://github.com/org/proj-b'
expect_validate_ok 'https://github.com/org/proj-a/'
expect_validate_ok 'https://gitlab.example.com:8443/group/sub/repo.git'
expect_validate_ok 'org/priv'
expect_validate_ok 'org/priv.git'
expect_validate_ok 'my-app=org/priv'
expect_validate_ok 'foo/bar=https://github.com/org/proj'

expect_validate_fail $'https://github.com/org/a\nhttps://github.com/other/a.git' 'duplicate name'
expect_validate_fail $'app=https://github.com/org/a\napp=https://github.com/org/b' 'duplicate name'
expect_validate_fail $'org/priv\norg/priv.git' 'duplicate name'
expect_validate_fail $'org=https://github.com/acme/org\norg/priv' 'conflicts'
expect_validate_fail 'http://github.com/org/proj' 'URL is invalid'
expect_validate_fail 'git@github.com:org/proj.git' 'missing a URL'
expect_validate_fail 'ssh://git@github.com/org/proj.git' 'URL is invalid'
expect_validate_fail 'file:///tmp/proj' 'URL is invalid'
expect_validate_fail 'https://user:pass@github.com/org/proj' 'URL is invalid'
expect_validate_fail 'https://github.com/org/proj?foo=1' 'URL is invalid'
expect_validate_fail 'https://github.com/' 'URL is invalid'
expect_validate_fail 'https://github.com' 'URL is invalid'
expect_validate_fail '../evil=https://github.com/org/proj' 'name is invalid'
expect_validate_fail '.=https://github.com/org/proj' 'name is invalid'
expect_validate_fail 'org/../priv' 'missing a URL'
expect_validate_fail 'org/priv/extra' 'missing a URL'
expect_validate_fail 'my-app=' 'URL is invalid'
expect_validate_fail 'just-a-name' 'missing a URL'

GIT_WORKSPACES=$'# keep\nhttps://github.com/org/proj-a.git\nmy-app=https://github.com/org/proj-c\norg/priv'
mapfile -t parsed < <(parse_git_workspaces)
(( ${#parsed[@]} == 3 )) || fail "parsed ${#parsed[@]} workspaces, expected 3"
[[ "${parsed[0]}" == $'proj-a\thttps://github.com/org/proj-a.git' ]] || fail "first workspace was ${parsed[0]}"
[[ "${parsed[1]}" == $'my-app\thttps://github.com/org/proj-c' ]] || fail "second workspace was ${parsed[1]}"
[[ "${parsed[2]}" == $'org/priv\thttps://github.com/org/priv' ]] || fail "shorthand workspace was ${parsed[2]}"

[[ "$(git_workspace_name_from_url 'https://github.com/org/proj-b.git')" == 'proj-b' ]] ||
    fail 'name from URL did not strip .git'
[[ "$(workspace_root)" == "$HOME/workspaces" ]] ||
    fail "workspace_root was $(workspace_root)"

home="$(mktemp -d)"
stub_dir="$(mktemp -d)"
trap 'rm -rf -- "$home" "$stub_dir"' EXIT
HOME="$home"
export HOME

cat >"$stub_dir/git" <<'EOF'
#!/bin/sh
set -eu
{
    printf 'argv='
    printf ' %s' "$@"
    printf '\n'
    printf 'GIT_ASKPASS=%s\n' "${GIT_ASKPASS-}"
} >>"${GIT_STUB_LOG:?}"
dest=''
url=''
seen_clone=0
for arg in "$@"; do
    case "$arg" in
        clone) seen_clone=1; continue ;;
    esac
    if [ "$seen_clone" -eq 1 ] && [ "$arg" != '--depth=1' ] && [ "$arg" != '--' ] && [ "${arg#-}" = "$arg" ]; then
        if [ -z "$url" ]; then
            url="$arg"
        else
            dest="$arg"
        fi
    fi
done
if [ -n "${GIT_STUB_FAIL-}" ]; then
    exit 1
fi
[ -n "$dest" ] || exit 1
mkdir -p "$dest/.git"
printf '%s\n' "$url" >"$dest/.git/stub-url"
EOF
chmod 755 "$stub_dir/git"
PATH="$stub_dir:$PATH"
export PATH

unset GIT_WORKSPACES || true
unset GIT_WORKSPACES_TOKEN || true
enable_git_workspaces || fail 'enable_git_workspaces failed when GIT_WORKSPACES was unset'
[[ ! -e "$home/workspaces" ]] || fail 'workspaces directory was created without GIT_WORKSPACES'

GIT_STUB_LOG="$stub_dir/git.log"
export GIT_STUB_LOG
: >"$GIT_STUB_LOG"

GIT_WORKSPACES=$'https://github.com/org/proj-a\nmy-app=https://github.com/org/proj-c\norg/priv'
export GIT_WORKSPACES
enable_git_workspaces || fail 'enable_git_workspaces failed for valid public repos'
[[ -d "$home/workspaces/proj-a/.git" ]] || fail 'proj-a was not cloned'
[[ -d "$home/workspaces/my-app/.git" ]] || fail 'my-app was not cloned'
[[ -d "$home/workspaces/org/priv/.git" ]] || fail 'org/priv was not cloned'
[[ "$(cat "$home/workspaces/org/priv/.git/stub-url")" == 'https://github.com/org/priv' ]] ||
    fail 'org/priv was cloned from the wrong URL'
[[ "$(cat "$home/workspaces/proj-a/.git/stub-url")" == 'https://github.com/org/proj-a' ]] ||
    fail 'proj-a was cloned from the wrong URL'
grep -Fq 'clone --depth=1 -- https://github.com/org/proj-a' "$GIT_STUB_LOG" ||
    fail "clone argv was unexpected: $(cat "$GIT_STUB_LOG")"

: >"$GIT_STUB_LOG"
enable_git_workspaces || fail 'enable_git_workspaces was not idempotent'
if grep -q clone "$GIT_STUB_LOG"; then
    fail 'existing git workspaces were cloned again'
fi

mkdir -p "$home/workspaces/blocked"
printf 'keep\n' >"$home/workspaces/blocked/file"
GIT_WORKSPACES='blocked=https://github.com/org/blocked'
export GIT_WORKSPACES
: >"$GIT_STUB_LOG"
output="$(enable_git_workspaces 2>&1)" || fail 'enable_git_workspaces failed when dest already exists'
[[ "$output" == *'already exists'* ]] || fail "missing already-exists warning: $output"
[[ -f "$home/workspaces/blocked/file" ]] || fail 'existing workspace contents were disturbed'
if grep -q clone "$GIT_STUB_LOG"; then
    fail 'git clone ran against a blocked destination'
fi

GIT_WORKSPACES='secret-app=https://github.com/org/private'
GIT_WORKSPACES_TOKEN='super-secret-token'
export GIT_WORKSPACES GIT_WORKSPACES_TOKEN
: >"$GIT_STUB_LOG"
enable_git_workspaces || fail 'enable_git_workspaces failed with a token'
[[ -d "$home/workspaces/secret-app/.git" ]] || fail 'private workspace was not cloned'
if grep -Fq 'super-secret-token' "$GIT_STUB_LOG"; then
    fail 'token appeared on the git command line or stub log'
fi
# shellcheck disable=SC2016
grep -Fq 'credential.helper=!f() { echo username=x-access-token; echo password=$GIT_WORKSPACES_TOKEN; }; f' "$GIT_STUB_LOG" ||
    fail "token clone did not use the env credential helper: $(cat "$GIT_STUB_LOG")"
# shellcheck disable=SC2016
[[ "$(git_workspace_credential_helper)" == '!f() { echo username=x-access-token; echo password=$GIT_WORKSPACES_TOKEN; }; f' ]] ||
    fail 'credential helper did not keep the token in the environment'

GIT_WORKSPACES='fail-me=https://github.com/org/fail-me'
unset GIT_WORKSPACES_TOKEN || true
export GIT_WORKSPACES
GIT_STUB_FAIL=1
export GIT_STUB_FAIL
: >"$GIT_STUB_LOG"
output="$(enable_git_workspaces 2>&1)" || fail 'enable_git_workspaces did not survive a clone failure'
[[ "$output" == *'git clone failed for fail-me'* ]] || fail "missing clone-failure warning: $output"
[[ ! -e "$home/workspaces/fail-me" ]] || fail 'failed clone left a partial workspace'
unset GIT_STUB_FAIL

printf 'git workspaces contract: PASS\n'
