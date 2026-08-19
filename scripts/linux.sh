#!/usr/bin/env bash
set -euo pipefail

log() {
    printf '[debug-session] %s\n' "$*"
}

warn() {
    printf '::warning::%s\n' "$*"
}

require_env() {
    local name="$1"
    [[ -n "${!name:-}" ]] || {
        printf 'Required environment variable %s is empty\n' "$name" >&2
        return 1
    }
}

validate_session_password() {
    require_env SESSION_PASSWORD
    (( ${#SESSION_PASSWORD} >= 8 )) || {
        printf 'SESSION_PASSWORD must contain at least 8 characters\n' >&2
        return 1
    }
    [[ "$SESSION_PASSWORD" != *$'\n'* && "$SESSION_PASSWORD" != *$'\r'* ]] || {
        printf 'SESSION_PASSWORD must be a single line\n' >&2
        return 1
    }
}

validate_inputs() {
    require_env ACCESS_PROFILE
    require_env SESSION_PROFILE
    require_env SESSION_DEADLINE_EPOCH

    case "$ACCESS_PROFILE" in
        mini|full) ;;
        *)
            printf 'ACCESS_PROFILE must be mini or full\n' >&2
            return 1
            ;;
    esac

    case "$SESSION_PROFILE" in
        core|developer) ;;
        *)
            printf 'SESSION_PROFILE must be core or developer\n' >&2
            return 1
            ;;
    esac

    [[ "$SESSION_DEADLINE_EPOCH" =~ ^[0-9]+$ ]] || {
        printf 'SESSION_DEADLINE_EPOCH must be a Unix timestamp\n' >&2
        return 1
    }
    (( SESSION_DEADLINE_EPOCH > $(date +%s) )) || {
        printf 'SESSION_DEADLINE_EPOCH must be in the future\n' >&2
        return 1
    }

    validate_session_password
    validate_rclone_home_links
    validate_git_workspaces
}

apt_prerequisites_present() {
    command -v curl >/dev/null 2>&1 &&
        command -v gpg >/dev/null 2>&1 &&
        [[ -f /etc/ssl/certs/ca-certificates.crt ]]
}

run_apt_update() {
    sudo apt-get update -o Acquire::Retries=3
}

run_apt_install() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Acquire::Retries=3 "$@"
}

ensure_apt_prerequisites() {
    if apt_prerequisites_present; then
        return 0
    fi

    run_apt_update
    run_apt_install ca-certificates curl gnupg
}

configure_tailscale_repository() {
    local codename
    codename="$(awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
    [[ -n "$codename" ]] || {
        printf 'The Ubuntu release codename is unavailable\n' >&2
        return 1
    }

    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" |
        sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" |
        sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
}

core_package_present() {
    command -v "$1" >/dev/null 2>&1
}

ensure_zsh_login_shell() {
    local zsh_path
    zsh_path="$(command -v zsh)" || {
        printf 'zsh is not installed\n' >&2
        return 1
    }
    sudo chsh -s "$zsh_path" "$(id -un)"

    # A missing ~/.zshrc makes interactive zsh run zsh-newuser-install.
    if [[ ! -f "$HOME/.zshrc" ]]; then
        printf '%s\n' '# debug-session zsh login shell' >"$HOME/.zshrc" || return 1
    fi
    # /etc/zsh/zshrc runs compinit before ~/.zshrc and prompts on
    # group-writable completion dirs (common on GitHub-hosted runners).
    if [[ ! -f "$HOME/.zshenv" ]] || ! grep -Fq 'skip_global_compinit' "$HOME/.zshenv"; then
        printf '%s\n' 'skip_global_compinit=1' >>"$HOME/.zshenv" || return 1
    fi
}

ensure_core_packages() {
    local need_sshd=0
    local need_tailscale=0
    local need_zsh=0
    local need_git=0
    core_package_present sshd || need_sshd=1
    core_package_present tailscale || need_tailscale=1
    core_package_present zsh || need_zsh=1
    core_package_present git || need_git=1

    if (( need_sshd == 0 && need_tailscale == 0 && need_zsh == 0 && need_git == 0 )); then
        return 0
    fi

    if (( need_tailscale )); then
        configure_tailscale_repository
    fi
    run_apt_update
    local -a packages=()
    (( need_sshd )) && packages+=(openssh-server)
    (( need_tailscale )) && packages+=(tailscale)
    (( need_zsh )) && packages+=(zsh)
    (( need_git )) && packages+=(git)
    run_apt_install "${packages[@]}"
}

