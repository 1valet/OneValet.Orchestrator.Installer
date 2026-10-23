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

# Drop what was typed into the terminal before a question (say, keys pressed during a long wait), so it isn't taken
# as the answer. python3 is there by then (Command Line Tools); without it, nothing is dropped.
drain_input() {
    python3 -c 'import sys, termios; termios.tcflush(open("/dev/tty"), termios.TCIFLUSH)' 2>/dev/null || true
}

# A typed answer without escape sequences (arrow keys, Escape) and control characters, trimmed.
clean_answer() {
    printf '%s' "$1" | sed $'s/\e\\[[0-9;?]*[A-Za-z~]//g; s/\eO.//g' | tr -d '[:cntrl:]' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# The folder to install into: Enter takes $1; a typed folder must be absolute or start with ~. Asked again when the
# answer had nothing usable once control characters are gone.
ask_folder() {
    local default="$1" raw reply
    while :; do
        drain_input
        raw="$(ask_line "Install into $default? (Enter, or type another folder) ")"
        reply="$(clean_answer "$raw")"
        if [ -z "$raw" ]; then echo "$default"; return 0; fi
        case "$reply" in
            /*|"~"|"~/"*) echo "$reply"; return 0 ;;
            "") echo "That answer had only control keys in it; type a folder, or just press Enter." >&2 ;;
            *) echo "Type a full path (starting with / or ~), or just press Enter." >&2 ;;
        esac
    done
}

# The terminal's own device (/dev/ttys003, /dev/pts/1). start gets it as stdin, opened read-write: Claude Code (Bun)
# fails with "EINVAL: invalid argument, kqueue" on /dev/tty, and on the device opened read-only.
terminal_device() {
    local t
    t="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')"
    case "$t" in ''|'?'|'??') return 1 ;; esac
    [ -c "/dev/$t" ] && echo "/dev/$t"
}

# Apple's Command Line Tools through softwareupdate, which has no disk-space check of its own (the dialog can refuse,
# asking for far more space than the tools take). The marker file makes softwareupdate list them.
install_clt_softwareupdate() {
    local marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label
    touch "$marker"
    info "Looking up the Command Line Tools in Software Update"
    label="$(softwareupdate -l 2>/dev/null | sed -n 's/^[[:space:]]*\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -1)"
    if [ -z "$label" ]; then
        rm -f "$marker"
        die "Software Update doesn't offer the Command Line Tools; install them from https://developer.apple.com/download/all/ and run this again"
    fi
    info "Installing $label (macOS asks for your password; this takes a few minutes)"
    sudo softwareupdate -i "$label" </dev/tty || { rm -f "$marker"; die "installing $label failed"; }
    rm -f "$marker"
}

# Apple's dialog first; while it runs, say every 30 s that we're still waiting. When it closes without installing
# (cancelled, or refused for disk space), or nothing is installed after 30 minutes, fall back to softwareupdate.
install_clt() {
    local waited=0
    info "Installing Apple's Command Line Tools (git, python3): finish the installer that opens"
    xcode-select --install >/dev/null 2>&1 || true
    sleep 5
    while ! xcode-select -p >/dev/null 2>&1; do
        if ! pgrep -f "Install Command Line Developer Tools" >/dev/null 2>&1; then
            info "The installer window closed without installing; installing through Software Update instead"
            install_clt_softwareupdate
            break
        fi
        if [ "$waited" -ge 1800 ]; then
            info "Still not installed after 30 minutes; installing through Software Update instead"
            install_clt_softwareupdate
            break
        fi
        sleep 5
        waited=$((waited + 5))
        [ $((waited % 30)) -ne 0 ] || echo "     still waiting for the Command Line Tools installer ($((waited / 60)) min $((waited % 60)) s)"
    done
    xcode-select -p >/dev/null 2>&1 || die "the Command Line Tools aren't installed; run this again"
    info "Command Line Tools installed"
}

ensure_git_python() {
    if [ "$(uname -s)" = Darwin ]; then
        # Apple's Command Line Tools provide git and /usr/bin/python3.
        xcode-select -p >/dev/null 2>&1 || install_clt
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
    local dir="${ONEVALET_DIR:-}" tty_dev
    echo "Installing the $APP_NAME"
    ensure_git_python
    if [ -z "$dir" ]; then
        dir="$HOME/1valet/OneValet.Orchestrator"
        [ -d "$dir/.git" ] || dir="$(ask_folder "$dir")"
    fi
    dir="${dir/#\~/$HOME}"
    info "Folder: $dir"
    clone_or_update "$dir"
    add_launcher "$dir" || true
    info "Starting (next time: open \"$APP_NAME\", or run $dir/start.sh)"
    cd "$dir"
    if tty_dev="$(terminal_device)"; then exec ./start.sh "$@" <>"$tty_dev"; fi
    exec ./start.sh "$@" </dev/tty
}

main "$@"
