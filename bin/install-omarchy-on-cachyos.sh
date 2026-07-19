#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OMARCHY_DIR="$REPO_DIR/omarchy"
OMARCHY_INSTALL_DIR="$HOME/.local/share/omarchy"
OMARCHY_KEY_FINGERPRINT="40DFB630FF42BCFFB047046CF0134EE680CAC571"
OMARCHY_KEY_ID="F0134EE680CAC571"
OMARCHY_REPO_SERVER='https://pkgs.omarchy.org/$arch'
PACMAN_CONF_PATH="/etc/pacman.conf"

DRY_RUN=0
PREPARE_ONLY=0
ENABLE_AUTOLOGIN=""
ENABLE_IWD_BACKEND=""
OMARCHY_REF="${OMARCHY_REF:-}"
OMARCHY_PROFILE="${OMARCHY_PROFILE:-upstream}"
APPLIED_PATCHES=()

export OMARCHY_DIR

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --dry-run             Show checks and planned system changes, then exit.
  --prepare-only        Fetch and patch Omarchy, then stop before sudo/system changes.
  --ref <tag|branch>    Fetch this Omarchy version without the interactive menu.
                        Also honored from the OMARCHY_REF environment variable.
  --profile <name>      Apply an optional customization profile after CachyOS
                        patches. Supported: upstream, th3rig.
                        Also honored from the OMARCHY_PROFILE environment variable.
  --auto-login          Allow Omarchy to configure SDDM autologin.
  --no-auto-login       Keep the existing display-manager login flow.
  --network-iwd         Configure NetworkManager to use iwd and disable wpa_supplicant.
  --keep-network        Do not change NetworkManager/wpa_supplicant behavior.
  -h, --help            Show this help.
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            --prepare-only)
                PREPARE_ONLY=1
                ;;
            --ref)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    echo "Error: --ref requires a value (an Omarchy tag or branch)."
                    exit 1
                fi
                OMARCHY_REF="$2"
                shift
                ;;
            --profile)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    echo "Error: --profile requires a value."
                    exit 1
                fi
                OMARCHY_PROFILE="$2"
                shift
                ;;
            --auto-login)
                ENABLE_AUTOLOGIN=1
                ;;
            --no-auto-login)
                ENABLE_AUTOLOGIN=0
                ;;
            --network-iwd)
                ENABLE_IWD_BACKEND=1
                ;;
            --keep-network)
                ENABLE_IWD_BACKEND=0
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

    export OMARCHY_REF
    export OMARCHY_PROFILE
}

validate_profile() {
    case "$OMARCHY_PROFILE" in
        upstream|th3rig)
            ;;
        *)
            echo "Error: Unsupported profile '$OMARCHY_PROFILE'. Supported profiles: upstream, th3rig."
            exit 1
            ;;
    esac
}

prompt_bool() {
    local prompt="$1"
    local default="$2"
    local answer

    while true; do
        read -r -p "$prompt" answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done
}

