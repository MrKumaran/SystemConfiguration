#!/usr/bin/env bash

# Written for bash, so if not bash running run with bash
if [ -z "${BASH_VERSION-}" ] || [ -n "${POSIXLY_CORRECT-}" ]; then
    if [ ! -f "$0" ]; then
        echo "This script needs bash - run it as:  bash init.sh" >&2
        exit 1
    fi
    exec /usr/bin/env -u POSIXLY_CORRECT bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

REPO_URL="https://github.com/MrKumaran/SystemConfiguration.git"
REPO_DIR="$HOME/SystemConfiguration"

BREW_PACKAGES=(eza fastfetch ncdu btop podman zsh-autosuggestions)

# Files we manage: rc files (merged line by line into a marked block).
#   entries are  FILE::COMMENT_CHAR   (the char that starts a comment in that
#   file: # for shells, " for vim - decides which lines are comments and how
#   the block markers are written)
RC_FILES=('.zshrc::#' '.bashrc::#' '.vimrc::"')
BRAVERAT_DIR="$HOME/.braverat"

say() { printf '%s\n' "$*"; }

# report LABEL MESSAGE - one aligned summary line
report() { printf '  %-20s %s\n' "$1" "$2"; }

# Scratch space for this run; removed on every exit (normal, error, Ctrl-C).
TMP_DIR=${TMPDIR:-/tmp}/braverat_init_$$
SUDO_KEEPALIVE_PID=
cleanup() {
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    rm -rf "$TMP_DIR"
}

# run_quiet LOG_NAME CMD... - run a long installer with its output in a log.
# On failure the last lines are shown, so a broken step is not silent.
run_quiet() {
    local log="$TMP_DIR/$1.log"; shift
    if "$@" > "$log" 2>&1; then
        return 0
    fi
    say "    --- last lines of output ---"
    tail -n 15 "$log" | sed 's/^/    /'
    return 1
}

# ---------------------------------------------------------------------------
# sudo - asked only when a step really needs it, and only once
# ---------------------------------------------------------------------------

# `sudo -v` prompts for the password and caches it (~5 min). Installs can
# take longer, so a background loop refreshes it every 60s. `kill -0 $$`
# only checks this script is still alive, so the loop can never outlive us.
ensure_sudo() {
    [ -n "$SUDO_KEEPALIVE_PID" ] && return 0
    if ! sudo -v; then
        say "ERROR: user '$USER' has no sudo access - needed for the step above."
        exit 1
    fi
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 60; done ) &
    SUDO_KEEPALIVE_PID=$!
}

# ---------------------------------------------------------------------------
# Step 1: git
# ---------------------------------------------------------------------------

# `xcode-select --install` opens a GUI dialog and returns IMMEDIATELY, it
# does not wait for the download. So we poll `xcode-select -p` (prints the
# install path once the tools exist) until it succeeds.
install_xcode_clt() {
    xcode-select --install 2>/dev/null
    say "    waiting for the Xcode Command Line Tools dialog to finish (click Install)..."
    until xcode-select -p >/dev/null 2>&1; do
        sleep 10
    done
}

# Homebrew on Linux needs curl/git/gcc to install itself, and we need git
# to clone - a minimal Linux has none of them.
install_linux_prereqs() {
    ensure_sudo
    if command -v apt-get >/dev/null 2>&1; then
        run_quiet prereqs sudo apt-get update && run_quiet prereqs sudo apt-get install -y curl git build-essential procps file
    elif command -v dnf >/dev/null 2>&1; then
        run_quiet prereqs sudo dnf install -y curl git gcc gcc-c++ make procps-ng file
    elif command -v yum >/dev/null 2>&1; then
        run_quiet prereqs sudo yum install -y curl git gcc gcc-c++ make procps-ng file
    else
        say "no apt-get/dnf/yum found - install curl, git and gcc by hand, then re-run."
        return 1
    fi
}

