#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TARGET="$(cd "$SCRIPT_DIR/.." && pwd)/omarchy"
TARGET_DIR="${OMARCHY_DIR:-$DEFAULT_TARGET}"
REPO_URL="https://github.com/basecamp/omarchy"

REF="${OMARCHY_REF:-}"
ON_EXISTING="${OMARCHY_ON_EXISTING:-}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --ref <tag|branch>    Fetch this Omarchy ref without showing the version menu.
                        Also honored from the OMARCHY_REF environment variable.
  --keep-existing       Reuse an existing checkout without prompting.
                        (env: OMARCHY_ON_EXISTING=keep)
  --force               Delete and re-clone an existing checkout without prompting.
                        (env: OMARCHY_ON_EXISTING=replace)
  -h, --help            Show this help.
EOF
}

while (($#)); do
    case "$1" in
        --ref)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "Error: --ref requires a value (an Omarchy tag or branch)."
                exit 1
            fi
            REF="$2"
            shift
            ;;
        --keep-existing)
            ON_EXISTING="keep"
            ;;
        --force)
            ON_EXISTING="replace"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

resolve_existing_dir() {
    [ -d "$TARGET_DIR" ] || return 0

    local decision="$ON_EXISTING"

    if [ -z "$decision" ]; then
        echo ""
        echo "Warning: An existing installation directory was found at $TARGET_DIR"
        read -r -p "Would you like to delete it and proceed with a clean checkout? [y/N]: " CONFIRM

        if [[ "${CONFIRM,,}" =~ ^(y|yes)$ ]]; then
            decision="replace"
        else
            decision="keep"
        fi
    fi

    case "$decision" in
        keep)
            echo "Proceeding with existing files in $TARGET_DIR."
            exit 0
            ;;
        replace)
            case "$TARGET_DIR" in
                "$DEFAULT_TARGET"|"$HOME"/.cache/omarchy-on-cachyos/*|/tmp/omarchy-on-cachyos.*)
                    echo "Cleaning up previous installation files at $TARGET_DIR..."
                    rm -rf "$TARGET_DIR"
                    ;;
                *)
                    echo "Error: Refusing to remove unexpected target directory: $TARGET_DIR"
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Error: Invalid OMARCHY_ON_EXISTING value: $decision (expected keep or replace)."
            exit 1
            ;;
    esac
}

pick_ref_interactive() {
    echo "Fetching available stable releases from GitHub..."
    mapfile -t RELEASES < <(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null | awk -F/ '{print $3}' | sort -rV | head -n 5)

    if [ "${#RELEASES[@]}" -eq 0 ]; then
        echo "Error: Could not fetch Omarchy release tags."
        exit 1
    fi

    echo "-----------------------------------------------"
    echo "Select the Omarchy version you want to install:"
    echo "-----------------------------------------------"
    echo "1) Stable Release (${RELEASES[0]}) - Recommended"

    for i in "${!RELEASES[@]}"; do
        [ "$i" -eq 0 ] && continue
        echo "$((i+1))) Stable Release (${RELEASES[i]})"
    done

    local bleeding_edge_choice=$(( ${#RELEASES[@]} + 1 ))
    echo "$bleeding_edge_choice) Bleeding Edge (dev branch - Unstable)"

    local choice
    while true; do
        read -r -p "Enter your choice [1]: " choice
        choice="${choice:-1}"

        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$bleeding_edge_choice" ]]; then
            break
        fi

        echo "Invalid choice. Please enter a number between 1 and $bleeding_edge_choice."
    done

    if [ "$choice" -eq "$bleeding_edge_choice" ]; then
        REF=""
        echo "Cloning bleeding-edge dev tree..."
    else
        REF="${RELEASES[$((choice-1))]}"
        echo "Cloning stable version: $REF..."
    fi
}

clone_ref() {
    local branch_args=()

    if [ -n "$REF" ]; then
        branch_args=(--depth 1 -b "$REF")
    fi

    mkdir -p "$(dirname "$TARGET_DIR")"
    echo "Cloning into $TARGET_DIR..."
    git -c advice.detachedHead=false clone --quiet "${branch_args[@]}" "$REPO_URL" "$TARGET_DIR"

    echo "Successfully cloned Omarchy repository layout."
}

resolve_existing_dir

if [ -z "$REF" ]; then
    pick_ref_interactive
else
    echo "Fetching Omarchy ref: $REF..."
fi

clone_ref