prompt_identity() {
    if [[ ! "${OMARCHY_USER_NAME:-}" =~ ^[[:print:]]{1,80}$ ]]; then
        echo ""
        echo "Please enter your name for git commits and Omarchy shortcuts:"
        while true; do
            read -r OMARCHY_USER_NAME
            if [[ "$OMARCHY_USER_NAME" =~ ^[[:print:]]{1,80}$ ]]; then
                break
            fi
            echo "Please enter 1-80 printable characters."
        done
    fi
    export OMARCHY_USER_NAME

    if [ -z "${OMARCHY_USER_EMAIL+x}" ]; then
        echo ""
        echo "Please enter your email for git commits. Leave blank to skip:"
        while true; do
            read -r OMARCHY_USER_EMAIL
            if [[ -z "$OMARCHY_USER_EMAIL" || "$OMARCHY_USER_EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]; then
                break
            fi
            echo "Invalid email format. Try again or leave blank to skip:"
        done
    elif [[ -n "$OMARCHY_USER_EMAIL" && ! "$OMARCHY_USER_EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]; then
        echo "Error: OMARCHY_USER_EMAIL is set but is not a valid email address."
        exit 1
    fi
    export OMARCHY_USER_EMAIL
}

is_cachyos() {
    if [ -f /etc/cachyos-release ] || [ -d /etc/cachyos ]; then
        return 0
    fi

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        [ "${ID:-}" = "cachyos" ] && return 0
    fi

    return 1
}

print_preflight() {
    local distro="unknown"
    local root_fs="unknown"
    local secure_boot="unknown"
    local desktop="none detected"
    local display_manager="none detected"
    local nvidia="not detected"

    if is_cachyos; then
        distro="CachyOS"
    elif [ -f /etc/arch-release ]; then
        distro="Arch-compatible, not CachyOS"
    fi

    root_fs="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"

    if bootctl status 2>/dev/null | grep -q "Secure Boot: enabled"; then
        secure_boot="enabled"
    elif command -v bootctl >/dev/null 2>&1; then
        secure_boot="disabled or unavailable"
    fi

    if command -v pacman >/dev/null 2>&1; then
        if pacman -Qe plasma-desktop >/dev/null 2>&1; then
            desktop="KDE Plasma"
        elif pacman -Qe gnome-shell >/dev/null 2>&1; then
            desktop="GNOME"
        elif pacman -Qe hyprland >/dev/null 2>&1; then
            desktop="Hyprland"
        fi
    fi

    if systemctl is-enabled plasmalogin.service >/dev/null 2>&1; then
        display_manager="plasmalogin.service enabled"
    elif systemctl is-enabled sddm.service >/dev/null 2>&1; then
        display_manager="sddm.service enabled"
    elif systemctl is-enabled gdm.service >/dev/null 2>&1; then
        display_manager="gdm.service enabled"
    fi

    if command -v lspci >/dev/null 2>&1 && lspci -nn -d 10de: | grep -qE "VGA|3D"; then
        nvidia="detected"
    fi

    echo ""
    echo "Preflight summary"
    echo "  Distro            : $distro"
    echo "  Root filesystem   : $root_fs"
    echo "  Secure Boot       : $secure_boot"
    echo "  Desktop           : $desktop"
    echo "  Display manager   : $display_manager"
    echo "  NVIDIA GPU        : $nvidia"
    echo "  Profile           : $OMARCHY_PROFILE"
    echo "  Omarchy workdir   : $OMARCHY_DIR"
    echo "  Install target    : $OMARCHY_INSTALL_DIR"
    echo ""

    if ! is_cachyos; then
        echo "Warning: This adapter is intended for CachyOS."
    fi

    if [ "$root_fs" != "btrfs" ]; then
        echo "Warning: Root filesystem is '$root_fs'. The README recommends BTRFS with Snapper."
    fi

    if [ "$secure_boot" = "enabled" ]; then
        echo "Warning: Omarchy expects Secure Boot to be disabled."
    fi
}

print_dry_run() {
    echo "Dry run: no files, packages, services, drivers, or /etc configs will be changed."
    echo ""
    echo "Planned actions if run normally:"
    echo "  1. Fetch Omarchy into: $OMARCHY_DIR (interactive version menu, or --ref/OMARCHY_REF)."
    echo "  2. Ask for autologin and NetworkManager/iwd preferences (plus name/email for full installs)."
    echo "  3. Patch Omarchy for CachyOS: remove tldr, disable the pacman.conf replacement,"
    echo "     keep mkinitcpio hooks active, disable the Plymouth/limine-snapper/hibernation steps,"
    echo "     replace the NVIDIA setup,"
    echo "     relax the distro/desktop/bootloader/filesystem guards, force AI-skill symlinks,"
    echo "     pin walker, and optionally configure iwd and a selectable SDDM session."
    echo "  4. Apply the selected profile overlay: $OMARCHY_PROFILE."
    echo "  5. Verify every patch after applying it, aborting if upstream Omarchy has drifted."
    echo "  6. Refresh isolated package metadata and verify Hyprland/Aquamarine alignment."
    echo "  7. Install yay only if missing, using a temporary build directory."
    echo "  8. Import and locally sign Omarchy package key: $OMARCHY_KEY_ID"
    echo "  9. Validate or add the signature-required Omarchy pacman repository."
    echo " 10. Sync pacman once, recheck the exact transaction metadata, then update."
    echo " 11. Backup /etc/sddm.conf before removing it, only when autologin is enabled."
    echo " 12. Copy patched Omarchy files to: $OMARCHY_INSTALL_DIR"
    echo " 13. Run Omarchy's patched install.sh unless --prepare-only is used."
}

ensure_tooling() {
    for cmd in curl fakeroot git pacman pacman-conf realpath sudo; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: $cmd is required before running this script."
            exit 1
        fi
    done
}

first_sync_package_info() {
    local package="$1" sync_db_path="${2:-}"
    local -a pacman_args=()

    if [ -n "$sync_db_path" ]; then
        pacman_args+=(--dbpath "$sync_db_path")
    fi
    pacman_args+=(-Si "$package")

    # Consume all repo results so pipefail cannot turn an intentional first-
    # result selection into SIGPIPE. C locale and a wide output prevent
    # localized or terminal-width-dependent field names and wrapping.
    LC_ALL=C COLUMNS=10000 pacman "${pacman_args[@]}" 2>/dev/null | awk '
        /^Repository[[:space:]]*:/ { block++ }
        block == 1 { print }
        END { if (block == 0) exit 1 }
    '
}

package_info_field() {
    local package_info="$1" field="$2"

    awk -v field="$field" '
        function emit(value) {
            sub(/^[[:space:]]+/, "", value)
            if (length(value) > 0) {
                printf "%s%s", separator, value
                separator = " "
            }
        }
        {
            if (!found) {
                key = $0
                sub(/[[:space:]]*:.*/, "", key)
                if (key == field) {
                    value = $0
                    sub(/^[^:]+:[[:space:]]*/, "", value)
                    emit(value)
                    found = 1
                }
                next
            }

            if ($0 ~ /^[[:space:]]+/) {
                emit($0)
                next
            }

            exit
        }
        END {
            if (!found) exit 1
            print ""
        }
    ' <<< "$package_info"
}

package_info_soname() {
    local package_info="$1" field="$2" soname="$3"
    local field_value token
    local -a tokens=()

    if ! field_value="$(package_info_field "$package_info" "$field")"; then
        return 1
    fi

    read -ra tokens <<< "$field_value"
    for token in "${tokens[@]}"; do
        if [[ "$token" == "$soname="* ]]; then
            printf '%s\n' "$token"
            return 0
        fi
    done

    return 1
}

installed_package_version() {
    LC_ALL=C pacman -Q "$1" 2>/dev/null | awk '{print $2}' || true
}

cleanup_fresh_sync_db() {
    local sync_db_path="$1"
    local temp_root canonical_path

    temp_root="$(realpath -m -- "${TMPDIR:-/tmp}")"
    canonical_path="$(realpath -m -- "$sync_db_path")"

    case "$canonical_path" in
        "$temp_root"/omarchy-pacman-db.*)
            rm -rf -- "$canonical_path"
            ;;
        *)
            echo "Error: Refusing to remove unexpected temporary pacman database: $canonical_path" >&2
            return 1
            ;;
    esac
}

create_fresh_sync_db() {
    local sync_db_path system_db_path
    local required_cmd

    for required_cmd in fakeroot pacman pacman-conf realpath; do
        if ! command -v "$required_cmd" >/dev/null 2>&1; then
            echo "Error: $required_cmd is required to check current CachyOS package metadata without modifying the system database." >&2
            return 1
        fi
    done

    sync_db_path="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-pacman-db.XXXXXX")"
    system_db_path="$(pacman-conf DBPath)"

    if [ ! -d "$system_db_path/local" ]; then
        echo "Error: pacman's installed-package database is missing: $system_db_path/local" >&2
        cleanup_fresh_sync_db "$sync_db_path"
        return 1
    fi

    ln -s "$system_db_path/local" "$sync_db_path/local"

    echo "Refreshing package metadata in an isolated temporary database..." >&2
    if ! LC_ALL=C fakeroot -- pacman -Sy --noconfirm --disable-sandbox-filesystem \
        --dbpath "$sync_db_path" --logfile /dev/null >&2; then
        echo "Error: Could not refresh temporary pacman databases; package alignment was not verified." >&2
        cleanup_fresh_sync_db "$sync_db_path"
        return 1
    fi

    printf '%s\n' "$sync_db_path"
}

check_hyprland_aquamarine_alignment() {
    local sync_db_path="${1:-}"
    local hypr_repo hypr_version hypr_aquamarine_dep
    local aqua_repo aqua_version aqua_provides
    local installed_hypr installed_aqua
    local hypr_info aqua_info

    is_cachyos || return 0

    echo "Checking CachyOS Hyprland/Aquamarine package alignment..."

    if ! hypr_info="$(first_sync_package_info hyprland "$sync_db_path")"; then
        echo "Error: Could not inspect the current hyprland sync package; refusing to continue without the ABI check."
        return 1
    fi
    if ! aqua_info="$(first_sync_package_info aquamarine "$sync_db_path")"; then
        echo "Error: Could not inspect the current aquamarine sync package; refusing to continue without the ABI check."
        return 1
    fi

    if ! hypr_repo="$(package_info_field "$hypr_info" Repository)" ||
        ! hypr_version="$(package_info_field "$hypr_info" Version)" ||
        ! hypr_aquamarine_dep="$(package_info_soname "$hypr_info" "Depends On" libaquamarine.so)" ||
        ! aqua_repo="$(package_info_field "$aqua_info" Repository)" ||
        ! aqua_version="$(package_info_field "$aqua_info" Version)" ||
        ! aqua_provides="$(package_info_soname "$aqua_info" Provides libaquamarine.so)"; then
        echo "Error: Hyprland/Aquamarine metadata is incomplete; refusing to skip the ABI check."
        return 1
    fi

    echo "  hyprland   : $hypr_version from $hypr_repo"
    echo "  aquamarine : $aqua_version from $aqua_repo"

    if [[ "$hypr_repo" != cachyos-* ]] || [[ "$aqua_repo" != cachyos-* ]]; then
        echo "Error: hyprland/aquamarine are not both resolving from CachyOS repos."
        echo "This can expose upstream Omarchy issue #6224-style Hyprland/Aquamarine ABI skew."
        echo "Run a full CachyOS system update and make sure both packages resolve from CachyOS repos before installing Omarchy."
        return 1
    fi

    if [ "$hypr_repo" != "$aqua_repo" ]; then
        echo "Error: hyprland and aquamarine resolve from different repos: $hypr_repo vs $aqua_repo."
        echo "This can expose upstream Omarchy issue #6224-style Hyprland/Aquamarine ABI skew."
        return 1
    fi

    if [ "$hypr_aquamarine_dep" != "$aqua_provides" ]; then
        echo "Error: hyprland requires $hypr_aquamarine_dep but aquamarine provides $aqua_provides."
        echo "Update CachyOS mirrors/package databases before installing Omarchy."
        return 1
    fi

    installed_hypr="$(installed_package_version hyprland)"
    installed_aqua="$(installed_package_version aquamarine)"

    if [ "$installed_hypr" = "0.55.4-1" ] && [ "$installed_aqua" = "0.12.1-1" ]; then
        echo "Error: installed hyprland/aquamarine match the known risky pair from Omarchy issue #6224."
        echo "Run a full CachyOS update before installing Omarchy."
        return 1
    fi

    return 0
}

check_fresh_hyprland_aquamarine_alignment() {
    local sync_db_path status=0

    is_cachyos || return 0

    if ! sync_db_path="$(create_fresh_sync_db)"; then
        return 1
    fi

    if ! check_hyprland_aquamarine_alignment "$sync_db_path"; then
        status=1
    fi

    cleanup_fresh_sync_db "$sync_db_path" || return 1
    return "$status"
}

fetch_omarchy() {
    echo "Fetching Omarchy source..."

    if [ ! -f "$SCRIPT_DIR/fetch-omarchy.sh" ]; then
        echo "Error: fetch-omarchy.sh is missing from $SCRIPT_DIR."
        echo "The adapter checkout is incomplete; re-clone the omarchy-on-cachyos repository."
        exit 1
    fi

    bash "$SCRIPT_DIR/fetch-omarchy.sh"

    if [ ! -d "$OMARCHY_DIR" ]; then
        echo "Error: Failed to fetch Omarchy source at $OMARCHY_DIR"
        exit 1
    fi
}

record_patch() {
    APPLIED_PATCHES+=("$1")
}

# verify_patch <name> <file> <ERE pattern> <present|absent> [required]
#
# Guards against upstream drift: a sed that matches nothing exits 0, so every
# patch must assert its expected post-state here. A missing file is a skip
# (feature absent in the selected Omarchy ref) unless marked required.
verify_patch() {
    local name="$1" file="$2" pattern="$3" expect="$4" requirement="${5:-}"

    if [ ! -f "$file" ]; then
        if [ "$requirement" = "required" ]; then
            echo "Error: [$name] expected file is missing: $file"
            echo "Upstream Omarchy has likely changed (patch drift). Re-run selecting a release"
            echo "this adapter supports (see the CI badge in the README), or update the adapter."
            exit 1
        fi
        echo "Warning: [$name] $file not found in this Omarchy ref; skipping."
        return 0
    fi

    local ok=0
    if grep -Eq "$pattern" "$file"; then
        [ "$expect" = "present" ] && ok=1
    else
        [ "$expect" = "absent" ] && ok=1
    fi

    if [ "$ok" -ne 1 ]; then
        echo "Error: [$name] expected pattern '$pattern' to be $expect in $file."
        echo "Upstream Omarchy has likely changed (patch drift). Re-run selecting a release"
        echo "this adapter supports (see the CI badge in the README), or update the adapter."
        exit 1
    fi
}

remove_run_logged() {
    local file="$1"
    local script_path="$2"

    if [ ! -f "$file" ]; then
        echo "Error: [disable $script_path] $file is missing from this Omarchy ref."
        echo "Upstream Omarchy has likely changed (patch drift). Re-run selecting a release"
        echo "this adapter supports (see the CI badge in the README), or update the adapter."
        exit 1
    fi

    # Delete any wiring of the script (run_logged or source), so a future
    # upstream switch to 'source' cannot silently re-enable the step.
    sed -i "\#$script_path#d" "$file"
    verify_patch "disable $script_path" "$file" "$script_path" absent required
    record_patch "Disabled Omarchy install step: $script_path"
}

# Restore a file to its upstream state from the git checkout the fetch
# produced. Used when a previous run applied an opt-in patch that the
# current flags no longer want.
restore_upstream_file() {
    local file="$1" name="$2"

    if ! git checkout -- "$file" 2>/dev/null; then
        echo "Error: [$name] could not restore upstream $file (not a git checkout?)."
        echo "Refetch Omarchy cleanly: re-run with OMARCHY_ON_EXISTING=replace or delete $OMARCHY_DIR."
        exit 1
    fi
}

patch_guard_for_cachyos() {
    local guard_file="install/preflight/guard.sh"

    verify_patch "guard relaxations" "$guard_file" "abort" present required

    if grep -q "CachyOS compatibility guard relaxations" "$guard_file"; then
        record_patch "Kept previously relaxed Omarchy install guards"
        return 0
    fi

    sed -i '1i# CachyOS compatibility guard relaxations: distro, desktop, bootloader, and filesystem constraints are handled by the adapter preflight.' "$guard_file"
    sed -i 's# /etc/cachyos-release##g; s#/etc/cachyos-release ##g; s#/etc/cachyos-release##g' "$guard_file"
    sed -i '/# Must not have Gnome or KDE already install/,/fi/s/^/# CachyOS compat disabled: /' "$guard_file"
    sed -i 's/^command -v limine /# CachyOS compat disabled: command -v limine /' "$guard_file"
    sed -i 's/^\[\[ $(findmnt -n -o FSTYPE \/).*$/# CachyOS compat disabled: Btrfs root filesystem guard skipped by adapter/' "$guard_file"

    verify_patch "guard: derivative-distro check" "$guard_file" "cachyos-release" absent required
    verify_patch "guard: desktop check disabled" "$guard_file" "# CachyOS compat disabled: if pacman -Qe gnome-shell" present required
    verify_patch "guard: limine check disabled" "$guard_file" "# CachyOS compat disabled: command -v limine" present required
    verify_patch "guard: btrfs check disabled" "$guard_file" "Btrfs root filesystem guard skipped by adapter" present required
    verify_patch "guard: no stacked patching" "$guard_file" "CachyOS compat disabled: # CachyOS compat disabled" absent required
    record_patch "Relaxed Omarchy's distro/desktop/bootloader/filesystem install guards"
}

patch_network_script() {
    local network_file="install/config/hardware/network.sh"

    if [ "$ENABLE_IWD_BACKEND" != "1" ]; then
        if [ -f "$network_file" ] && grep -q "CachyOS NetworkManager iwd backend" "$network_file"; then
            restore_upstream_file "$network_file" "network iwd rollback"
            verify_patch "network iwd rollback" "$network_file" "CachyOS NetworkManager iwd backend" absent required
            record_patch "Removed previously added iwd backend block (keeping wpa_supplicant)"
        else
            record_patch "Kept existing NetworkManager/wpa_supplicant behavior"
        fi
        return 0
    fi

    if [ ! -f "$network_file" ]; then
        echo "Warning: [network iwd backend] $network_file not found in this Omarchy ref; skipping."
        return 0
    fi

    if grep -q "CachyOS NetworkManager iwd backend" "$network_file"; then
        verify_patch "network iwd backend" "$network_file" "wifi\.backend=iwd" present required
        record_patch "NetworkManager already configured to use the iwd WiFi backend"
        return 0
    fi

    cat >> "$network_file" <<'NETEOF'

# CachyOS NetworkManager iwd backend
sudo systemctl disable --now wpa_supplicant.service 2>/dev/null || true
sudo install -Dm644 /dev/stdin /etc/NetworkManager/conf.d/omarchy-iwd.conf <<'EOF'
[device]
wifi.backend=iwd
EOF
NETEOF

    verify_patch "network iwd backend" "$network_file" "wifi\.backend=iwd" present required
    record_patch "Configured NetworkManager to use the iwd WiFi backend during install"
}

patch_walker_script() {
    local walker_file="install/config/walker-elephant.sh"

    if [ ! -f "$walker_file" ]; then
        echo "Warning: [walker repo pin] $walker_file not found in this Omarchy ref; skipping."
        return 0
    fi

    if grep -q "CachyOS walker repo pin" "$walker_file"; then
        record_patch "Walker package pinning already in place (IgnorePkg)"
        return 0
    fi

    sed -i '2i\
# CachyOS walker repo pin\
if ! grep -Eq "^IgnorePkg = (.*[[:space:]])?walker([[:space:]]|$)" /etc/pacman.conf 2>/dev/null; then\
  if grep -q "^IgnorePkg =" /etc/pacman.conf 2>/dev/null; then\
    sudo sed -i '"'"'0,/^IgnorePkg = /s/^IgnorePkg = /IgnorePkg = walker /'"'"' /etc/pacman.conf\
  else\
    sudo sed -i '"'"'/^\\[options\\]/a IgnorePkg = walker'"'"' /etc/pacman.conf\
  fi\
fi\
' "$walker_file"

    verify_patch "walker repo pin" "$walker_file" "CachyOS walker repo pin" present required
    record_patch "Pinned walker via IgnorePkg so pacman keeps the Omarchy build"
}

patch_sddm_script() {
    local sddm_file="install/login/sddm.sh"
    local session_file="default/wayland-sessions/omarchy.desktop"

    if [ "$ENABLE_AUTOLOGIN" != "0" ]; then
        if [ -f "$sddm_file" ] && grep -q "Minimal SDDM integration" "$sddm_file"; then
            restore_upstream_file "$sddm_file" "sddm autologin restore"
            verify_patch "sddm autologin restore" "$sddm_file" "Minimal SDDM integration" absent required
            record_patch "Restored Omarchy's own SDDM autologin setup (autologin allowed)"
        else
            record_patch "Autologin allowed: kept Omarchy's own SDDM autologin setup"
        fi
        return 0
    fi

    if [ ! -f "$sddm_file" ]; then
        echo "Warning: [sddm minimal session] $sddm_file not found in this Omarchy ref; skipping."
        return 0
    fi

    # The replacement script copies this file at install time; fail now, not then.
    verify_patch "sddm session desktop file" "$session_file" "uwsm" present required

    cat > "$sddm_file" <<'SDDMEOF'
#!/bin/bash
set -e

# Minimal SDDM integration: install Omarchy as a selectable Wayland session.
sudo mkdir -p /usr/local/share/wayland-sessions
sudo cp "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
SDDMEOF
    chmod +x "$sddm_file"

    verify_patch "sddm minimal session" "$sddm_file" "Minimal SDDM integration" present required
    record_patch "Replaced SDDM autologin setup with a selectable Omarchy session"
}

patch_mkinitcpio_hooks_for_cachyos() {
    local post_install_all="install/post-install/all.sh"
    local restore_script="install/post-install/cachyos-mkinitcpio-hooks.sh"

    remove_run_logged "install/preflight/all.sh" "preflight/disable-mkinitcpio.sh"

    cat > "$restore_script" <<'MKINITCPIOEOF'
#!/bin/bash
# Sourced directly by post-install/all.sh (not run_logged/bash -c isolated),
# so no 'set' here: install.sh already runs under 'set -eEo pipefail' and
# adding -u would leak nounset into finished.sh, which runs right after.

hooks_dir="/usr/share/libalpm/hooks"
restored=0

for hook in 60-mkinitcpio-remove 90-mkinitcpio-install; do
  if [[ -f "$hooks_dir/$hook.hook.disabled" ]]; then
    if [[ -f "$hooks_dir/$hook.hook" ]]; then
      echo "Keeping active $hook.hook; leaving the older disabled copy untouched"
      continue
    fi

    echo "Restoring $hook.hook"
    sudo mv "$hooks_dir/$hook.hook.disabled" "$hooks_dir/$hook.hook"
    restored=1
  fi
done

if (( restored > 0 )); then
  echo "Regenerating initramfs after restoring mkinitcpio pacman hooks..."

  if [[ -x /usr/share/libalpm/scripts/mkinitcpio ]]; then
    targets=()
    shopt -s nullglob
    for vmlinuz in /usr/lib/modules/*/vmlinuz; do
      targets+=("${vmlinuz#/}")
    done
    shopt -u nullglob

    if (( ${#targets[@]} > 0 )); then
      printf '%s\n' "${targets[@]}" | sudo /usr/share/libalpm/scripts/mkinitcpio install
    else
      sudo mkinitcpio -P
    fi
  elif command -v mkinitcpio >/dev/null 2>&1; then
    sudo mkinitcpio -P
  else
    echo "Warning: mkinitcpio is unavailable; hooks were restored but initramfs was not regenerated."
  fi
fi
MKINITCPIOEOF
    chmod +x "$restore_script"

    verify_patch "mkinitcpio restore script" "$restore_script" "Regenerating initramfs" present required

    if [ ! -f "$post_install_all" ]; then
        echo "Error: [mkinitcpio post-install wiring] expected file is missing: $post_install_all"
        echo "Upstream Omarchy has likely changed (patch drift). Re-run selecting a release"
        echo "this adapter supports (see the CI badge in the README), or update the adapter."
        exit 1
    fi

    if ! grep -q "post-install/cachyos-mkinitcpio-hooks.sh" "$post_install_all"; then
        if grep -q "post-install/finished.sh" "$post_install_all"; then
            sed -i '\#post-install/finished.sh#i source $OMARCHY_INSTALL/post-install/cachyos-mkinitcpio-hooks.sh' "$post_install_all"
        else
            printf '\nsource $OMARCHY_INSTALL/post-install/cachyos-mkinitcpio-hooks.sh\n' >> "$post_install_all"
        fi
    fi

    verify_patch "mkinitcpio preflight disable removed" "install/preflight/all.sh" "preflight/disable-mkinitcpio.sh" absent required
    verify_patch "mkinitcpio post-install wiring" "$post_install_all" "post-install/cachyos-mkinitcpio-hooks.sh" present required
    record_patch "Kept mkinitcpio pacman hooks active and added a post-install repair for stranded disabled hooks"
}

terminal_defaults_file() {
    if [ -f "default/xdg-terminal-exec/hyprland-xdg-terminals.list" ]; then
        printf '%s\n' "default/xdg-terminal-exec/hyprland-xdg-terminals.list"
    elif [ -f "config/xdg-terminals.list" ]; then
        printf '%s\n' "config/xdg-terminals.list"
    else
        return 1
    fi
}

patch_upstream_profile() {
    local packages_file="install/omarchy-base.packages"
    local terminal_defaults upstream_packages

    if ! terminal_defaults="$(terminal_defaults_file)"; then
        echo "Error: [profile upstream: terminal defaults] no xdg-terminal-exec defaults file was found."
        echo "Upstream Omarchy has likely changed (patch drift). Re-run selecting a release"
        echo "this adapter supports (see the CI badge in the README), or update the adapter."
        exit 1
    fi

    restore_upstream_file "$terminal_defaults" "profile upstream terminal defaults"

    if ! upstream_packages="$(git show "HEAD:$packages_file")"; then
        echo "Error: [profile upstream: package list] could not read upstream $packages_file."
        exit 1
    fi

    if grep -qxF ghostty <<< "$upstream_packages"; then
        verify_patch "profile upstream: upstream ghostty package" "$packages_file" "^ghostty$" present required
    else
        sed -i '/^ghostty$/d' "$packages_file"
        verify_patch "profile upstream: remove overlay ghostty package" "$packages_file" "^ghostty$" absent required
    fi

    if ! git diff --quiet -- "$terminal_defaults"; then
        echo "Error: [profile upstream: terminal defaults] failed to restore $terminal_defaults."
        exit 1
    fi

    record_patch "Restored upstream Omarchy application defaults"
}

patch_th3rig_profile() {
    local packages_file="install/omarchy-base.packages"
    local terminal_defaults
    local fallback_terminal=""

    verify_patch "profile th3rig: package list" "$packages_file" "^xdg-terminal-exec$" present required
    verify_patch "profile th3rig: ghostty config" "config/ghostty/config" "window-theme = ghostty" present required

    if ! terminal_defaults="$(terminal_defaults_file)"; then
        echo "Error: [profile th3rig: terminal defaults] no xdg-terminal-exec defaults file was found."
        echo "Upstream Omarchy has likely changed (patch drift). Re-run selecting a release"
        echo "this adapter supports (see the CI badge in the README), or update the adapter."
        exit 1
    fi

    if ! grep -qxF ghostty "$packages_file"; then
        if grep -qxF foot "$packages_file"; then
            sed -i '/^foot$/a ghostty' "$packages_file"
        elif grep -qxF alacritty "$packages_file"; then
            sed -i '/^alacritty$/a ghostty' "$packages_file"
        else
            printf '\nghostty\n' >> "$packages_file"
        fi
    fi
    verify_patch "profile th3rig: ghostty package" "$packages_file" "^ghostty$" present required

    fallback_terminal="$(grep -vE '^[[:space:]]*($|#)' "$terminal_defaults" | grep -vxF "com.mitchellh.ghostty.desktop" | head -n 1 || true)"
    if [ -z "$fallback_terminal" ]; then
        if grep -qxF foot "$packages_file"; then
            fallback_terminal="foot.desktop"
        elif grep -qxF alacritty "$packages_file"; then
            fallback_terminal="Alacritty.desktop"
        fi
    fi

    if [ -z "$fallback_terminal" ]; then
        echo "Error: [profile th3rig: terminal fallback] could not determine an upstream fallback terminal."
        echo "Upstream Omarchy has likely changed (patch drift). Re-run selecting a release"
        echo "this adapter supports (see the CI badge in the README), or update the adapter."
        exit 1
    fi

    cat > "$terminal_defaults" <<'TERMINALSEOF'
# Terminal emulator preference order for xdg-terminal-exec
# The first found and valid terminal will be used
com.mitchellh.ghostty.desktop
TERMINALSEOF
    printf '%s\n' "$fallback_terminal" >> "$terminal_defaults"

    verify_patch "profile th3rig: ghostty default terminal" "$terminal_defaults" "^com\\.mitchellh\\.ghostty\\.desktop$" present required
    verify_patch "profile th3rig: fallback terminal" "$terminal_defaults" "^${fallback_terminal//./\\.}$" present required
    record_patch "Applied th3rig profile: Ghostty is installed and preferred, with $fallback_terminal as fallback"
}

patch_profile() {
    case "$OMARCHY_PROFILE" in
        upstream)
            patch_upstream_profile
            ;;
        th3rig)
            patch_th3rig_profile
            ;;
    esac
}

patch_omarchy() {
    echo "Patching Omarchy for CachyOS compatibility..."
    cd "$OMARCHY_DIR"

    sed -i '/^tldr$/d' install/omarchy-base.packages
    verify_patch "tldr removal" install/omarchy-base.packages '^tldr$' absent required
    record_patch "Removed tldr from the package list to preserve CachyOS tealdeer"

    # Canary: upstream detects kernel updates by scanning /usr/lib/modules/*/vmlinuz,
    # which works with linux-cachyos kernels unpatched. Fail if that ever changes.
    verify_patch "update-restart kernel detection" bin/omarchy-update-restart 'vmlinuz' present

    remove_run_logged "install/preflight/all.sh" "preflight/pacman.sh"
    patch_mkinitcpio_hooks_for_cachyos
    remove_run_logged "install/login/all.sh" "login/plymouth.sh"
    remove_run_logged "install/login/all.sh" "login/limine-snapper.sh"
    remove_run_logged "install/login/all.sh" "login/hibernation.sh"
    remove_run_logged "install/post-install/all.sh" "post-install/pacman.sh"

    cp "$SCRIPT_DIR/nvidia.sh" install/config/hardware/nvidia.sh
    chmod +x install/config/hardware/nvidia.sh
    verify_patch "nvidia replacement" install/config/hardware/nvidia.sh 'NVIDIA configuration for Omarchy on CachyOS' present required
    record_patch "Replaced NVIDIA setup with CachyOS-aware driver detection"

    # Omarchy <= v3.7.x creates AI-skill symlinks with plain 'ln -s', which
    # fails on re-install; v3.8.0+ already uses 'ln -sfn' and is left alone.
    if [ -f install/config/omarchy-ai-skill.sh ]; then
        sed -i 's/^ln -s /ln -sfn /' install/config/omarchy-ai-skill.sh
        verify_patch "ai-skill symlinks" install/config/omarchy-ai-skill.sh '^ln -s ' absent required
        verify_patch "ai-skill symlinks forced" install/config/omarchy-ai-skill.sh 'ln -sfn' present required
        record_patch "Ensured AI-skill symlinks are created with ln -sfn"
    fi

    # Old releases activate mise with 'mise activate bash' (bash-only hooks);
    # upgrade them to the --shims form, a plain PATH prepend that uwsm exports
    # session-wide, so fish sessions inherit it too. Current releases already
    # ship --shims and are left untouched.
    if [ -f config/uwsm/env ] && grep -q 'mise activate' config/uwsm/env; then
        sed -i 's/mise activate bash)"/mise activate bash --shims)"/' config/uwsm/env
        verify_patch "mise shims activation" config/uwsm/env 'mise activate bash --shims' present required
        record_patch "Verified mise activation uses the shell-agnostic --shims form"
    fi

    patch_guard_for_cachyos
    patch_network_script
    patch_walker_script
    patch_sddm_script
    patch_profile
}

install_yay_if_missing() {
    local yay_dir

    if command -v yay >/dev/null 2>&1; then
        echo "yay is already installed."
        return 0
    fi

    echo "yay is not installed. Installing yay..."
    sudo pacman -S --needed --noconfirm git base-devel

    yay_dir="$(mktemp -d /tmp/yay.XXXXXX)"
    git clone https://aur.archlinux.org/yay.git "$yay_dir"
    (
        cd "$yay_dir"
        makepkg -si --noconfirm
    )
    rm -rf "$yay_dir"

    if ! command -v yay >/dev/null 2>&1; then
        echo "Error: Failed to install yay."
        exit 1
    fi
}

omarchy_repo_is_configured() {
    local config_file="$1"
    local repo_list

    if ! repo_list="$(LC_ALL=C pacman-conf -c "$config_file" --repo-list 2>/dev/null)"; then
        return 1
    fi

    grep -qxF omarchy <<< "$repo_list"
}

omarchy_repo_directive_count() {
    local config_file="$1" directive="$2"

    awk -v directive="$directive" '
        /^[[:space:]]*\[omarchy\][[:space:]]*$/ { in_repo = 1; next }
        in_repo && /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { exit }
        in_repo {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ "^" directive "[[:space:]]*=") count++
        }
        END { print count + 0 }
    ' "$config_file"
}

