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
expect_validate_ok 'lirtual/.grok'
expect_validate_ok '.grok=lirtual/.grok'
expect_validate_ok 'workspaces/notes=org/notes'

expect_validate_fail $'https://github.com/org/a\nhttps://github.com/other/a.git' 'duplicate name'
expect_validate_fail $'https://github.com/org/a\norg/a' 'duplicate name'
expect_validate_fail $'app=https://github.com/org/a\napp=https://github.com/org/b' 'duplicate name'
expect_validate_fail $'org/priv\norg/priv.git' 'duplicate name'
expect_validate_ok $'org=https://github.com/acme/org\norg/priv'
expect_validate_fail $'org=https://github.com/acme/org\norg/priv=https://github.com/acme/priv' 'conflicts'
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
expect_validate_fail 'rclone=org/foo' 'destination is invalid'
expect_validate_fail 'rclone/foo=org/foo' 'destination is invalid'

GIT_WORKSPACES=$'# keep\nhttps://github.com/org/proj-a.git\nmy-app=https://github.com/org/proj-c\norg/priv'
mapfile -t parsed < <(parse_git_workspaces)
(( ${#parsed[@]} == 3 )) || fail "parsed ${#parsed[@]} workspaces, expected 3"
[[ "${parsed[0]}" == $'proj-a\thttps://github.com/org/proj-a.git' ]] || fail "first workspace was ${parsed[0]}"
[[ "${parsed[1]}" == $'my-app\thttps://github.com/org/proj-c' ]] || fail "second workspace was ${parsed[1]}"
[[ "${parsed[2]}" == $'priv\thttps://github.com/org/priv' ]] || fail "shorthand workspace was ${parsed[2]}"

GIT_WORKSPACES='lirtual/.grok'
mapfile -t parsed < <(parse_git_workspaces)
[[ "${parsed[0]}" == $'.grok\thttps://github.com/lirtual/.grok' ]] ||
    fail "lirtual/.grok parsed as ${parsed[0]}"

[[ "$(git_workspace_name_from_url 'https://github.com/org/proj-b.git')" == 'proj-b' ]] ||
    fail 'name from URL did not use the repo name'
[[ "$(git_workspace_name_from_url 'https://github.com/autoactions/debug-session')" == 'debug-session' ]] ||
    fail 'name from URL did not use the last path segment'
[[ "$(git_workspace_name_from_url 'https://gitlab.example.com:8443/group/sub/repo.git')" == 'repo' ]] ||
    fail 'name from URL did not use the last path segment of a nested repo'
[[ "$(git_workspace_name_from_shorthand 'lirtual/.grok')" == '.grok' ]] ||
    fail 'name from shorthand did not use the repo name'
[[ "$(git_workspace_name_from_shorthand 'org/priv.git')" == 'priv' ]] ||
    fail 'name from shorthand did not strip .git'
[[ "$(workspace_root)" == "${HOME%/}" ]] ||
    fail "workspace_root was $(workspace_root)"
[[ "$(git_workspace_destination 'proj-a')" == "${HOME%/}/proj-a" ]] ||
    fail "destination for proj-a was $(git_workspace_destination 'proj-a')"
[[ "$(git_workspace_destination '.grok')" == "${HOME%/}/.grok" ]] ||
    fail "destination for .grok was $(git_workspace_destination '.grok')"
[[ "$(git_workspace_normalize_url 'https://github.com/org/proj.git/')" == 'https://github.com/org/proj' ]] ||
    fail 'URL normalization did not strip .git and trailing slash'

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

dest_c=''
while [ $# -gt 0 ]; do
    case "$1" in
        -C)
            dest_c="$2"
            shift 2
            ;;
        -c)
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

cmd="${1:-}"
if [ $# -gt 0 ]; then
    shift
fi

case "$cmd" in
    clone)
        dest=''
        url=''
        for arg in "$@"; do
            if [ "$arg" = '--depth=1' ] || [ "$arg" = '--' ] || [ "${arg#-}" != "$arg" ]; then
                continue
            fi
            if [ -z "$url" ]; then
                url="$arg"
            else
                dest="$arg"
            fi
        done
        if [ -n "${GIT_STUB_FAIL-}" ]; then
            exit 1
        fi
        [ -n "$dest" ] || exit 1
        mkdir -p "$dest/.git"
        printf '%s\n' "$url" >"$dest/.git/stub-url"
        ;;
    remote)
        if [ "${1:-}" = get-url ]; then
            if [ -f "$dest_c/.git/stub-url" ]; then
                cat "$dest_c/.git/stub-url"
            else
                printf '%s\n' 'https://github.com/org/unknown'
            fi
        fi
        ;;
    config)
        key=''
        get=0
        for arg in "$@"; do
            case "$arg" in
                --get) get=1 ;;
                user.name|user.email) key="$arg" ;;
            esac
        done
        mkdir -p "$dest_c/.git"
        if [ "$get" -eq 1 ]; then
            if [ -f "$dest_c/.git/config-$key" ]; then
                cat "$dest_c/.git/config-$key"
                exit 0
            fi
            exit 1
        fi
        if [ -n "$key" ]; then
            printf '%s\n' "${2:-}" >"$dest_c/.git/config-$key"
        fi
        ;;
    add)
        mkdir -p "$dest_c/.git"
        printf 'added\n' >>"$dest_c/.git/events"
        ;;
    status)
        if [ -f "$dest_c/.git/dirty" ]; then
            printf ' M file\n'
        fi
        ;;
    commit)
        mkdir -p "$dest_c/.git"
        printf 'committed\n' >>"$dest_c/.git/events"
        rm -f "$dest_c/.git/dirty"
        ;;
    fetch)
        mkdir -p "$dest_c/.git"
        if [ -n "${GIT_STUB_FETCH_FAIL-}" ]; then
            exit 1
        fi
        for arg in "$@"; do
            if [ "$arg" = '--unshallow' ]; then
                printf 'unshallow\n' >>"$dest_c/.git/events"
            fi
        done
        printf 'fetched\n' >>"$dest_c/.git/events"
        ;;
    rebase)
        mkdir -p "$dest_c/.git"
        if [ "${1:-}" = --abort ]; then
            exit 0
        fi
        if [ -n "${GIT_STUB_REBASE_FAIL-}" ]; then
            exit 1
        fi
        printf 'rebased\n' >>"$dest_c/.git/events"
        ;;
    push)
        mkdir -p "$dest_c/.git"
        if [ -n "${GIT_STUB_PUSH_FAIL-}" ]; then
            exit 1
        fi
        printf 'pushed\n' >>"$dest_c/.git/events"
        ;;
    *)
        exit 0
        ;;
