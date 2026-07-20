#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"
OMARCHY_TREE="${1:-$REPO_DIR/omarchy}"
INSTALLER="$REPO_DIR/bin/install-omarchy-on-cachyos.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local expected="$1" actual="$2" message="$3"

    if [ "$actual" != "$expected" ]; then
        echo "Expected: $expected" >&2
        echo "Actual  : $actual" >&2
        fail "$message"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" message="$3"

    grep -qF -- "$needle" <<< "$haystack" || fail "$message"
}

# Sourcing exposes pure helpers without executing main.
# shellcheck source=../bin/install-omarchy-on-cachyos.sh
source "$INSTALLER"

wrapped_hyprland_info='Repository      : cachyos-extra
Name            : hyprland
Version         : 1.0.0-1
Depends On      : cairo  aquamarine
                  libaquamarine.so=12-64
                  wayland
Optional Deps   : None'

assert_equal \
    "libaquamarine.so=12-64" \
    "$(package_info_soname "$wrapped_hyprland_info" "Depends On" libaquamarine.so)" \
    "wrapped dependency metadata must retain the Aquamarine SONAME"

if ! (
    is_cachyos() { return 0; }
    enforce_verified_package_pair() { return 0; }
    pacman() {
        case "$*" in
            *"-Si hyprland")
                printf '%s\n' "$wrapped_hyprland_info"
                ;;
            *"-Si aquamarine")
                printf '%s\n' 'Repository      : cachyos-extra
Name            : aquamarine
Version         : 2.0.0-1
Provides        : libaquamarine.so=12-64
Depends On      : wayland'
                ;;
            *"-Q hyprland"|*"-Q aquamarine")
                return 1
                ;;
            *)
                return 1
                ;;
        esac
    }
    check_hyprland_aquamarine_alignment /tmp/mock-sync-db >/dev/null
); then
    fail "compatible wrapped metadata should pass the ABI guard"
fi

if (
    is_cachyos() { return 0; }
    pacman() { return 1; }
    check_hyprland_aquamarine_alignment /tmp/mock-sync-db >/dev/null 2>&1
); then
    fail "missing package metadata must fail closed"
fi

test_root="$(mktemp -d /tmp/omarchy-installer-tests.XXXXXX)"
cleanup() {
    case "$test_root" in
        /tmp/omarchy-installer-tests.*)
            rm -rf -- "$test_root"
            ;;
        *)
            fail "refusing to clean unexpected test directory: $test_root"
            ;;
    esac
}
trap cleanup EXIT

login_test_root="$test_root/login"
mkdir -p "$login_test_root/systemd" "$login_test_root/etc/sddm.conf.d" "$login_test_root/sessions"
touch "$login_test_root/systemd/sddm.service" "$login_test_root/systemd/plasmalogin.service"
ln -s "$login_test_root/systemd/sddm.service" "$login_test_root/display-manager.service"
printf '%s\n' '[Autologin]' 'Session=omarchy' > "$login_test_root/etc/sddm.conf.d/90-omarchy.conf"

if ! (
    export ENABLE_AUTOLOGIN=1
    export DISPLAY_MANAGER_LINK="$login_test_root/display-manager.service"
    export SDDM_OMARCHY_CONFIG="$login_test_root/etc/sddm.conf.d/90-omarchy.conf"
    validate_post_install_login >/dev/null
); then
    fail "autologin validation must accept an SDDM Omarchy next-boot target"
fi

rm "$login_test_root/display-manager.service"
ln -s "$login_test_root/systemd/plasmalogin.service" "$login_test_root/display-manager.service"
if (
    export ENABLE_AUTOLOGIN=1
    export DISPLAY_MANAGER_LINK="$login_test_root/display-manager.service"
    export SDDM_OMARCHY_CONFIG="$login_test_root/etc/sddm.conf.d/90-omarchy.conf"
    validate_post_install_login >/dev/null 2>&1
); then
    fail "autologin validation must reject a display-manager target that remains on Plasma"
fi