ensure_post_core_packages() {
    local -a packages=()
    if rclone_config_present; then
        if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
            packages+=(fuse3)
        fi
        command -v unzip >/dev/null 2>&1 || packages+=(unzip)
        command -v bindfs >/dev/null 2>&1 || packages+=(bindfs)
    fi
    if [[ "$SESSION_PROFILE" == developer ]] && ! command -v npm >/dev/null 2>&1; then
        packages+=(nodejs npm)
    fi
    if (( ${#packages[@]} == 0 )); then
        return 0
    fi
    run_apt_update
    run_apt_install "${packages[@]}"
}

assert_private_listener() {
    local port="$1"
    local expected_ip="$2"
    local listeners
    listeners="$(sudo ss -H -ltn "sport = :$port" | awk '{print $4}')"
    [[ -n "$listeners" ]] || {
        printf 'No listener reached the ready state on TCP port %s\n' "$port" >&2
        return 1
    }

    local listener
    while IFS= read -r listener; do
        case "$listener" in
            "$expected_ip:$port"|"[$expected_ip]:$port") ;;
            *)
                printf 'TCP port %s is listening outside the Tailscale address: %s\n' "$port" "$listener" >&2
                return 1
                ;;
        esac
    done <<< "$listeners"
}

require_oauth_session_inputs() {
    require_env TAILSCALE_OAUTH_CLIENT_ID
    require_env TAILSCALE_OAUTH_CLIENT_SECRET
    require_env TAILSCALE_HOSTNAME
    require_env TAILSCALE_TAGS

    local tag
    local IFS=','
    for tag in $TAILSCALE_TAGS; do
        [[ "$tag" =~ ^tag:[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
            printf 'TAILSCALE_TAGS must be a comma-separated list of Tailscale tags such as tag:debug-session\n' >&2
            return 1
        }
    done
}

request_oauth_access_token() {
    local response
    response="$(curl -fsS --connect-timeout 30 \
        -d "client_id=${TAILSCALE_OAUTH_CLIENT_ID}" \
        -d "client_secret=${TAILSCALE_OAUTH_CLIENT_SECRET}" \
        -d 'scope=devices:core' \
        'https://api.tailscale.com/api/v2/oauth/token')" || {
        printf 'Could not exchange the Tailscale OAuth client for an access token\n' >&2
        return 1
    }

    python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
token = payload.get("access_token") or ""
if not token:
    sys.exit(1)
print(token)
' <<<"$response" || {
        printf 'The Tailscale OAuth token response did not include an access token\n' >&2
        return 1
    }
}

list_reserved_hostname_leftovers() {
    local reserved="$1"
    local exclude="${2:-}"
    python3 -c '
import json, re, sys

reserved = sys.argv[1]
exclude = sys.argv[2]
payload = json.load(sys.stdin)
devices = payload.get("devices") or []
pattern = re.compile("^" + re.escape(reserved) + r"(?:-\d+)?$")
for device in devices:
    if not isinstance(device, dict):
        continue
    name = device.get("hostname") or ""
    if not pattern.fullmatch(name):
        continue
    node_id = device.get("nodeId") or device.get("id")
    if node_id is None or node_id == "":
        continue
    node_id = str(node_id)
    identifiers = {
        str(device.get("nodeId") or ""),
        str(device.get("id") or ""),
        node_id,
    }
    if exclude and exclude in identifiers:
        continue
    print(f"{node_id}\t{name}")
' "$reserved" "$exclude"
}

delete_tailscale_device() {
    local access_token="$1"
    local device_id="$2"
    local device_name="$3"
    local status
    status="$(curl -sS --connect-timeout 30 -o /dev/null -w '%{http_code}' \
        -X DELETE \
        -H "Authorization: Bearer ${access_token}" \
        "https://api.tailscale.com/api/v2/device/${device_id}")" || {
        printf 'Could not delete leftover Tailscale device %s\n' "$device_name" >&2
        return 1
    }
    case "$status" in
        200|204|404)
            log "Removed leftover Tailscale device ${device_name}"
            ;;
        *)
            printf 'Could not delete leftover Tailscale device %s (HTTP %s)\n' "$device_name" "$status" >&2
            return 1
            ;;
    esac
}

reclaim_reserved_hostname() {
    local access_token="$1"
    local exclude="${2:-}"
    local payload device_id device_name
    payload="$(curl -fsS --connect-timeout 30 \
        -H "Authorization: Bearer ${access_token}" \
        'https://api.tailscale.com/api/v2/tailnet/-/devices')" || {
        printf 'Could not list Tailscale devices\n' >&2
        return 1
    }

    while IFS=$'\t' read -r device_id device_name; do
        [[ -n "$device_id" ]] || continue
        delete_tailscale_device "$access_token" "$device_id" "$device_name"
    done < <(list_reserved_hostname_leftovers "$TAILSCALE_HOSTNAME" "$exclude" <<<"$payload")
}

read_self_tailscale_identity() {
    python3 -c '
import json, sys
payload = json.load(sys.stdin)
self_status = payload.get("Self") or {}
hostname = self_status.get("HostName") or ""
node_id = self_status.get("ID") or ""
if not hostname or not node_id:
    sys.exit(1)
print(f"{hostname}\t{node_id}")
'
}

join_private_network() {
    local access_token="$1"
    local auth_key="${TAILSCALE_OAUTH_CLIENT_SECRET}?ephemeral=true&preauthorized=true"
    sudo tailscale up --auth-key "$auth_key" \
        --advertise-tags "$TAILSCALE_TAGS" \
        --hostname "$TAILSCALE_HOSTNAME"

    local identity current_hostname self_id
    identity="$(read_self_tailscale_identity < <(tailscale status --json))" || {
        printf 'Tailscale did not report this node identity\n' >&2
        return 1
    }
    IFS=$'\t' read -r current_hostname self_id <<<"$identity"

    if [[ "$current_hostname" != "$TAILSCALE_HOSTNAME" ]]; then
        reclaim_reserved_hostname "$access_token" "$self_id"
        sudo tailscale set --hostname "$TAILSCALE_HOSTNAME"
        identity="$(read_self_tailscale_identity < <(tailscale status --json))" || {
            printf 'Tailscale did not report this node identity\n' >&2
            return 1
        }
        IFS=$'\t' read -r current_hostname self_id <<<"$identity"
    fi

    if [[ "$current_hostname" != "$TAILSCALE_HOSTNAME" ]]; then
        printf 'Could not claim reserved Tailscale name %s; this node is %s\n' \
            "$TAILSCALE_HOSTNAME" "$current_hostname" >&2
        return 1
    fi

    reclaim_reserved_hostname "$access_token" "$self_id"
}

enable_core_session() {
    log 'begin Core Session'
    validate_inputs
    require_oauth_session_inputs

    ensure_apt_prerequisites
    local access_token
    access_token="$(request_oauth_access_token)"
    reclaim_reserved_hostname "$access_token"

    sudo systemctl stop ssh 2>/dev/null || true
    sudo systemctl mask --runtime ssh.service ssh.socket >/dev/null
    ensure_core_packages

    sudo systemctl enable --now tailscaled
    join_private_network "$access_token"

    local tailscale_ip
    tailscale_ip="$(tailscale ip -4)"
    [[ -n "$tailscale_ip" ]] || {
        printf 'Tailscale did not assign an IPv4 address\n' >&2
        return 1
    }

    local session_user
    session_user="$(id -un)"
    printf '%s:%s\n' "$session_user" "$SESSION_PASSWORD" | sudo chpasswd
    touch "$HOME/.hushlogin"
    ensure_zsh_login_shell
    printf 'PasswordAuthentication yes\nPermitRootLogin no\nListenAddress %s\n' "$tailscale_ip" |
        sudo tee /etc/ssh/sshd_config.d/00-debug-session.conf >/dev/null
    sudo install -d -o root -g root -m 0755 /run/sshd
    sudo sshd -t
    sudo systemctl unmask --runtime ssh.service ssh.socket >/dev/null
    sudo systemctl enable --now ssh
    sudo systemctl restart ssh

    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    sudo systemctl is-active --quiet tailscaled
    sudo systemctl is-active --quiet ssh
    assert_private_listener 22 "$tailscale_ip"

    local stop_session
    stop_session="$(mktemp)"
    cat > "$stop_session" <<'EOF'
#!/bin/sh
set -eu
touch "$HOME/STOP_SESSION"
EOF
    sudo install -m 0755 "$stop_session" /usr/local/bin/stop-session
    rm -f -- "$stop_session"

    log "Linux $ACCESS_PROFILE Core Session ready (${SECONDS}s elapsed); Developer Profile provisioning may continue"
    printf 'SSH: %s@%s\n' "$session_user" "$tailscale_ip"
    printf 'Stop Signal: run stop-session\n'
}