validate_omarchy_repo_server() {
    local config_file="$1"
    local architecture expected_server server_output
    local -a servers=()

    if ! architecture="$(LC_ALL=C pacman-conf -c "$config_file" Architecture 2>/dev/null)" || [ -z "$architecture" ]; then
        echo "Error: Could not determine pacman architecture from $config_file."
        return 1
    fi
    expected_server="${OMARCHY_REPO_SERVER/\$arch/$architecture}"

    if ! server_output="$(LC_ALL=C pacman-conf -c "$config_file" --repo omarchy Server 2>/dev/null)" || [ -z "$server_output" ]; then
        echo "Error: [omarchy] has no readable Server in $config_file."
        return 1
    fi
    mapfile -t servers <<< "$server_output"

    if [ "${#servers[@]}" -ne 1 ] || [ "${servers[0]}" != "$expected_server" ]; then
        echo "Error: Existing [omarchy] repo does not use the expected server: $expected_server"
        return 1
    fi
}

validate_omarchy_repo_config() {
    local config_file="$1"
    local siglevel_output token
    local package_required=0 package_trusted=0 database_optional=0 database_trusted=0

    if ! omarchy_repo_is_configured "$config_file"; then
        echo "Error: [omarchy] is missing from $config_file."
        return 1
    fi
    validate_omarchy_repo_server "$config_file" || return 1

    if ! siglevel_output="$(LC_ALL=C pacman-conf -c "$config_file" --repo omarchy SigLevel 2>/dev/null)"; then
        echo "Error: Could not inspect [omarchy] SigLevel in $config_file."
        return 1
    fi

    while IFS= read -r token; do
        case "$token" in
            PackageRequired) package_required=1 ;;
            PackageTrustedOnly) package_trusted=1 ;;
            DatabaseOptional) database_optional=1 ;;
            DatabaseTrustedOnly) database_trusted=1 ;;
            *)
                echo "Error: Unsafe or unsupported [omarchy] SigLevel token: $token"
                return 1
                ;;
        esac
    done <<< "$siglevel_output"

    if (( ! package_required || ! package_trusted || ! database_optional || ! database_trusted )); then
        echo "Error: [omarchy] must use Required DatabaseOptional TrustedOnly signatures."
        return 1
    fi
}