touch "$login_test_root/sessions/omarchy.desktop"
if ! (
    export ENABLE_AUTOLOGIN=0
    export LOCAL_OMARCHY_SESSION="$login_test_root/sessions/omarchy.desktop"
    export SYSTEM_OMARCHY_SESSION="$login_test_root/sessions/missing.desktop"
    validate_post_install_login >/dev/null
); then
    fail "manual login validation must accept an installed Omarchy session"
fi

validate_compatibility_manifest >/dev/null || fail "repository compatibility manifest must be valid"
compatibility_manifest_has_pair "0.55.4-1.1" "0.12.1-1.1" ||
    fail "current verified CachyOS package pair must be present"

test_manifest="$test_root/compatibility.tsv"
printf '%s\t%s\t%s\t%s\n' \
    "1.0.0-1" "2.0.0-1" "2026-07-19" "test evidence" > "$test_manifest"

if ! (
    COMPATIBILITY_FILE="$test_manifest"
    INSTALL_MODE="production"
    ALLOW_UNVERIFIED_PACKAGE_PAIR=0
    enforce_verified_package_pair "1.0.0-1" "2.0.0-1" >/dev/null
); then
    fail "a manifest-listed package pair must pass in production"
fi

if (
    COMPATIBILITY_FILE="$test_manifest"
    INSTALL_MODE="production"
    ALLOW_UNVERIFIED_PACKAGE_PAIR=0
    enforce_verified_package_pair "1.0.1-1" "2.0.0-1" >/dev/null 2>&1
); then
    fail "an unverified package pair must fail closed in production"
fi

if (
    COMPATIBILITY_FILE="$test_root/does-not-exist.tsv"
    INSTALL_MODE="staging"
    ALLOW_UNVERIFIED_PACKAGE_PAIR=1
    enforce_verified_package_pair "1.0.1-1" "2.0.0-1" >/dev/null 2>&1
); then
    fail "staging must not bypass a missing compatibility manifest"
fi

if ! (
    COMPATIBILITY_FILE="$test_manifest"
    INSTALL_MODE="staging"
    ALLOW_UNVERIFIED_PACKAGE_PAIR=1
    enforce_verified_package_pair "1.0.1-1" "2.0.0-1" >/dev/null
); then
    fail "the explicit staging option must allow an unverified pair"
fi

malformed_manifest="$test_root/compatibility-malformed.tsv"
printf '%s\n' '1.0.0-1 2.0.0-1 missing-tabs' > "$malformed_manifest"
if (
    export COMPATIBILITY_FILE="$malformed_manifest"
    INSTALL_MODE="staging"
    ALLOW_UNVERIFIED_PACKAGE_PAIR=1
    enforce_verified_package_pair "1.0.0-1" "2.0.0-1" >/dev/null 2>&1
); then
    fail "staging must not bypass a malformed compatibility manifest"
fi

if ! (
    INSTALL_MODE="production"
    ALLOW_UNVERIFIED_PACKAGE_PAIR=0
    parse_args --staging-allow-unverified-pair
    assert_equal "staging" "$INSTALL_MODE" "staging option must mark the run as staging"
    assert_equal "1" "$ALLOW_UNVERIFIED_PACKAGE_PAIR" "staging option must enable the unverified-pair exception"
); then
    fail "staging option parsing should succeed"
fi

snapshot_log="$test_root/snapshot.log"
snapshot_output="$test_root/snapshot-output.log"
if ! (
    root_filesystem_type() { echo btrfs; }
    snapper() { return 0; }
    snapper_root_config_exists() { return 0; }
    sudo() {
        printf '%s\n' "$*" >> "$snapshot_log"
        case "$*" in
            *"--type pre"*) printf '%s\n' 42 ;;
            *"--type post"*) printf '%s\n' 43 ;;
            *) return 1 ;;
        esac
    }
    ALLOW_NO_SNAPSHOT=0
    detected_bootloader() { echo grub; }
    create_preinstall_snapshot > "$snapshot_output"
    assert_equal "42" "$SNAPPER_PRE_NUMBER" "pre-install snapshot number must be retained"
    assert_contains \
        "sudo snapper -c root rollback 42 && sudo reboot" \
        "$(<"$snapshot_output")" \
        "snapshot creation must print the exact Snapper fallback command"
    assert_contains \
        "sudo -E btrfs-assistant" \
        "$(<"$snapshot_output")" \
        "GRUB recovery must print CachyOS's supported Btrfs Assistant command"
    create_postinstall_snapshot >> "$snapshot_output"
    assert_equal "43" "$SNAPPER_POST_NUMBER" "post-install snapshot number must be retained"
); then
    fail "available BTRFS/Snapper protection should create a pre/post pair"