esac
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
[[ -d "$home/proj-a/.git" ]] || fail 'proj-a was not cloned'
[[ -d "$home/my-app/.git" ]] || fail 'my-app was not cloned'
[[ -d "$home/priv/.git" ]] || fail 'priv was not cloned'
[[ ! -e "$home/workspaces" ]] || fail 'clone still used the workspaces directory'
[[ "$(cat "$home/priv/.git/stub-url")" == 'https://github.com/org/priv' ]] ||
    fail 'priv was cloned from the wrong URL'
[[ "$(cat "$home/proj-a/.git/stub-url")" == 'https://github.com/org/proj-a' ]] ||
    fail 'proj-a was cloned from the wrong URL'
grep -Fq 'clone --depth=1 -- https://github.com/org/proj-a' "$GIT_STUB_LOG" ||
    fail "clone argv was unexpected: $(cat "$GIT_STUB_LOG")"

: >"$GIT_STUB_LOG"
enable_git_workspaces || fail 'enable_git_workspaces was not idempotent'
if grep -q clone "$GIT_STUB_LOG"; then
    fail 'existing git workspaces were cloned again'
fi
grep -Fq 'already present' <<<"$(enable_git_workspaces 2>&1)" ||
    fail 'same-remote workspace was not treated as already present'

mkdir -p "$home/other/.git"
printf 'https://github.com/org/other\n' >"$home/other/.git/stub-url"
GIT_WORKSPACES='other=https://github.com/org/expected'
export GIT_WORKSPACES
: >"$GIT_STUB_LOG"
output="$(enable_git_workspaces 2>&1)" || fail 'enable_git_workspaces failed for a different remote'
[[ "$output" == *'different git remote'* ]] || fail "missing different-remote warning: $output"
if grep -q clone "$GIT_STUB_LOG"; then
    fail 'git clone ran against a different-remote destination'