configure_omarchy_repo() {
    local siglevel_count

    if omarchy_repo_is_configured "$PACMAN_CONF_PATH"; then
        validate_omarchy_repo_server "$PACMAN_CONF_PATH" || exit 1

        siglevel_count="$(omarchy_repo_directive_count "$PACMAN_CONF_PATH" SigLevel)"
        case "$siglevel_count" in
            0)
                sudo sed -i '/^[[:space:]]*\[omarchy\][[:space:]]*$/a SigLevel = Required DatabaseOptional TrustedOnly' "$PACMAN_CONF_PATH"
                ;;
            1)
                sudo sed -i '/^[[:space:]]*\[omarchy\][[:space:]]*$/,/^[[:space:]]*\[[^]]\+\][[:space:]]*$/ s/^[[:space:]]*SigLevel[[:space:]]*=.*$/SigLevel = Required DatabaseOptional TrustedOnly/' "$PACMAN_CONF_PATH"
                ;;
            *)
                echo "Error: Existing [omarchy] repo contains multiple SigLevel directives; refusing to rewrite it."
                exit 1
                ;;
        esac
    else
        printf '\n[omarchy]\nSigLevel = Required DatabaseOptional TrustedOnly\nServer = %s\n' "$OMARCHY_REPO_SERVER" | sudo tee -a "$PACMAN_CONF_PATH" >/dev/null
    fi

    if ! validate_omarchy_repo_config "$PACMAN_CONF_PATH"; then
        echo "Error: Refusing to synchronize an invalid or insecure [omarchy] repository configuration."
        exit 1
    fi
}