fi
assert_contains "--type pre" "$(<"$snapshot_log")" "Snapper pre snapshot command must be executed"
assert_contains "--type post" "$(<"$snapshot_log")" "Snapper post snapshot command must be executed"

if (
    check_snapshot_readiness() { return 1; }
    ALLOW_NO_SNAPSHOT=0
    create_preinstall_snapshot >/dev/null 2>&1
); then
    fail "production must stop when no rollback snapshot can be created"
fi

if ! (
    check_snapshot_readiness() { return 1; }
    export ALLOW_NO_SNAPSHOT=1
    create_preinstall_snapshot >/dev/null
    [ -z "$SNAPPER_PRE_NUMBER" ]
); then
    fail "--allow-no-snapshot must be the explicit no-snapshot exception"
fi

if ! (
    is_cachyos() { return 0; }
    installed_package_version() {
        case "$1" in
            hyprland) echo 1.0.0-1 ;;
            aquamarine) echo 2.0.0-1 ;;
        esac
    }
    hyprland_binary_path() { echo /usr/bin/Hyprland; }
    dynamic_link_report() { echo 'libaquamarine.so.12 => /usr/lib/libaquamarine.so.12'; }
    run_hyprland_version() { echo 'Hyprland 1.0.0'; }
    EXPECTED_HYPRLAND_VERSION="1.0.0-1"
    EXPECTED_AQUAMARINE_VERSION="2.0.0-1"
    export EXPECTED_HYPRLAND_REPOSITORY="cachyos-extra"
    validate_post_install_hyprland >/dev/null
); then
    fail "matching installed versions, links, and version probe must pass post-install validation"
fi

if (
    is_cachyos() { return 0; }
    installed_package_version() {
        case "$1" in
            hyprland) echo 1.0.1-1 ;;
            aquamarine) echo 2.0.0-1 ;;
        esac
    }
    export EXPECTED_HYPRLAND_VERSION="1.0.0-1"
    export EXPECTED_AQUAMARINE_VERSION="2.0.0-1"
    validate_post_install_hyprland >/dev/null 2>&1
); then
    fail "post-install validation must reject version drift"
fi

if (
    is_cachyos() { return 0; }
    installed_package_version() {
        case "$1" in
            hyprland) echo 1.0.0-1 ;;
            aquamarine) echo 2.0.0-1 ;;
        esac
    }
    hyprland_binary_path() { echo /usr/bin/Hyprland; }
    dynamic_link_report() {
        printf '%s\n' \
            'libaquamarine.so.12 => /usr/lib/libaquamarine.so.12' \
            'libbroken.so => not found'
    }
    EXPECTED_HYPRLAND_VERSION="1.0.0-1"
    EXPECTED_AQUAMARINE_VERSION="2.0.0-1"
    validate_post_install_hyprland >/dev/null 2>&1
); then
    fail "post-install validation must reject unresolved dynamic libraries"
fi

if (
    is_cachyos() { return 0; }
    installed_package_version() {
        case "$1" in
            hyprland) echo 1.0.0-1 ;;
            aquamarine) echo 2.0.0-1 ;;
        esac
    }
    hyprland_binary_path() { echo /usr/bin/Hyprland; }
    dynamic_link_report() { echo 'libaquamarine.so.12 => /usr/lib/libaquamarine.so.12'; }
    run_hyprland_version() { return 1; }
    EXPECTED_HYPRLAND_VERSION="1.0.0-1"
    EXPECTED_AQUAMARINE_VERSION="2.0.0-1"
    validate_post_install_hyprland >/dev/null 2>&1
); then
    fail "post-install validation must reject a failing Hyprland --version probe"