enable_xfce_rdp() {
    local tailscale_ip
    tailscale_ip="$(tailscale ip -4)" || true
    if [[ -z "$tailscale_ip" ]]; then
        warn 'Linux RDP Access Channel is unavailable; Tailscale did not assign an IPv4 address'
        return 1
    fi

    sudo systemctl stop xrdp 2>/dev/null || true
    sudo systemctl mask --runtime xrdp.service >/dev/null || true
    if ! run_apt_install dbus-x11 xorg xfce4 xrdp; then
        warn 'Linux RDP Access Channel failed to install; SSH remains available'
        return 1
    fi

    if ! printf '%s\n' 'startxfce4' > "$HOME/.xsession" ||
        ! sudo adduser xrdp ssl-cert ||
        ! sudo sed -i "0,/^port=.*/s|^port=.*|port=tcp://${tailscale_ip}:3389|" /etc/xrdp/xrdp.ini ||
        ! sudo systemctl unmask --runtime xrdp.service >/dev/null ||
        ! sudo systemctl enable --now xrdp ||
        ! sudo systemctl restart xrdp ||
        ! sudo systemctl is-active --quiet xrdp ||
        ! assert_private_listener 3389 "$tailscale_ip"; then
        warn 'Linux RDP Access Channel did not become ready; SSH remains available'
        return 1
    fi

    log 'Linux full Access Channel ready'
    printf 'RDP: %s:3389\n' "$tailscale_ip"
}

linux_herdr_target() {
    case "$(uname -m)" in
        x86_64 | amd64)
            printf '%s\n' 'linux-x86_64'
            ;;
        aarch64 | arm64)
            printf '%s\n' 'linux-aarch64'
            ;;
        *)
            printf 'Unsupported Linux architecture for herdr: %s\n' "$(uname -m)" >&2
            return 1
            ;;
    esac
}

read_herdr_release() {
    local target="$1"
    python3 -c '
import json, sys
target = sys.argv[1]
payload = json.load(sys.stdin)
assets = payload.get("assets") or {}
checksums = payload.get("sha256") or {}
url = assets.get(target) or ""
digest = (checksums.get(target) or "").lower()
if not url or len(digest) != 64:
    sys.exit(1)
print(f"{url}\t{digest}")
' "$target"
}