setup_omarchy_repo() {
    local key_file

    if ! sudo pacman-key --recv-keys "$OMARCHY_KEY_ID"; then
        key_file="$(mktemp /tmp/omarchy-key.XXXXXX.asc)"
        curl -fsSLo "$key_file" "https://keys.openpgp.org/vks/v1/by-fingerprint/$OMARCHY_KEY_FINGERPRINT"
        sudo pacman-key --add "$key_file"
        rm -f "$key_file"
    fi

    sudo pacman-key --lsign-key "$OMARCHY_KEY_ID"

    configure_omarchy_repo

    # Refresh once, validate exactly those databases, then upgrade without a
    # second refresh that could change the package set after the ABI check.
    sudo pacman -Sy
    check_hyprland_aquamarine_alignment
    sudo pacman -S --needed --noconfirm omarchy-keyring
    sudo pacman -Su
}

backup_sddm_conf_for_autologin() {
    local backup

    [ "$ENABLE_AUTOLOGIN" = "1" ] || return 0
    [ -f /etc/sddm.conf ] || return 0

    backup="/etc/sddm.conf.omarchy-backup-$(date +%Y%m%d%H%M%S)"
    echo "Backing up /etc/sddm.conf to $backup before removing it."
    sudo cp -a /etc/sddm.conf "$backup"
    sudo rm /etc/sddm.conf
}