fi

claude_test_root="$test_root/claude"
claude_npm_root="$claude_test_root/usr/lib/node_modules/@anthropic-ai/claude-code"
mkdir -p "$claude_test_root/usr/bin" "$claude_npm_root/bin"
touch "$claude_npm_root/bin/claude.exe" "$claude_test_root/usr/bin/npm"
chmod +x "$claude_test_root/usr/bin/npm"
ln -s ../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe "$claude_test_root/usr/bin/claude"

if ! (
    SYSTEM_CLAUDE_PATH="$claude_test_root/usr/bin/claude"
    export SYSTEM_CLAUDE_NPM_ROOT="$claude_npm_root"
    export SYSTEM_NPM_PATH="$claude_test_root/usr/bin/npm"
    pacman() { return 1; }
    sudo() { rm -f -- "$SYSTEM_CLAUDE_PATH"; }
    remove_conflicting_unmanaged_claude_code >/dev/null
    [[ ! -e "$SYSTEM_CLAUDE_PATH" && ! -L "$SYSTEM_CLAUDE_PATH" ]]
); then
    fail "the known unmanaged global Claude Code npm link should be replaced"
fi

ln -s ../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe "$claude_test_root/usr/bin/claude"
if ! (
    SYSTEM_CLAUDE_PATH="$claude_test_root/usr/bin/claude"
    pacman() { return 0; }
    sudo() { return 1; }
    remove_conflicting_unmanaged_claude_code >/dev/null
    [[ -L "$SYSTEM_CLAUDE_PATH" ]]
); then
    fail "a pacman-owned Claude Code path must be preserved"
fi

rm -f -- "$claude_test_root/usr/bin/claude"
ln -s /opt/unexpected/claude "$claude_test_root/usr/bin/claude"
if (
    SYSTEM_CLAUDE_PATH="$claude_test_root/usr/bin/claude"
    pacman() { return 1; }
    remove_conflicting_unmanaged_claude_code >/dev/null 2>&1
); then
    fail "an unexpected unowned Claude Code path must fail closed"
fi

required_config="$test_root/pacman-required.conf"
optional_config="$test_root/pacman-optional.conf"
invalid_server_config="$test_root/pacman-invalid-server.conf"
missing_repo_config="$test_root/pacman-missing-repo.conf"
duplicate_siglevel_config="$test_root/pacman-duplicate-siglevel.conf"

cat > "$required_config" <<'EOF'
[options]
Architecture = x86_64
SigLevel = Required DatabaseOptional TrustedOnly

[omarchy]
SigLevel = Required DatabaseOptional TrustedOnly
Server = https://pkgs.omarchy.org/$arch
EOF

sed 's/^SigLevel = Required DatabaseOptional TrustedOnly$/SigLevel = Optional TrustedOnly/' \
    "$required_config" > "$optional_config"
sed 's|https://pkgs.omarchy.org/$arch|https://packages.invalid/$arch|' \
    "$required_config" > "$invalid_server_config"
sed '/^\[omarchy\]$/,$d' "$required_config" > "$missing_repo_config"
sed '/^SigLevel = Required DatabaseOptional TrustedOnly$/a SigLevel = Optional TrustedOnly' \
    "$required_config" > "$duplicate_siglevel_config"

validate_omarchy_repo_config "$required_config" >/dev/null || fail "required Omarchy signatures should validate"
if ! (
    pacman-conf() {
        case "$*" in
            *"--repo omarchy Server") printf '%s\n' 'https://pkgs.omarchy.org/x86_64' ;;
            *"Architecture") printf '%s\n' x86_64 x86_64_v2 x86_64_v3 x86_64_v4 ;;
            *) return 1 ;;
        esac
    }
    validate_omarchy_repo_server "$required_config" >/dev/null
); then
    fail "CachyOS multi-line architecture output must use the primary repo expansion"
fi
if validate_omarchy_repo_config "$optional_config" >/dev/null 2>&1; then
    fail "optional Omarchy package signatures must be rejected"
fi