step_git() {
    if [ "$OS" = mac ]; then
        if xcode-select -p >/dev/null 2>&1; then
            report "git" "already installed"
        else
            install_xcode_clt && report "git" "installed (Xcode Command Line Tools)"
        fi
    else
        if command -v curl >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then
            report "git" "already installed"
        else
            install_linux_prereqs && report "git" "installed (curl git gcc)" || { report "git" "FAILED"; exit 1; }
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 2: repo
# ---------------------------------------------------------------------------

# If used with private repo then give PAT with read only scope for systemconfiguration repo
git_auth() {
    git "$@"
}

step_repo() {
    if [ -d "$REPO_DIR/.git" ]; then
        git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
        if git_auth -C "$REPO_DIR" pull --ff-only -q; then
            report "~/SystemConfiguration" "updated to latest"
        else
            report "~/SystemConfiguration" "PULL FAILED - local changes in the repo? fix them and re-run"
            exit 1
        fi
    elif [ -e "$REPO_DIR" ]; then
        report "~/SystemConfiguration" "EXISTS but is not a git repo - move it away and re-run"
        exit 1
    else
        if git_auth clone -q "$REPO_URL" "$REPO_DIR"; then
            report "~/SystemConfiguration" "cloned"
        else
            report "~/SystemConfiguration" "CLONE FAILED"
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Homebrew
# ---------------------------------------------------------------------------

# Homebrew lands in a different directory depending on the machine:
#   /opt/homebrew          - Apple Silicon mac
#   /usr/local             - Intel mac
#   /home/linuxbrew/...    - Linux
# Right after installing, `brew` is NOT on the PATH of this shell yet.
# `brew shellenv` prints the export lines and `eval` runs them here. Sets
# BREW_BIN and returns 0 if brew exists - so it doubles as the check.
BREW_BIN=
activate_brew() {
    local b
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
        if [ -x "$b" ]; then
            BREW_BIN=$b
            eval "$("$b" shellenv)"
            return 0
        fi
    done
    return 1
}

# brew_perms_ok - if the brew prefix (or something under it) is owned by
# root or another user - shared macs, migrated setups, a brew once run with
# sudo - `brew install` dies with "Permission denied". The prefix comes
# from `brew --prefix` and the owner is whoever runs this.
# `find ... -quit` stops at the FIRST wrongly-owned path, so the healthy
# case is cheap.
brew_perms_ok() {
    local prefix
    prefix=$(brew --prefix 2>/dev/null) || return 0
    [ -d "$prefix" ] || return 0
    [ -z "$(find "$prefix" ! -user "$(id -un)" -print -quit 2>/dev/null)" ]
}

step_brew() {
    if activate_brew; then
        report "Homebrew" "already installed"
    else
        ensure_sudo
        say "Homebrew installing (takes a few minutes)..."
        if run_quiet brew env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && activate_brew; then
            report "Homebrew" "installed"
        else
            report "Homebrew" "FAILED"
            exit 1
        fi
    fi
    if ! brew_perms_ok; then
        ensure_sudo
        sudo chown -R "$(id -un)" "$(brew --prefix)" && report "brew ownership" "fixed"
    fi
}

# ---------------------------------------------------------------------------
# Step 4: zsh as the default shell
# ---------------------------------------------------------------------------

# login_shell - the shell stored for this user (what a new terminal opens).
# $SHELL is only the fallback: it is inherited and stays stale after a chsh.
login_shell() {
    local s
    if [ "$OS" = mac ]; then
        s=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2}')
    else
        s=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
    fi
    printf '%s' "${s:-${SHELL-}}"
}

step_zsh() {
    local zsh_path
    if [ -x /bin/zsh ]; then
        zsh_path=/bin/zsh
    elif command -v zsh >/dev/null 2>&1; then
        zsh_path=$(command -v zsh)
    else
        say "zsh installing..."
        if run_quiet zsh brew install zsh; then
            zsh_path="$(brew --prefix)/bin/zsh"
            report "zsh" "installed"
        else
            report "zsh" "FAILED"
            return 1
        fi
    fi

    # chsh only accepts shells listed in /etc/shells; a brew zsh is not there.
    if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
        ensure_sudo
        printf '%s\n' "$zsh_path" | sudo tee -a /etc/shells >/dev/null
    fi

    case $(login_shell) in
        */zsh)
            report "default shell" "already zsh"
            ;;
        *)
            say "default shell switching to $zsh_path (asks for YOUR login password)..."
            if chsh -s "$zsh_path"; then
                report "default shell" "zsh (new terminals open in zsh)"
            else
                report "default shell" "FAILED - run by hand:  chsh -s $zsh_path"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 5: tools
# ---------------------------------------------------------------------------

