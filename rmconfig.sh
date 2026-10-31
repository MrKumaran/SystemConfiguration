#!/usr/bin/env bash
#
# rmconfig.sh - undo the config init.sh added:
#
#     ~/SystemConfig/rmconfig.sh      (or: bash rmconfig.sh)
#
# init.sh puts everything it adds to ~/.zshrc, ~/.bashrc and ~/.vimrc inside
# ONE marked block. This removes that block (markers included) and leaves
# every other line - your own settings, whether written before or after

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BRAVERAT_DIR="$HOME/.braverat"

# Files we manage, as FILE::COMMENT_CHAR (# for shells, " for vim).
RC_FILES=('.zshrc::#' '.bashrc::#' '.vimrc::"')

# strip_block BEGIN END < file - print the file with the block between
# BEGIN and END (markers included) removed, everything else untouched.
# `|| [ -n "$line" ]` also emits a final line that has no trailing newline.
strip_block() {
    local begin=$1 end=$2 in_block=0 line
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$begin" ]; then in_block=1; continue; fi
        if [ "$line" = "$end" ];   then in_block=0; continue; fi
        [ "$in_block" -eq 1 ] && continue
        printf '%s\n' "$line"
    done
}

report() { printf '  %-20s %s\n' "$1" "$2"; }

# clean_rc FILE COMMENT_CHAR - remove every known fence from ~/FILE.
clean_rc() {
    local file=$1 p=$2 dest="$HOME/$1"
    local fences=(
        "$p$p$p Braverat system config start $p$p$p::$p$p$p Braverat system config end $p$p$p"
    )
    local fence begin end found=0 tmp

    if [ ! -f "$dest" ]; then
        report "~/$file" "does not exist - nothing to do"
        return 0
    fi

    # Only rewrite - and only back up - if a fence is actually present, so
    # running this on an already-clean file is a harmless no-op.
    for fence in "${fences[@]}"; do
        if grep -qxF -- "${fence%%::*}" "$dest"; then found=1; break; fi
    done
    if [ "$found" -eq 0 ]; then
        report "~/$file" "clean - no block from init.sh found"
        return 0
    fi

    cp "$dest" "$dest.bak"

    # Strip every known fence pass by pass, feeding each result into the
    # next, so a file that somehow holds more than one block is fully cleaned.
    tmp="$dest.braverat.$$"
    cp "$dest" "$tmp"
    for fence in "${fences[@]}"; do
        begin=${fence%%::*}
        end=${fence#*::}
        strip_block "$begin" "$end" < "$tmp" > "$tmp.out"
        mv "$tmp.out" "$tmp"
    done
    mv "$tmp" "$dest"
    report "~/$file" "removed the init.sh block (backup: ~/$file.bak)"
}

# clean_braverat - remove each file in ~/.braverat that is still the copy
# init.sh installed from the repo's .braverat. Sub-folders (dotfiles) are
# never touched.
clean_braverat() {
    local src name dest
    if [ ! -d "$SCRIPT_DIR/.braverat" ]; then
        report "~/.braverat" "LEFT ALONE - no .braverat next to rmconfig.sh to compare with"
        return 0
    fi
    for src in "$SCRIPT_DIR/.braverat"/*; do
        [ -f "$src" ] || continue
        name=${src##*/}
        dest="$BRAVERAT_DIR/$name"
        if [ ! -f "$dest" ]; then
            report "~/.braverat/$name" "does not exist - nothing to do"
        elif cmp -s "$src" "$dest"; then
            rm -f "$dest"
            report "~/.braverat/$name" "removed"
        else
            report "~/.braverat/$name" "LEFT ALONE - differs from the repo copy, so you changed it"
        fi
    done
}

main() {
    local rec
    printf 'Removing terminal setup added by init.sh\n\n'
    for rec in "${RC_FILES[@]}"; do
        clean_rc "${rec%%::*}" "${rec#*::}"
    done
    clean_braverat
    printf '\nCleanup done\n'
}

main "$@"