copy_to_install_dir() {
    if [ -d "$OMARCHY_INSTALL_DIR" ]; then
        if [ "$OMARCHY_INSTALL_DIR" != "$HOME/.local/share/omarchy" ]; then
            echo "Error: Refusing to remove unexpected install directory: $OMARCHY_INSTALL_DIR"
            exit 1
        fi

        echo "Removing previous Omarchy installation files at $OMARCHY_INSTALL_DIR"
        rm -rf "$OMARCHY_INSTALL_DIR"
    fi

    mkdir -p "$OMARCHY_INSTALL_DIR"
    cp -r "$OMARCHY_DIR"/. "$OMARCHY_INSTALL_DIR"
}

print_applied_patches() {
    local i=1
    local patch

    echo ""
    echo "The following verified adjustments have been completed at $OMARCHY_DIR:"
    for patch in "${APPLIED_PATCHES[@]}"; do
        echo " $i. $patch"
        i=$((i + 1))
    done
}

print_install_summary() {
    print_applied_patches

    if [ "$ENABLE_AUTOLOGIN" = "1" ]; then
        echo ""
        echo "Autologin is enabled; /etc/sddm.conf was backed up first if present."
    fi

    echo ""
    echo "Press Enter to begin the Omarchy installation, or Ctrl-C to stop here."
    read -r
}

