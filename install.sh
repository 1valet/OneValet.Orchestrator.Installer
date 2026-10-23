#!/usr/bin/env bash
# Install the 1VALET orchestrator on a new machine (macOS, Linux, WSL): git and python3, SSH access to Azure DevOps,
# a clone of this repo, a launcher, then ./start.sh. Windows: install.ps1. A copy is published in the public GitHub
# repo 1valet/OneValet.Orchestrator.Installer, so it runs without git or an Azure DevOps sign-in:
#
#   curl -fsSL https://raw.githubusercontent.com/1valet/OneValet.Orchestrator.Installer/main/install.sh | bash
#
# Run again, it updates the clone (fast-forward only) and runs start. ONEVALET_DIR sets the folder.
# Everything is in main(), called on the last line, so a download cut short runs nothing; questions read
# /dev/tty, because under curl | bash stdin is this script.
set -euo pipefail

REPO_URL="onevalet@vs-ssh.visualstudio.com:v3/onevalet/1Valet-BAS/OneValet.Orchestrator"
VSTS_KEY="$HOME/.ssh/onevalet_vsts_rsa"
VSTS_KEYS_URL="https://dev.azure.com/onevalet/_usersSettings/keys"
APP_NAME="1VALET Orchestrator"

info() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }
ask_line() { local reply; read -r -p "$1" reply </dev/tty || reply=""; echo "$reply"; }

ensure_git_python() {
    if [ "$(uname -s)" = Darwin ]; then
        # Apple's Command Line Tools provide git and /usr/bin/python3.
        xcode-select -p >/dev/null 2>&1 && return 0
        info "Installing Apple's Command Line Tools (git, python3): finish the installer that opens"
        xcode-select --install >/dev/null 2>&1 || true
        until xcode-select -p >/dev/null 2>&1; do sleep 5; done
        info "Command Line Tools installed"
    elif ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || die "install git and python3, then run this again"
        info "Installing git and python3 (sudo)"
        sudo apt-get update -qq && sudo apt-get install -y -qq git python3 </dev/tty
    fi
}

SSH_MODE=default
ssh_command() {
    if [ "$SSH_MODE" = key ]; then
        echo "ssh -i '$VSTS_KEY' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    else
        echo "ssh -o StrictHostKeyChecking=accept-new"
    fi
}
can_read() { GIT_SSH_COMMAND="$(ssh_command) -o BatchMode=yes" git ls-remote "$REPO_URL" HEAD >/dev/null 2>&1; }

copy_to_clipboard() {
    local tool
    for tool in pbcopy clip.exe wl-copy "xclip -selection clipboard"; do
        if command -v "${tool%% *}" >/dev/null 2>&1; then $tool && return 0; fi
    done
    return 1
}

# The same order as orch clone: the user's own SSH setup, then $VSTS_KEY, created and registered if needed.
ensure_access() {
    can_read && return 0
    SSH_MODE=key
    while ! { [ -f "$VSTS_KEY" ] && can_read; }; do
        if [ ! -f "$VSTS_KEY" ]; then
            mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
            info "Creating an SSH key for Azure DevOps: $VSTS_KEY"
            ssh-keygen -q -t rsa -b 4096 -N '' -C "$(whoami)@$(hostname) 1VALET Azure DevOps" -f "$VSTS_KEY"
        else
            echo "Azure DevOps doesn't accept $VSTS_KEY yet."
        fi
        echo
        echo "Add this public key to Azure DevOps (VSTS):"
        echo "  1. Open $VSTS_KEYS_URL"
        echo "  2. New Key, any name, paste the key below, Add"
        echo
        cat "$VSTS_KEY.pub"
        echo
        if copy_to_clipboard < "$VSTS_KEY.pub"; then echo "(also copied to the clipboard)"; fi
        command -v open >/dev/null 2>&1 && open "$VSTS_KEYS_URL" 2>/dev/null || true
        ask_line "Press Enter once the key is added (Ctrl+C to stop) " >/dev/null
    done
}

clone_or_update() {
    local dir="$1"
    if [ -d "$dir/.git" ]; then
        info "Updating $dir"
        if [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
            git -C "$dir" pull --ff-only -q || echo "     (couldn't fast-forward; left as is)"
        else
            echo "     (local changes; left as is)"
        fi
        return 0
    fi
    [ ! -e "$dir" ] || [ -z "$(ls -A "$dir")" ] || die "$dir exists and isn't a clone of the orchestrator"
    ensure_access
    info "Cloning the orchestrator into $dir"
    mkdir -p "$(dirname "$dir")"
    GIT_SSH_COMMAND="$(ssh_command)" git clone -q "$REPO_URL" "$dir"
    # Like orch clone: a clone made with the key keeps using it, without an ssh config.
    [ "$SSH_MODE" = default ] || git -C "$dir" config core.sshCommand "ssh -i '$VSTS_KEY' -o IdentitiesOnly=yes"
}

# A launcher that opens a terminal and runs start: an app in ~/Applications (Spotlight, Dock) on macOS, a menu
# entry on Linux desktops. None on WSL (start it from Windows Terminal).
add_launcher() {
    local dir="$1" app desktop
    if [ "$(uname -s)" = Darwin ]; then
        app="$HOME/Applications/$APP_NAME.app"
        [ -d "$app" ] && return 0
        mkdir -p "$HOME/Applications"
        osacompile -o "$app" \
            -e 'tell application "Terminal"' \
            -e 'activate' \
            -e "do script \"cd '$dir' && ./start.sh\"" \
            -e 'end tell' >/dev/null 2>&1 && info "Added $app (find it with Spotlight, or drag it to the Dock)"
    elif ! grep -qi microsoft /proc/version 2>/dev/null && [ -n "${XDG_CURRENT_DESKTOP:-}" ]; then
        desktop="$HOME/.local/share/applications/onevalet-orchestrator.desktop"
        [ -f "$desktop" ] && return 0
        mkdir -p "$(dirname "$desktop")"
        printf '[Desktop Entry]\nType=Application\nName=%s\nExec=bash -c "cd '\''%s'\'' && ./start.sh"\nTerminal=true\n' \
            "$APP_NAME" "$dir" > "$desktop"
        info "Added \"$APP_NAME\" to your applications menu"
    fi
}

main() {
    local dir="${ONEVALET_DIR:-}" reply
    echo "Installing the $APP_NAME"
    ensure_git_python
    if [ -z "$dir" ]; then
        dir="$HOME/1valet/OneValet.Orchestrator"
        [ -d "$dir/.git" ] || { reply="$(ask_line "Install into $dir? (Enter, or type another folder) ")"; dir="${reply:-$dir}"; }
    fi
    dir="${dir/#\~/$HOME}"
    clone_or_update "$dir"
    add_launcher "$dir" || true
    info "Starting (next time: open \"$APP_NAME\", or run $dir/start.sh)"
    cd "$dir"
    exec ./start.sh "$@" </dev/tty
}

main "$@"
