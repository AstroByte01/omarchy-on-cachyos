#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OMARCHY_DIR="$REPO_DIR/omarchy"
OMARCHY_INSTALL_DIR="$HOME/.local/share/omarchy"
OMARCHY_KEY_FINGERPRINT="40DFB630FF42BCFFB047046CF0134EE680CAC571"
OMARCHY_KEY_ID="F0134EE680CAC571"

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
    echo "  6. Install yay only if missing, using a temporary build directory."
    echo "  7. Import and locally sign Omarchy package key: $OMARCHY_KEY_ID"
    echo "  8. Check CachyOS Hyprland/Aquamarine package alignment before package changes."
    echo "  9. Add the Omarchy pacman repo if missing, then install omarchy-keyring."
    echo " 10. Backup /etc/sddm.conf before removing it, only when autologin is enabled."
    echo " 11. Copy patched Omarchy files to: $OMARCHY_INSTALL_DIR"
    echo " 12. Run Omarchy's patched install.sh unless --prepare-only is used."
}

ensure_tooling() {
    for cmd in curl git sudo pacman; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: $cmd is required before running this script."
            exit 1
        fi
    done
}

first_sync_package_field() {
    local package="$1" field="$2"

    pacman -Si "$package" 2>/dev/null | awk -v field="$field" '
        $1 == "Repository" && found == 0 { in_first = 1 }
        in_first && index($0, field " ") == 1 {
            sub("^[^:]+:[[:space:]]*", "")
            print
            exit
        }
        in_first && $0 == "" { exit }
    '
}

first_sync_package_soname() {
    local package="$1" field="$2" soname="$3"

    first_sync_package_field "$package" "$field" | tr ' ' '\n' | grep -E "^${soname}=.*" | head -n 1 || true
}

installed_package_version() {
    pacman -Q "$1" 2>/dev/null | awk '{print $2}' || true
}

check_hyprland_aquamarine_alignment() {
    local hypr_repo hypr_version hypr_aquamarine_dep
    local aqua_repo aqua_version aqua_provides
    local installed_hypr installed_aqua

    is_cachyos || return 0

    echo "Checking CachyOS Hyprland/Aquamarine package alignment..."

    hypr_repo="$(first_sync_package_field hyprland Repository)"
    hypr_version="$(first_sync_package_field hyprland Version)"
    hypr_aquamarine_dep="$(first_sync_package_soname hyprland "Depends On" libaquamarine.so)"
    aqua_repo="$(first_sync_package_field aquamarine Repository)"
    aqua_version="$(first_sync_package_field aquamarine Version)"
    aqua_provides="$(first_sync_package_soname aquamarine Provides libaquamarine.so)"

    if [ -z "$hypr_repo" ] || [ -z "$hypr_version" ] || [ -z "$aqua_repo" ] || [ -z "$aqua_version" ]; then
        echo "Warning: Could not inspect hyprland/aquamarine sync packages; continuing."
        return 0
    fi

    echo "  hyprland   : $hypr_version from $hypr_repo"
    echo "  aquamarine : $aqua_version from $aqua_repo"

    if [[ "$hypr_repo" != cachyos-* ]] || [[ "$aqua_repo" != cachyos-* ]]; then
        echo "Error: hyprland/aquamarine are not both resolving from CachyOS repos."
        echo "This can expose upstream Omarchy issue #6224-style Hyprland/Aquamarine ABI skew."
        echo "Run a full CachyOS system update and make sure both packages resolve from CachyOS repos before installing Omarchy."
        exit 1
    fi

    if [ "$hypr_repo" != "$aqua_repo" ]; then
        echo "Error: hyprland and aquamarine resolve from different repos: $hypr_repo vs $aqua_repo."
        echo "This can expose upstream Omarchy issue #6224-style Hyprland/Aquamarine ABI skew."
        exit 1
    fi

    if [ -n "$hypr_aquamarine_dep" ] && [ -n "$aqua_provides" ] && [ "$hypr_aquamarine_dep" != "$aqua_provides" ]; then
        echo "Error: hyprland requires $hypr_aquamarine_dep but aquamarine provides $aqua_provides."
        echo "Update CachyOS mirrors/package databases before installing Omarchy."
        exit 1
    fi

    installed_hypr="$(installed_package_version hyprland)"
    installed_aqua="$(installed_package_version aquamarine)"

    if [ "$installed_hypr" = "0.55.4-1" ] && [ "$installed_aqua" = "0.12.1-1" ]; then
        echo "Error: installed hyprland/aquamarine match the known risky pair from Omarchy issue #6224."
        echo "Run a full CachyOS update before installing Omarchy."
        exit 1
    fi

    return 0
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
    echo "Restoring $hook.hook"
    sudo mv "$hooks_dir/$hook.hook.disabled" "$hooks_dir/$hook.hook"
    restored=1
  fi
done

if (( restored == 0 )); then
  exit 0
fi

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

patch_th3rig_profile() {
    local packages_file="install/omarchy-base.packages"
    local terminal_defaults=""
    local fallback_terminal=""

    verify_patch "profile th3rig: package list" "$packages_file" "^xdg-terminal-exec$" present required
    verify_patch "profile th3rig: ghostty config" "config/ghostty/config" "window-theme = ghostty" present required

    if [ -f "default/xdg-terminal-exec/hyprland-xdg-terminals.list" ]; then
        terminal_defaults="default/xdg-terminal-exec/hyprland-xdg-terminals.list"
    elif [ -f "config/xdg-terminals.list" ]; then
        terminal_defaults="config/xdg-terminals.list"
    else
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
            record_patch "Kept upstream Omarchy application defaults"
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

setup_omarchy_repo() {
    local key_file

    if ! sudo pacman-key --recv-keys "$OMARCHY_KEY_ID"; then
        key_file="$(mktemp /tmp/omarchy-key.XXXXXX.asc)"
        curl -fsSLo "$key_file" "https://keys.openpgp.org/vks/v1/by-fingerprint/$OMARCHY_KEY_FINGERPRINT"
        sudo pacman-key --add "$key_file"
        rm -f "$key_file"
    fi

    sudo pacman-key --lsign-key "$OMARCHY_KEY_ID"

    if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
        printf '\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/$arch\n' | sudo tee -a /etc/pacman.conf >/dev/null
    else
        echo "Omarchy repository already present in pacman.conf, skipping."
    fi

    sudo pacman -Sy --needed --noconfirm omarchy-keyring
    sudo pacman -Syu
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
    validate_profile
    print_preflight

    if [ "$DRY_RUN" = "1" ]; then
        if command -v pacman >/dev/null 2>&1; then
            check_hyprland_aquamarine_alignment
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

    check_hyprland_aquamarine_alignment
    install_yay_if_missing
    setup_omarchy_repo
    backup_sddm_conf_for_autologin
    copy_to_install_dir

    cd "$OMARCHY_INSTALL_DIR"
    print_install_summary
    chmod +x install.sh
    ./install.sh
}

main