step_packages() {
    local p
    for p in "${BREW_PACKAGES[@]}"; do
        if brew list --formula "$p" >/dev/null 2>&1; then
            report "$p" "already installed"
        else
            say "  $p$(printf '%*s' $((21 - ${#p})) '')installing..."
            if run_quiet "pkg_$p" brew install "$p"; then
                report "$p" "installed"
            else
                report "$p" "FAILED"
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# Step 6: config - ~/.braverat files
# ---------------------------------------------------------------------------

# sync_braverat - copy every FILE in the repo's .braverat into ~/.braverat.
# Overwrites in place, so re-runs are idempotent. Sub-folders are not
# copied: ~/.braverat/dotfiles holds the user's data (gt bookmarks, essh
# hosts) and must never be replaced by the repo.
sync_braverat() {
    local src dest name
    mkdir -p "$BRAVERAT_DIR"
    for src in "$REPO_DIR/.braverat"/*; do
        [ -f "$src" ] || continue
        name=${src##*/}
        dest="$BRAVERAT_DIR/$name"
        if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
            report "~/.braverat/$name" "already up to date"
        elif [ -f "$dest" ]; then
            cp "$src" "$dest" && report "~/.braverat/$name" "updated"
        else
            cp "$src" "$dest" && report "~/.braverat/$name" "installed"
        fi
        [ -x "$src" ] && chmod +x "$dest"
    done
}

# ---------------------------------------------------------------------------
# Step 6: config - rc files (block markers)
# ---------------------------------------------------------------------------
#
CFG_BEGIN=
CFG_END=
config_markers() {
    local p=$1
    CFG_BEGIN="$p$p$p Braverat system config start $p$p$p"
    CFG_END="$p$p$p Braverat system config end $p$p$p"
}


strip_block() {
    local begin=$1 end=$2 in_block=0 line
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$begin" ]; then in_block=1; continue; fi
        if [ "$line" = "$end" ];   then in_block=0; continue; fi
        [ "$in_block" -eq 1 ] && continue
        printf '%s\n' "$line"
    done
}

# ---------------------------------------------------------------------------
# Existence checks
# ---------------------------------------------------------------------------

ere_escape() { printf '%s' "$1" | sed 's#[][\.*^$/+?(){}|]#\\&#g'; }


RE_FUNC='^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{'
RE_ALIAS='^alias[[:space:]]+([^=[:space:]]+)='
RE_PROMPT='^(export[[:space:]]+)?(PROMPT|RPROMPT|PS1)='

# unit_present KIND NAME FIRST_LINE BASE_FILE - succeeds if the user's own
# config (BASE_FILE = their rc without our block) already covers this unit.
unit_present() {
    local kind=$1 name=$2 first=$3 base=$4
    case $kind in
        func)  grep -Eq "^[[:space:]]*(function[[:space:]]+)?${name}[[:space:]]*(\(\)|\{|$)" "$base" ;;
        alias) grep -Eq "^[[:space:]]*alias[[:space:]]+$(ere_escape "$name")=" "$base" ;;
        var)   grep -Eq "^[[:space:]]*(export[[:space:]]+)?${name}=" "$base" ;;
        *)     grep -qxF -- "$first" "$base" ;;
    esac
}