fi
[[ "$(cat "$home/other/.git/stub-url")" == 'https://github.com/org/other' ]] ||
    fail 'different-remote destination was rewritten'

mkdir -p "$home/blocked"
printf 'keep\n' >"$home/blocked/file"
GIT_WORKSPACES='blocked=https://github.com/org/blocked'
export GIT_WORKSPACES
: >"$GIT_STUB_LOG"
output="$(enable_git_workspaces 2>&1)" || fail 'enable_git_workspaces failed when dest already exists'
[[ "$output" == *'already exists'* ]] || fail "missing already-exists warning: $output"
[[ -f "$home/blocked/file" ]] || fail 'existing workspace contents were disturbed'
if grep -q clone "$GIT_STUB_LOG"; then
    fail 'git clone ran against a blocked destination'
fi

GIT_WORKSPACES='secret-app=https://github.com/org/private'
GIT_WORKSPACES_TOKEN='super-secret-token'
export GIT_WORKSPACES GIT_WORKSPACES_TOKEN
: >"$GIT_STUB_LOG"
enable_git_workspaces || fail 'enable_git_workspaces failed with a token'
[[ -d "$home/secret-app/.git" ]] || fail 'private workspace was not cloned'
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
[[ ! -e "$home/fail-me" ]] || fail 'failed clone left a partial workspace'
unset GIT_STUB_FAIL

GIT_WORKSPACES='sync-me=https://github.com/org/sync-me'
export GIT_WORKSPACES
mkdir -p "$home/sync-me/.git"
printf 'https://github.com/org/sync-me\n' >"$home/sync-me/.git/stub-url"
printf '1\n' >"$home/sync-me/.git/dirty"
: >"$GIT_STUB_LOG"
sync_git_workspaces || fail 'sync_git_workspaces failed for a dirty workspace'
[[ -f "$home/sync-me/.git/events" ]] || fail 'sync did not record git events'
grep -Fxq added "$home/sync-me/.git/events" || fail 'sync did not git add'
grep -Fxq committed "$home/sync-me/.git/events" || fail 'sync did not commit dirty files'
grep -Fxq fetched "$home/sync-me/.git/events" || fail 'sync did not fetch'
grep -Fxq rebased "$home/sync-me/.git/events" || fail 'sync did not rebase'
grep -Fxq pushed "$home/sync-me/.git/events" || fail 'sync did not push'
if grep -Fq 'super-secret-token' "$GIT_STUB_LOG"; then
    fail 'token appeared during sync'
fi

: >"$home/sync-me/.git/events"
: >"$GIT_STUB_LOG"
output="$(sync_git_workspaces 2>&1)" || fail 'sync_git_workspaces failed when unchanged'
[[ "$output" == *'unchanged'* ]] || fail "missing unchanged log: $output"
if grep -Fxq committed "$home/sync-me/.git/events"; then
    fail 'unchanged workspace was committed'
fi
grep -Fxq pushed "$home/sync-me/.git/events" || fail 'unchanged workspace was not pushed'

GIT_STUB_PUSH_FAIL=1
export GIT_STUB_PUSH_FAIL
: >"$GIT_STUB_LOG"
output="$(sync_git_workspaces 2>&1)" || fail 'sync_git_workspaces did not survive a push failure'
[[ "$output" == *'git push failed for sync-me'* ]] || fail "missing push-failure warning: $output"
unset GIT_STUB_PUSH_FAIL

printf 'git workspaces contract: PASS\n'