install_herdr() {
    if command -v herdr >/dev/null 2>&1; then
        return 0
    fi

    local target manifest url digest archive actual
    target="$(linux_herdr_target)" || return 1
    manifest="$(curl -fsSL --retry 3 --retry-all-errors 'https://herdr.dev/latest.json')" || return 1
    IFS=$'\t' read -r url digest < <(read_herdr_release "$target" <<<"$manifest") || return 1
    [[ -n "$url" && ${#digest} -eq 64 ]] || return 1

    archive="$(mktemp)" || return 1
    if ! curl -fsSL --retry 3 --retry-all-errors "$url" -o "$archive"; then
        rm -f -- "$archive"
        return 1
    fi
    actual="$(sha256sum <"$archive" | awk '{ print tolower($1) }')"
    if [[ "$actual" != "$digest" ]]; then
        rm -f -- "$archive"
        return 1
    fi
    if ! sudo install -m 0755 "$archive" /usr/local/bin/herdr; then
        rm -f -- "$archive"
        return 1
    fi
    rm -f -- "$archive"
}

install_oh_my_zsh() {
    command -v git >/dev/null 2>&1 || return
    command -v zsh >/dev/null 2>&1 || return

    umask 022
    local install_dir="$HOME/.oh-my-zsh"
    if [[ ! -d "$install_dir" ]]; then
        local staging_dir
        staging_dir="$(mktemp -d)" || return
        if ! git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$staging_dir/oh-my-zsh"; then
            rm -rf -- "$staging_dir"
            return 1
        fi
        if ! mv "$staging_dir/oh-my-zsh" "$install_dir"; then
            rm -rf -- "$staging_dir"
            return 1
        fi
        rmdir "$staging_dir"
    fi
    chmod -R go-w "$install_dir" || return

    if [[ ! -f "$HOME/.zshrc" ]]; then
        cp "$install_dir/templates/zshrc.zsh-template" "$HOME/.zshrc" || return
    elif ! grep -Fq 'oh-my-zsh.sh' "$HOME/.zshrc"; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.pre-oh-my-zsh" || return
        cp "$install_dir/templates/zshrc.zsh-template" "$HOME/.zshrc" || return
    fi
    if ! grep -Fq 'ZSH_DISABLE_COMPFIX' "$HOME/.zshrc"; then
        printf '%s\n' 'ZSH_DISABLE_COMPFIX=true' | cat - "$HOME/.zshrc" >"$HOME/.zshrc.debug-session" || return
        mv "$HOME/.zshrc.debug-session" "$HOME/.zshrc" || return
    fi
    # /etc/zsh/zshrc runs compinit before ~/.zshrc; this must be in ~/.zshenv.
    if [[ ! -f "$HOME/.zshenv" ]] || ! grep -Fq 'skip_global_compinit' "$HOME/.zshenv"; then
        printf '%s\n' 'skip_global_compinit=1' >>"$HOME/.zshenv" || return
    fi
}

install_developer_profile() {
    local -a failed=()

    if ! command -v npm >/dev/null 2>&1; then
        failed+=(codex grok)
    else
        if ! command -v codex >/dev/null 2>&1 && ! npm install --global @openai/codex; then
            failed+=(codex)
        fi
        if ! command -v grok >/dev/null 2>&1 && ! npm install --global @xai-official/grok; then
            failed+=(grok)
        fi
    fi

    if ! install_herdr; then
        failed+=(herdr)
    fi

    if ! install_oh_my_zsh; then
        failed+=(ohmyzsh)
    fi

    if (( ${#failed[@]} > 0 )); then
        warn "Developer Profile is incomplete; failed tools: ${failed[*]}"
    else
        log "Linux Developer Profile complete (${SECONDS}s elapsed)"
    fi
}

wait_for_stop() {
    local stop_file="$HOME/STOP_SESSION"
    local tailscale_ip
    tailscale_ip="$(tailscale ip -4)"

    printf 'SSH: %s@%s\n' "$(id -un)" "$tailscale_ip"
    if [[ "$ACCESS_PROFILE" == full ]] && sudo systemctl is-active --quiet xrdp; then
        printf 'RDP: %s:3389\n' "$tailscale_ip"
    fi
    printf 'Stop Signal: run stop-session\n'
    log 'Debug Session provisioning finished; waiting for the Stop Signal or Session Deadline'

    while (( $(date +%s) < SESSION_DEADLINE_EPOCH )); do
        if [[ -e "$stop_file" ]]; then
            log 'Stop Signal received'
            return 0
        fi
        sleep 15
    done
    log 'Session Deadline reached'
}

rclone_config_present() {
    [[ -n "${RCLONE_CONFIG:-}" ]]
}

rclone_config_path() {
    printf '%s/.config/rclone/rclone.conf' "$HOME"
}

rclone_cloud_root() {
    printf '%s/rclone' "$HOME"
}

rclone_log_dir() {
    printf '%s/.cache/debug-session' "$HOME"
}

rclone_remote_mountable() {
    local name="$1"
    [[ -n "$name" && "$name" != '.' && "$name" != '..' ]] || return 1
    [[ "$name" != */* && "$name" != *\\* ]] || return 1
    return 0
}

write_rclone_config() {
    local config_dir config_path
    config_path="$(rclone_config_path)"
    config_dir="$(dirname "$config_path")"
    mkdir -p "$config_dir"
    chmod 700 "$config_dir"
    umask 077
    printf '%s\n' "$RCLONE_CONFIG" >"$config_path"
    chmod 600 "$config_path"
    # rclone treats RCLONE_CONFIG as a file path, not the file contents.
    export RCLONE_CONFIG="$config_path"
}

list_rclone_remotes_from_config() {
    python3 -c '
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
except OSError:
    sys.exit(1)

current = None
has_type = False

def flush():
    if current and has_type:
        print(current)

for raw in lines:
    line = raw.strip()
    if not line or line.startswith("#") or line.startswith(";"):
        continue
    if line.startswith("[") and line.endswith("]"):
        flush()
        current = line[1:-1].strip()
        has_type = False
        continue
    key = line.split("=", 1)[0].strip().lower()
    if key == "type":
        has_type = True
flush()
' "$(rclone_config_path)"
}

linux_rclone_archive_url() {
    case "$(uname -m)" in
        x86_64 | amd64)
            printf '%s\n' 'https://downloads.rclone.org/rclone-current-linux-amd64.zip'
            ;;
        aarch64 | arm64)
            printf '%s\n' 'https://downloads.rclone.org/rclone-current-linux-arm64.zip'
            ;;
        *)
            printf 'Unsupported Linux architecture for rclone: %s\n' "$(uname -m)" >&2
            return 1
            ;;
    esac
}

ensure_rclone_and_fuse() {
    local -a pkgs=()
    if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
        pkgs+=(fuse3)
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        pkgs+=(unzip)
    fi
    if ! command -v bindfs >/dev/null 2>&1; then
        pkgs+=(bindfs)
    fi
    if (( ${#pkgs[@]} > 0 )); then
        run_apt_update
        run_apt_install "${pkgs[@]}"
    fi

    if command -v rclone >/dev/null 2>&1; then
        return 0
    fi

    local url archive staging bin
    url="$(linux_rclone_archive_url)" || return 1
    archive="$(mktemp)"
    staging="$(mktemp -d)"
    if ! curl -fsSL "$url" -o "$archive"; then
        rm -f -- "$archive"
        rm -rf -- "$staging"
        return 1
    fi
    if ! unzip -q "$archive" -d "$staging"; then
        rm -f -- "$archive"
        rm -rf -- "$staging"
        return 1
    fi
    bin="$(find "$staging" -type f -name rclone -print -quit)"
    if [[ -z "$bin" ]] || ! sudo install -m 0755 "$bin" /usr/local/bin/rclone; then
        rm -f -- "$archive"
        rm -rf -- "$staging"
        return 1
    fi
    rm -f -- "$archive"
    rm -rf -- "$staging"
}

mount_rclone_remote() {
    local remote="$1"
    local dest log_file
    dest="$(rclone_cloud_root)/$remote"
    log_file="$(rclone_log_dir)/rclone-${remote}.log"
    mkdir -p "$dest" "$(rclone_log_dir)"
    rclone mount "${remote}:" "$dest" \
        --config "$(rclone_config_path)" \
        --vfs-cache-mode writes \
        --daemon \
        --log-file "$log_file"
}

provision_rclone_mounts() {
    write_rclone_config || return 1
    ensure_rclone_and_fuse || return 1
    mkdir -p "$(rclone_cloud_root)" "$(rclone_log_dir)"

    local remote
    local found=0
    local mounted=0
    while IFS= read -r remote; do
        [[ -n "$remote" ]] || continue
        found=1
        if ! rclone_remote_mountable "$remote"; then
            warn "Skipping rclone remote with an unsafe name: $remote"
            continue
        fi
        if mount_rclone_remote "$remote"; then
            mounted=1
            log "rclone mount ready: $(rclone_cloud_root)/$remote"
        else
            warn "rclone mount failed for $remote"
        fi
    done < <(list_rclone_remotes_from_config)

    if (( found == 0 )); then
        warn 'rclone config did not contain any mountable remotes'
        return 1
    fi
    if (( mounted == 0 )); then
        return 1
    fi
    return 0
}

enable_rclone_mounts() {
    if ! rclone_config_present; then
        return 0
    fi
    if ! provision_rclone_mounts; then
        warn 'rclone cloud mounts are unavailable; the Core Session remains available'
    fi
    return 0
}

unmount_rclone_path() {
    local dir="$1"
    fusermount3 -u "$dir" 2>/dev/null ||
        fusermount -u "$dir" 2>/dev/null ||
        umount "$dir" 2>/dev/null ||
        sudo umount "$dir" 2>/dev/null ||
        true
}

unmount_home_bind() {
    local dest="$1"
    mountpoint -q "$dest" 2>/dev/null || return 0
    fusermount3 -u "$dest" 2>/dev/null ||
        fusermount -u "$dest" 2>/dev/null ||
        umount "$dest" 2>/dev/null ||
        sudo umount "$dest" 2>/dev/null ||
        true
}

rclone_writeback_wait_seconds() {
    printf '%s\n' '120'
}

rclone_process_running() {
    pgrep -x rclone >/dev/null 2>&1
}

wait_for_rclone_exit() {
    local timeout="$1"
    local elapsed=0
    while rclone_process_running; do
        if (( elapsed >= timeout )); then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 0
}

cleanup_rclone_home_mounts() {
    local target source kind dest
    if ! rclone_home_links_present; then
        return 0
    fi
    if ! parse_rclone_home_links >/dev/null; then
        return 0
    fi
    while IFS=$'\t' read -r target source kind; do
        [[ -n "$target" ]] || continue
        dest="$HOME/$target"
        if mountpoint -q "$dest" 2>/dev/null; then
            unmount_home_bind "$dest"
        elif [[ -L "$dest" ]]; then
            rm -f -- "$dest" || true
        fi
    done < <(parse_rclone_home_links)
}

cleanup_rclone_mounts() {
    local root dir
    cleanup_rclone_home_mounts
    root="$(rclone_cloud_root)"
    if [[ -d "$root" ]]; then
        for dir in "$root"/*; do
            [[ -e "$dir" || -L "$dir" ]] || continue
            unmount_rclone_path "$dir"
        done
    fi

    if ! wait_for_rclone_exit "$(rclone_writeback_wait_seconds)"; then
        warn 'rclone did not exit after unmount; unflushed VFS writes may be lost'
        pkill -x rclone 2>/dev/null || true
        wait_for_rclone_exit 5 || true
    fi

    rm -f -- "$(rclone_config_path)"
    rm -rf -- "$HOME/.cache/rclone" "$(rclone_log_dir)"
}

rclone_home_links_present() {
    [[ -n "${RCLONE_HOME_LINKS:-}" ]]
}

rclone_home_link_component_valid() {
    local part="$1"
    [[ "$part" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || return 1
    [[ "$part" != '.' && "$part" != '..' ]] || return 1
    return 0
}

rclone_home_link_target_valid() {
    local target="$1"
    local part
    local -a parts
    [[ -n "$target" ]] || return 1
    [[ "$target" != /* && "$target" != *\\* && "$target" != *[[:space:]]* ]] || return 1
    IFS=/ read -ra parts <<< "$target"
    (( ${#parts[@]} >= 1 && ${#parts[@]} <= 8 )) || return 1
    for part in "${parts[@]}"; do
        rclone_home_link_component_valid "$part" || return 1
    done
    [[ "${parts[0]}" != 'rclone' ]] || return 1
    return 0
}

rclone_home_link_targets_conflict() {
    local left="$1"
    local right="$2"
    [[ "$left" == "$right" || "$left" == "$right"/* || "$right" == "$left"/* ]]
}

rclone_home_link_ancestors_are_local() {
    local dest="$1"
    local home="${HOME%/}"
    local cursor
    cursor="$(dirname -- "$dest")"
    while [[ "$cursor" != "$home" && "$cursor" != '/' && "$cursor" != '.' ]]; do
        if [[ -L "$cursor" || ! -d "$cursor" ]]; then
            return 1
        fi
        if mountpoint -q "$cursor" 2>/dev/null; then
            return 1
        fi
        cursor="$(dirname -- "$cursor")"
    done
    return 0
}

rclone_home_link_source_valid() {
    local source="$1"
    local part
    local -a parts
    [[ -n "$source" ]] || return 1
    [[ "$source" != /* && "$source" != *\\* && "$source" != *[[:space:]]* ]] || return 1
    IFS=/ read -ra parts <<< "$source"
    (( ${#parts[@]} >= 1 )) || return 1
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || return 1
        [[ "$part" != '.' && "$part" != '..' ]] || return 1
    done
    return 0
}

parse_rclone_home_links() {
    local raw line target source existing kind target_dir source_dir
    local -A seen=()
    local lineno=0

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        lineno=$((lineno + 1))
        line="${raw%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" != *=* ]]; then
            printf 'RCLONE_HOME_LINKS line %s is missing =\n' "$lineno" >&2
            return 1
        fi
        target="${line%%=*}"
        source="${line#*=}"
        target="${target#"${target%%[![:space:]]*}"}"
        target="${target%"${target##*[![:space:]]}"}"
        source="${source#"${source%%[![:space:]]*}"}"
        source="${source%"${source##*[![:space:]]}"}"
        target_dir=0
        source_dir=0
        [[ "$target" == */ ]] && target_dir=1
        [[ "$source" == */ ]] && source_dir=1
        while [[ "$target" == */ ]]; do
            target="${target%/}"
        done
        while [[ "$source" == */ ]]; do
            source="${source%/}"
        done
        if [[ -z "$source" ]]; then
            printf 'RCLONE_HOME_LINKS source is invalid: %s\n' "$source" >&2
            return 1
        fi
        if (( target_dir != source_dir )); then
            printf 'RCLONE_HOME_LINKS directory marker mismatch: %s=%s\n' "$target" "$source" >&2
            return 1
        fi
        if (( target_dir )); then
            kind='dir'
        else
            kind='file'
        fi
        if ! rclone_home_link_target_valid "$target"; then
            printf 'RCLONE_HOME_LINKS target is invalid: %s\n' "$target" >&2
            return 1
        fi
        if ! rclone_home_link_source_valid "$source"; then
            printf 'RCLONE_HOME_LINKS source is invalid: %s\n' "$source" >&2
            return 1
        fi
        if [[ -n "${seen[$target]:-}" ]]; then
            printf 'RCLONE_HOME_LINKS has a duplicate target: %s\n' "$target" >&2
            return 1
        fi
        for existing in "${!seen[@]}"; do
            if rclone_home_link_targets_conflict "$existing" "$target"; then
                printf 'RCLONE_HOME_LINKS target conflicts with %s: %s\n' "$existing" "$target" >&2
                return 1
            fi
        done
        seen[$target]=1
        printf '%s\t%s\t%s\n' "$target" "$source" "$kind"
    done <<< "${RCLONE_HOME_LINKS:-}"
}

validate_rclone_home_links() {
    if ! rclone_home_links_present; then
        return 0
    fi
    parse_rclone_home_links >/dev/null
}

rclone_has_live_mounts() {
    local root dir
    root="$(rclone_cloud_root)"
    [[ -d "$root" ]] || return 1
    for dir in "$root"/*; do
        [[ -d "$dir" ]] || continue
        if mountpoint -q "$dir"; then
            return 0
        fi
    done
    return 1
}

directory_is_empty() {
    local dest="$1"
    local -a entries
    local old
    old="$(shopt -p nullglob dotglob)"
    shopt -s nullglob dotglob
    entries=("$dest"/*)
    eval "$old"
    (( ${#entries[@]} == 0 ))
}

ensure_rclone_home_link_source() {
    local src_path="$1"
    local as_file="$2"
    local parent
    parent="$(dirname -- "$src_path")"
    mkdir -p -- "$parent" || return 1

    if [[ -d "$src_path" && ! -L "$src_path" ]]; then
        if [[ "$as_file" == 'file' ]] && directory_is_empty "$src_path"; then
            rmdir -- "$src_path" || return 1
            : >"$src_path" || return 1
        fi
        return 0
    fi
    if [[ -f "$src_path" ]]; then
        return 0
    fi
    if [[ -e "$src_path" ]]; then
        return 1
    fi
    if [[ "$as_file" == 'file' ]]; then
        : >"$src_path"
    else
        mkdir -p -- "$src_path"
    fi
}

home_bind_matches() {
    local dest="$1"
    local src="$2"
    local dest_id src_id dest_src src_real
    mountpoint -q "$dest" 2>/dev/null || return 1
    dest_id="$(stat -c '%d:%i' "$dest" 2>/dev/null)" || return 1
    src_id="$(stat -c '%d:%i' "$src" 2>/dev/null)" || return 1
    if [[ -n "$dest_id" && "$dest_id" == "$src_id" ]]; then
        return 0
    fi
    dest_src="$(findmnt -n -o SOURCE --mountpoint "$dest" 2>/dev/null)" || return 1
    src_real="$(realpath -- "$src" 2>/dev/null || printf '%s' "$src")"
    [[ -n "$dest_src" && ( "$dest_src" == "$src" || "$dest_src" == "$src_real" ) ]]
}

bind_home_path() {
    local src="$1"
    local dest="$2"

    if mount --bind "$src" "$dest" 2>/dev/null; then
        return 0
    fi
    if [[ -d "$src" ]] && command -v bindfs >/dev/null 2>&1; then
        if bindfs --no-allow-other "$src" "$dest" && mountpoint -q "$dest" 2>/dev/null; then
            return 0
        fi
    fi
    sudo mount --bind "$src" "$dest"
}

prepare_home_bind_destination() {
    local dest="$1"
    local src="$2"
    local kind="$3"

    if home_bind_matches "$dest" "$src"; then
        return 0
    fi
    if mountpoint -q "$dest" 2>/dev/null; then
        unmount_home_bind "$dest"
        if home_bind_matches "$dest" "$src"; then
            return 0
        fi
    fi

    if [[ -L "$dest" ]]; then
        rm -f -- "$dest" || return 1
    fi

    if [[ "$kind" == 'file' ]]; then
        if [[ -d "$dest" && ! -L "$dest" ]]; then
            if directory_is_empty "$dest"; then
                rmdir -- "$dest" || return 1
            else
                return 1
            fi
        fi
        if [[ -e "$dest" && ! -f "$dest" ]]; then
            return 1
        fi
        if [[ -f "$dest" ]]; then
            if [[ -s "$dest" ]]; then
                return 1
            fi
            return 2
        fi
        : >"$dest" || return 1
        return 2
    fi

    if [[ -f "$dest" ]]; then
        return 1
    fi
    if [[ -d "$dest" ]]; then
        if directory_is_empty "$dest"; then
            return 2
        fi
        return 1
    fi
    if [[ -e "$dest" ]]; then
        return 1
    fi
    mkdir -p -- "$dest" || return 1
    return 2
}

install_home_bind() {
    local dest="$1"
    local src="$2"
    local kind="${3:-dir}"
    local status

    set +e
    prepare_home_bind_destination "$dest" "$src" "$kind"
    status=$?
    set -e
    if (( status == 0 )); then
        return 0
    fi
    if (( status != 2 )); then
        return 1
    fi
    bind_home_path "$src" "$dest"
}

apply_rclone_home_link() {
    local target="$1"
    local source="$2"
    local kind="${3:-dir}"
    local dest src_path first parent
    dest="$HOME/$target"
    src_path="$HOME/rclone/$source"
    first="${source%%/*}"
    parent="$(dirname -- "$dest")"

    if ! mountpoint -q "$(rclone_cloud_root)/$first"; then
        warn "Skipping home link ${target}: rclone remote ${first} is not mounted"
        return 0
    fi
    if ! ensure_rclone_home_link_source "$src_path" "$kind"; then
        warn "Skipping home link ${target}: could not create ${src_path}"
        return 0
    fi
    if [[ "$kind" == 'file' ]]; then
        if [[ -d "$src_path" && ! -f "$src_path" ]]; then
            warn "Skipping home link ${target}: source is a directory but the mapping is a file"
            return 0
        fi
        if [[ ! -f "$src_path" ]]; then
            warn "Skipping home link ${target}: source is not a file"
            return 0
        fi
    elif [[ ! -d "$src_path" ]]; then
        warn "Skipping home link ${target}: source is not a directory"
        return 0
    fi
    if ! mkdir -p -- "$parent"; then
        warn "Skipping home link ${target}: could not create parent ${parent}"
        return 0
    fi
    if ! rclone_home_link_ancestors_are_local "$dest"; then
        warn "Skipping home link ${target}: parent is not a local directory"
        return 0
    fi
    if install_home_bind "$dest" "$src_path" "$kind"; then
        log "home mount ready: ${dest} <= ${src_path}"
        return 0
    fi
    warn "Skipping home mount ${target}: could not bind ${src_path} onto ${dest}"
    return 0
}

enable_rclone_home_links() {
    if ! rclone_home_links_present; then
        log 'RCLONE_HOME_LINKS is empty; skipping home links'
        return 0
    fi
    if ! rclone_has_live_mounts; then
        warn 'RCLONE_HOME_LINKS is set but rclone mounts are unavailable; skipping home links'
        return 0
    fi

    local target source kind
    if ! parse_rclone_home_links >/dev/null; then
        warn 'RCLONE_HOME_LINKS is invalid after validate; skipping home links'
        return 0
    fi
    while IFS=$'\t' read -r target source kind; do
        [[ -n "$target" ]] || continue
        apply_rclone_home_link "$target" "$source" "$kind"
    done < <(parse_rclone_home_links)
    return 0
}

git_workspaces_present() {
    [[ -n "${GIT_WORKSPACES:-}" ]]
}

workspace_root() {
    printf '%s' "${HOME%/}"
}

git_workspace_destination() {
    local name="$1"
    printf '%s/%s\n' "$(workspace_root)" "$name"
}

git_workspace_name_component_valid() {
    local part="$1"
    [[ "$part" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || return 1
    [[ "$part" != '.' && "$part" != '..' ]] || return 1
    return 0
}

git_workspace_name_valid() {
    local name="$1"
    local part
    local -a parts
    [[ -n "$name" ]] || return 1
    [[ "$name" != /* && "$name" != */ && "$name" != *//* ]] || return 1
    IFS=/ read -ra parts <<< "$name"
    (( ${#parts[@]} >= 1 && ${#parts[@]} <= 8 )) || return 1
    for part in "${parts[@]}"; do
        git_workspace_name_component_valid "$part" || return 1
    done
    return 0
}

git_workspace_names_conflict() {
    local left="$1"
    local right="$2"
    [[ "$left" == "$right" || "$left" == "$right"/* || "$right" == "$left"/* ]]
}

git_workspace_url_valid() {
    local url="$1"
    [[ "$url" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)+$ ]]
}

git_workspace_shorthand_valid() {
    local spec="$1"
    local owner repo
    [[ -n "$spec" && "$spec" != /* && "$spec" != */ && "$spec" != *//* ]] || return 1
    [[ "$spec" == */* ]] || return 1
    owner="${spec%%/*}"
    repo="${spec#*/}"
    [[ "$repo" != */* ]] || return 1
    repo="${repo%.git}"
    git_workspace_name_component_valid "$owner" || return 1
    git_workspace_name_component_valid "$repo" || return 1
}

git_workspace_expand_shorthand() {
    printf 'https://github.com/%s\n' "$1"
}

git_workspace_name_from_shorthand() {
    local spec="$1"
    spec="${spec%.git}"
    printf '%s\n' "${spec##*/}"
}

git_workspace_name_from_url() {
    local url="$1"
    local rest
    rest="${url#https://}"
    rest="${rest#*/}"
    rest="${rest%.git}"
    while [[ "$rest" == */ ]]; do
        rest="${rest%/}"
    done
    printf '%s\n' "${rest##*/}"
}

git_workspace_normalize_url() {
    local url="$1"
    while [[ "$url" == */ ]]; do
        url="${url%/}"
    done
    url="${url%.git}"
    printf '%s\n' "$url"
}

git_workspace_destination_valid() {
    local dest="$1"
    local home rclone
    home="$(workspace_root)"
    rclone="$home/rclone"
    [[ "$dest" != "$home" ]] || return 1
    [[ "$dest" != "$rclone" && "$dest" != "$rclone"/* ]] || return 1
    return 0
}

parse_git_workspaces() {
    local raw line name url existing
    local -A seen=()
    local lineno=0

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        lineno=$((lineno + 1))
        line="${raw%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        name=''
        url=''
        if [[ "$line" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
            url="$line"
        elif [[ "$line" == *=* ]]; then
            name="${line%%=*}"
            url="${line#*=}"
            name="${name#"${name%%[![:space:]]*}"}"
            name="${name%"${name##*[![:space:]]}"}"
            url="${url#"${url%%[![:space:]]*}"}"
            url="${url%"${url##*[![:space:]]}"}"
        elif git_workspace_shorthand_valid "$line"; then
            url="$line"
        else
            printf 'GIT_WORKSPACES line %s is missing a URL\n' "$lineno" >&2
            return 1
        fi

        while [[ "$url" == */ ]]; do
            url="${url%/}"
        done
        if git_workspace_shorthand_valid "$url"; then
            if [[ -z "$name" ]]; then
                name="$(git_workspace_name_from_shorthand "$url")"
            fi
            url="$(git_workspace_expand_shorthand "$url")"
        elif ! git_workspace_url_valid "$url"; then
            printf 'GIT_WORKSPACES URL is invalid: %s\n' "$url" >&2
            return 1
        fi
        if [[ -z "$name" ]]; then
            name="$(git_workspace_name_from_url "$url")"
        fi
        if ! git_workspace_name_valid "$name"; then
            printf 'GIT_WORKSPACES name is invalid: %s\n' "$name" >&2
            return 1
        fi
        if ! git_workspace_destination_valid "$(git_workspace_destination "$name")"; then
            printf 'GIT_WORKSPACES destination is invalid: %s\n' "$name" >&2
            return 1
        fi
        if [[ -n "${seen[$name]:-}" ]]; then
            printf 'GIT_WORKSPACES has a duplicate name: %s\n' "$name" >&2
            return 1
        fi
        for existing in "${!seen[@]}"; do
            if git_workspace_names_conflict "$existing" "$name"; then
                printf 'GIT_WORKSPACES name conflicts with %s: %s\n' "$existing" "$name" >&2
                return 1
            fi
        done
        seen[$name]=1
        printf '%s\t%s\n' "$name" "$url"
    done <<< "${GIT_WORKSPACES:-}"
}

validate_git_workspaces() {
    if ! git_workspaces_present; then
        return 0
    fi
    parse_git_workspaces >/dev/null
}

git_workspace_credential_helper() {
    # The helper must expand GIT_WORKSPACES_TOKEN in git's shell, not here.
    # shellcheck disable=SC2016
    printf '%s\n' '!f() { echo username=x-access-token; echo password=$GIT_WORKSPACES_TOKEN; }; f'
}

git_workspace_cmd() {
    local -a git_cmd=(git)
    if [[ -n "${GIT_WORKSPACES_TOKEN:-}" ]]; then
        git_cmd+=(-c credential.helper= -c "credential.helper=$(git_workspace_credential_helper)")
    fi
    GIT_TERMINAL_PROMPT=0 "${git_cmd[@]}" "$@"
}

git_workspace_remote_matches() {
    local dest="$1"
    local expected="$2"
    local actual
    actual="$(git -C "$dest" remote get-url origin 2>/dev/null)" || return 1
    [[ "$(git_workspace_normalize_url "$actual")" == "$(git_workspace_normalize_url "$expected")" ]]
}

ensure_git() {
    if command -v git >/dev/null 2>&1; then
        return 0
    fi
    run_apt_update
    run_apt_install git
}

clone_git_workspace() {
    local name="$1"
    local url="$2"
    local dest
    dest="$(git_workspace_destination "$name")"

    if [[ -d "$dest/.git" ]]; then
        if git_workspace_remote_matches "$dest" "$url"; then
            log "git workspace already present: $dest"
        else
            warn "Skipping git workspace ${name}: ${dest} is a different git remote"
        fi
        return 0
    fi
    if [[ -e "$dest" ]]; then
        warn "Skipping git workspace ${name}: ${dest} already exists"
        return 0
    fi

    if ! mkdir -p -- "$(dirname -- "$dest")"; then
        warn "Skipping git workspace ${name}: could not create $(dirname -- "$dest")"
        return 0
    fi

    if git_workspace_cmd clone --depth=1 -- "$url" "$dest"; then
        log "git workspace ready: $dest"
        return 0
    fi
    rm -rf -- "$dest"
    warn "git clone failed for ${name}"
    return 0
}

enable_git_workspaces() {
    if ! git_workspaces_present; then
        return 0
    fi
    if ! ensure_git; then
        warn 'git is unavailable; skipping git workspaces'
        return 0
    fi
    if ! parse_git_workspaces >/dev/null; then
        warn 'GIT_WORKSPACES is invalid after validate; skipping git workspaces'
        return 0
    fi

    local name url
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" ]] || continue
        clone_git_workspace "$name" "$url"
    done < <(parse_git_workspaces)
    return 0
}

git_workspace_ensure_identity() {
    local dest="$1"
    if [[ -z "$(git -C "$dest" config --get user.name 2>/dev/null || true)" ]]; then
        git -C "$dest" config user.name debug-session
    fi
    if [[ -z "$(git -C "$dest" config --get user.email 2>/dev/null || true)" ]]; then
        git -C "$dest" config user.email debug-session@users.noreply.github.com
    fi
}

git_workspace_rebase_and_push() {
    local dest="$1"

    git -C "$dest" rebase --abort >/dev/null 2>&1 || true
    if git_workspace_cmd -C "$dest" fetch origin &&
        git_workspace_cmd -C "$dest" rebase '@{u}' &&
        git_workspace_cmd -C "$dest" push; then
        return 0
    fi

    git -C "$dest" rebase --abort >/dev/null 2>&1 || true
    if git_workspace_cmd -C "$dest" fetch --unshallow origin &&
        git_workspace_cmd -C "$dest" rebase '@{u}' &&
        git_workspace_cmd -C "$dest" push; then
        return 0
    fi

    git -C "$dest" rebase --abort >/dev/null 2>&1 || true
    return 1
}

sync_git_workspace() {
    local name="$1"
    local dest
    dest="$(git_workspace_destination "$name")"

    if [[ ! -d "$dest/.git" ]]; then
        return 0
    fi

    if ! git_workspace_ensure_identity "$dest"; then
        warn "git identity failed for ${name}"
        return 0
    fi

    if ! git -C "$dest" add -A; then
        warn "git add failed for ${name}"
        return 0
    fi

    if [[ -n "$(git -C "$dest" status --porcelain 2>/dev/null || true)" ]]; then
        local host ts
        host="$(hostname -s 2>/dev/null || hostname || printf 'runner')"
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if ! git -C "$dest" commit -m "debug-session sync: ${host} ${ts}"; then
            warn "git commit failed for ${name}"
            return 0
        fi
        log "git workspace committed: $dest"
    else
        log "git workspace unchanged: $dest"
    fi

    if git_workspace_rebase_and_push "$dest"; then
        log "git workspace synced: $dest"
        return 0
    fi
    warn "git push failed for ${name}"
    return 0
}

sync_git_workspaces() {
    if ! git_workspaces_present; then
        return 0
    fi
    if ! command -v git >/dev/null 2>&1; then
        warn 'git is unavailable; skipping git workspace sync'
        return 0
    fi
    if ! parse_git_workspaces >/dev/null; then
        warn 'GIT_WORKSPACES is invalid after validate; skipping git workspace sync'
        return 0
    fi

    local name url
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" ]] || continue
        sync_git_workspace "$name"
    done < <(parse_git_workspaces)
    return 0
}

run_session() {
    enable_core_session
    if ! ensure_post_core_packages; then
        warn 'post-core packages failed; Cloud Mounts or Developer Profile tools may be incomplete'
    fi
    enable_rclone_mounts
    enable_rclone_home_links
    enable_git_workspaces
    local dev_pid=""
    if [[ "$SESSION_PROFILE" == developer ]]; then
        install_developer_profile &
        dev_pid=$!
    fi
    if [[ "$ACCESS_PROFILE" == full ]]; then
        enable_xfce_rdp || true
    fi
    if [[ -n "$dev_pid" ]]; then
        wait "$dev_pid" || true
    fi
    wait_for_stop
}

oauth_cleanup_configured() {
    [[ -n "${TAILSCALE_OAUTH_CLIENT_ID:-}" &&
        -n "${TAILSCALE_OAUTH_CLIENT_SECRET:-}" &&
        -n "${TAILSCALE_HOSTNAME:-}" ]]
}

cleanup() {
    sync_git_workspaces || warn 'git workspace sync failed; continuing rclone cleanup'
    cleanup_rclone_mounts || warn 'rclone cleanup failed; continuing Tailscale cleanup'

    local logout_status=0
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
        sudo tailscale logout || logout_status=1
    fi

    if oauth_cleanup_configured; then
        local access_token
        access_token="$(request_oauth_access_token)" || {
            printf 'Could not delete the reserved Tailscale device\n' >&2
            return 1
        }
        reclaim_reserved_hostname "$access_token" || {
            printf 'Could not delete the reserved Tailscale device\n' >&2
            return 1
        }
    fi

    if (( logout_status != 0 )); then
        printf 'Tailscale logout failed; the reserved name is removed when device delete succeeds\n' >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        validate) validate_inputs ;;
        run) run_session ;;
        cleanup) cleanup ;;
        *)
            printf 'Usage: %s {validate|run|cleanup}\n' "$0" >&2
            exit 2
            ;;
    esac
fi