# build_block SRC BASE COMMENT_CHAR - print the lines to put in the managed
# block: every unit of SRC that BASE does not already have. Fills the globals
# ADDED_LINES (how many lines were emitted) and KEPT (what was skipped, for
# the summary). Runs in the current shell so those globals survive.
ADDED_LINES=0
KEPT=()
build_block() {
    local src=$1 base=$2 cchar=$3
    local line unit='' unit_lines=0 kind='' name='' mode='' pending=''
    ADDED_LINES=0
    KEPT=()

    emit_or_skip() {
        local first=${unit%%$'\n'*} label
        if unit_present "$kind" "$name" "$first" "$base"; then
            case $kind in
                func)  label="function $name" ;;
                alias) label="alias $name" ;;
                var)   label="$name" ;;
                *)     label=$first; [ ${#label} -gt 40 ] && label="${label:0:37}..." ;;
            esac
            KEPT+=("$label")
        else
            printf '%s' "$pending"
            printf '%s\n' "$unit"
            local nl=${pending//[!$'\n']/}
            ADDED_LINES=$((ADDED_LINES + unit_lines + ${#nl}))
        fi
        pending=''
    }

    while IFS= read -r line || [ -n "$line" ]; do
        # inside a multi-line unit: keep collecting until it closes
        if [ -n "$mode" ]; then
            unit+=$'\n'"$line"
            unit_lines=$((unit_lines + 1))
            if { [ "$mode" = func ] && [ "$line" = '}' ]; } || { [ "$mode" = if ] && [ "$line" = 'fi' ]; }; then
                emit_or_skip
                mode=''
            fi
            continue
        fi

        # blank line or comment: hold it until we know whether the unit
        # that follows gets added
        case $line in
            '' | "$cchar"*) pending+="$line"$'\n'; continue ;;
        esac

        unit=$line
        unit_lines=1
        if [[ $line =~ $RE_FUNC ]]; then
            kind=func; name=${BASH_REMATCH[1]}
            [[ $line == *\} ]] || mode=func
        elif [[ $line == 'if '* ]]; then
            kind=line; name=''
            mode=if
        elif [[ $line =~ $RE_ALIAS ]]; then
            kind=alias; name=${BASH_REMATCH[1]}
        elif [[ $line =~ $RE_PROMPT ]]; then
            kind=var; name=${BASH_REMATCH[2]}
        else
            kind=line; name=''
        fi
        [ -z "$mode" ] && emit_or_skip
    done < "$src"

    # a function/if that never closed (should not happen) - add it as-is
    # rather than silently dropping it
    [ -n "$mode" ] && emit_or_skip
    unset -f emit_or_skip
}

# join_kept - the KEPT list as "a, b, c"
join_kept() {
    local out='' k
    for k in "${KEPT[@]}"; do out+="${out:+, }$k"; done
    printf '%s' "$out"
}

# sync_rc FILE COMMENT_CHAR - rebuild the managed block in ~/FILE from the
# repo copy. Shell rc files get the brew PATH line first, since brew's
# folder differs per machine and so cannot live in the repo file. Steps:
# take the user's file without any previous block (their own content), work
# out which units it lacks, and append those as a fresh block. The file is
# only rewritten if the result differs, so an unchanged re-run reports
# "already up to date".
sync_rc() {
    local file=$1 cchar=$2
    local repo_src="$REPO_DIR/$file" src="$TMP_DIR/$file.src" dest="$HOME/$file"
    local base="$TMP_DIR/$file.base" body="$TMP_DIR/$file.body" new="$TMP_DIR/$file.new"

    if [ ! -f "$repo_src" ]; then
        report "~/$file" "SKIPPED - $file not found in ~/SystemConfiguration"
        return 1
    fi
    {
        if [ "$cchar" = '#' ] && [ -n "$BREW_BIN" ]; then
            printf '%s\n' '# Homebrew (puts brew and everything it installs on the PATH)'
            printf 'eval "$(%s shellenv)"\n' "$BREW_BIN"
        fi
        cat "$repo_src"
    } > "$src"

    config_markers "$cchar"
    touch "$dest" || { report "~/$file" "SKIPPED - cannot write"; return 1; }

    strip_block "$CFG_BEGIN" "$CFG_END" < "$dest"
    build_block "$src" "$base" "$cchar" > "$body"

    cp "$base" "$new"
    if [ -s "$body" ]; then
        {
            printf '%s\n' "$CFG_BEGIN"
            cat "$body"
            printf '%s\n' "$CFG_END"
        } >> "$new"
    fi

    local kept_msg=''
    [ ${#KEPT[@]} -gt 0 ] && kept_msg=" - kept yours: $(join_kept)"

    if cmp -s "$new" "$dest"; then
        report "~/$file" "already up to date${kept_msg}"
    else
        cp "$new" "$dest"
        if [ "$ADDED_LINES" -gt 0 ]; then
            report "~/$file" "added $ADDED_LINES lines${kept_msg}"
        else
            report "~/$file" "nothing to add, you already have everything${kept_msg}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    # As root, $HOME is /root and Homebrew refuses to run at all.
    if [ "$EUID" -eq 0 ]; then
        say "Do not run this with sudo - run it as your normal user. It asks for the password when needed."
        exit 1
    fi

    case $(uname -s) in
        Darwin) OS=mac ;;
        Linux)  OS=linux ;;
        *)      say "Unsupported OS: $(uname -s)"; exit 1 ;;
    esac

    mkdir -p "$TMP_DIR"

    case ${1-} in
        ''|-upgrade)
            # Get git + the latest repo, then hand over to the repo's own
            # init.sh, so a fix pushed to the repo is used on this very run.
            say "Repo"
            step_git
            step_repo
            [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
            exec bash "$REPO_DIR/init.sh" --after-pull
            ;;
        --after-pull)
            ;;
        *)
            say "Usage:  bash init.sh          set everything up"
            say "        init.sh -upgrade      fetch the latest repo and apply it"
            exit 1
            ;;
    esac

    say ""
    say "Homebrew & shell"
    step_brew
    step_zsh

    say ""
    say "Tools"
    step_packages

    say ""
    say "Config"
    sync_braverat
    local rec
    for rec in "${RC_FILES[@]}"; do
        sync_rc "${rec%%::*}" "${rec#*::}"
    done

    say ""
    say "Done. Start zsh now with:  zsh      (new terminals open in zsh)"
    say "To fetch updates later:    ~/SystemConfiguration/init.sh -upgrade"
    say "To undo the config:        ~/SystemConfiguration/rmconfig.sh"
}

main "$@"