main() {
    parse_args "$@"
    validate_profile
    print_preflight

    if [ "$DRY_RUN" = "1" ]; then
        if command -v pacman >/dev/null 2>&1; then
            check_fresh_hyprland_aquamarine_alignment
            echo ""
        fi
        print_dry_run
        exit 0
    fi

    ensure_tooling
    fetch_omarchy

    if [ "$PREPARE_ONLY" != "1" ]; then
        prompt_identity
    fi

    if [ -z "$ENABLE_AUTOLOGIN" ]; then
        if prompt_bool "Enable Omarchy SDDM autologin? [y/N]: " "n"; then
            ENABLE_AUTOLOGIN=1
        else
            ENABLE_AUTOLOGIN=0
        fi
    fi

    if [ -z "$ENABLE_IWD_BACKEND" ]; then
        if prompt_bool "Switch NetworkManager WiFi backend to iwd? [y/N]: " "n"; then
            ENABLE_IWD_BACKEND=1
        else
            ENABLE_IWD_BACKEND=0
        fi
    fi

    patch_omarchy

    if [ "$PREPARE_ONLY" = "1" ]; then
        print_applied_patches
        echo ""
        echo "Prepare-only complete. Patched Omarchy is at: $OMARCHY_DIR"
        exit 0
    fi

    check_fresh_hyprland_aquamarine_alignment
    install_yay_if_missing
    setup_omarchy_repo
    backup_sddm_conf_for_autologin
    copy_to_install_dir

    cd "$OMARCHY_INSTALL_DIR"
    print_install_summary
    chmod +x install.sh
    ./install.sh
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