if ! (
    sudo() { "$@"; }
    export PACMAN_CONF_PATH="$optional_config"
    configure_omarchy_repo
    validate_omarchy_repo_config "$optional_config" >/dev/null
); then
    fail "legacy Optional TrustedOnly repo config should migrate to required signatures"
fi

if (
    sudo() { "$@"; }
    export PACMAN_CONF_PATH="$invalid_server_config"
    configure_omarchy_repo >/dev/null 2>&1
); then
    fail "an existing Omarchy repo with an unexpected server must be rejected"
fi

if ! (
    sudo() { "$@"; }
    export PACMAN_CONF_PATH="$missing_repo_config"
    configure_omarchy_repo
    validate_omarchy_repo_config "$missing_repo_config" >/dev/null
); then
    fail "a missing Omarchy repo should be added with the secure canonical configuration"
fi

if (
    sudo() { "$@"; }
    export PACMAN_CONF_PATH="$duplicate_siglevel_config"
    configure_omarchy_repo >/dev/null 2>&1
); then
    fail "multiple Omarchy SigLevel directives must be rejected"
fi

setup_log="$test_root/setup-order.log"
expected_setup_log="$test_root/setup-order.expected"
if ! (
    sudo() { printf 'sudo %s\n' "$*" >> "$setup_log"; }
    configure_omarchy_repo() { echo configure-repo >> "$setup_log"; }
    check_hyprland_aquamarine_alignment() { echo abi-check >> "$setup_log"; }
    setup_omarchy_repo
); then
    fail "mocked Omarchy repository setup should complete"
fi

cat > "$expected_setup_log" <<EOF
sudo pacman-key --recv-keys $OMARCHY_KEY_ID
sudo pacman-key --lsign-key $OMARCHY_KEY_ID
configure-repo
sudo pacman -Sy
abi-check
sudo pacman -S --needed --noconfirm omarchy-keyring
sudo pacman -Su
EOF
cmp -s "$expected_setup_log" "$setup_log" || fail "ABI check must run after the only system sync and before pacman -Su"

repair_source="$OMARCHY_TREE/install/post-install/cachyos-mkinitcpio-hooks.sh"
[ -f "$repair_source" ] || fail "prepared mkinitcpio repair script is missing: $repair_source"

if ! (
    cd "$OMARCHY_TREE"
    export ENABLE_AUTOLOGIN=1
    patch_sddm_script
    grep -qF "CachyOS SDDM autologin integration" install/login/sddm.sh
    grep -qF 'systemctl disable "$CURRENT_DISPLAY_MANAGER"' install/login/sddm.sh
    grep -qF "90-omarchy.conf" install/login/sddm.sh
    bash -n install/login/sddm.sh

    export ENABLE_AUTOLOGIN=0
    patch_sddm_script
    grep -qF "Minimal SDDM integration" install/login/sddm.sh
    grep -qF "/usr/share/wayland-sessions/omarchy.desktop" install/login/sddm.sh
    bash -n install/login/sddm.sh
); then
    fail "SDDM patching must support both activated and manually selectable login modes"
fi

if ! (
    cd "$OMARCHY_TREE"
    terminal_defaults="$(terminal_defaults_file)"
    index_before="$(sha256sum .git/index | awk '{print $1}')"
    restore_standard_application_defaults
    index_after="$(sha256sum .git/index | awk '{print $1}')"
    assert_equal "$index_before" "$index_after" "standard default checks must not modify the Git index"

    printf '%s\n' 'legacy-custom-terminal.desktop' > "$terminal_defaults"
    printf '%s\n' legacy-custom-package >> install/omarchy-base.packages

    restore_standard_application_defaults
    assert_equal \
        "$(git show HEAD:install/omarchy-base.packages)" \
        "$(<install/omarchy-base.packages)" \
        "standard packages must be restored from upstream"
    assert_equal \
        "$(git show "HEAD:$terminal_defaults")" \
        "$(<"$terminal_defaults")" \
        "standard terminal defaults must be restored from upstream"

    # Return the prepared tree to its standard adapter state for later checks.
    sed -i '/^tldr$/d' install/omarchy-base.packages
); then
    fail "standard application defaults must remove legacy personal overrides"
fi

chromium_helper="$OMARCHY_TREE/install/config/cachyos-chromium-preferences.sh"
[ -f "$chromium_helper" ] || fail "prepared Chromium preferences helper is missing: $chromium_helper"
bash -n "$chromium_helper" || fail "prepared Chromium preferences helper must parse"

chromium_home="$test_root/chromium-home"
chromium_omarchy="$test_root/chromium-omarchy"
mkdir -p "$chromium_home/.config/chromium/Default" "$chromium_omarchy/config/chromium/Default"
printf '%s\n' '{"browser":{"theme":{"legacy":true}},"extensions":{"settings":{"keep":true}},"profile":{"name":"Existing"}}' \
    > "$chromium_home/.config/chromium/Default/Preferences"
printf '%s\n' '{"browser":{"theme":{"color_scheme":2,"user_color":2}},"extensions":{"theme":{"id":""}}}' \
    > "$chromium_omarchy/config/chromium/Default/Preferences"

if ! (
    export HOME="$chromium_home"
    export OMARCHY_PATH="$chromium_omarchy"
    # shellcheck source=/dev/null
    source "$chromium_helper"
    cachyos_copy_config_preserving_chromium_preferences
); then
    fail "Chromium preferences preservation helper should complete"
fi

chromium_preferences="$chromium_home/.config/chromium/Default/Preferences"
assert_equal "Existing" "$(jq -r '.profile.name' "$chromium_preferences")" "existing Chromium profile settings must survive"
assert_equal "true" "$(jq -r '.extensions.settings.keep' "$chromium_preferences")" "existing Chromium extension settings must survive"
assert_equal "2" "$(jq -r '.browser.theme.color_scheme' "$chromium_preferences")" "Omarchy Chromium theme defaults must be merged"
assert_equal "2" "$(jq -r '.browser.theme.user_color' "$chromium_preferences")" "Omarchy Chromium color default must be merged"

hooks_dir="$test_root/hooks"
repair_probe="$test_root/cachyos-mkinitcpio-hooks.sh"
mkdir -p "$hooks_dir"
sed "s|hooks_dir=\"/usr/share/libalpm/hooks\"|hooks_dir=\"$hooks_dir\"|" "$repair_source" > "$repair_probe"

probe_output="$(bash -c 'source "$1"; echo POST_INSTALL_CONTINUED' probe "$repair_probe")"
assert_contains "POST_INSTALL_CONTINUED" "$probe_output" "repair script must not exit its sourcing installer"

printf '%s\n' active > "$hooks_dir/60-mkinitcpio-remove.hook"
printf '%s\n' disabled > "$hooks_dir/60-mkinitcpio-remove.hook.disabled"
probe_output="$(bash -c 'source "$1"; echo POST_INSTALL_CONTINUED' probe "$repair_probe")"
assert_contains "POST_INSTALL_CONTINUED" "$probe_output" "active-hook collision path must return to the installer"
assert_equal "active" "$(<"$hooks_dir/60-mkinitcpio-remove.hook")" "active hook must not be overwritten"
assert_equal "disabled" "$(<"$hooks_dir/60-mkinitcpio-remove.hook.disabled")" "disabled backup must remain untouched on collision"

rm -f "$hooks_dir/60-mkinitcpio-remove.hook"
probe_output="$(bash -c '
    sudo() {
        if [ "$1" = mv ]; then
            shift
            command mv "$@"
        else
            return 0
        fi
    }
    source "$1"
    echo POST_INSTALL_CONTINUED
' probe "$repair_probe")"
assert_contains "Regenerating initramfs" "$probe_output" "restoring a missing active hook must trigger initramfs regeneration"
assert_contains "POST_INSTALL_CONTINUED" "$probe_output" "restoration path must return to the installer"
assert_equal "disabled" "$(<"$hooks_dir/60-mkinitcpio-remove.hook")" "missing active hook must be restored"
[ ! -e "$hooks_dir/60-mkinitcpio-remove.hook.disabled" ] || fail "restored disabled hook should be moved into active place"

echo "Installer regression tests passed."
