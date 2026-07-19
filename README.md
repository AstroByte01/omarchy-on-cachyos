# omarchy-on-cachyos

[![CI](https://github.com/AstroByte01/omarchy-on-cachyos/actions/workflows/ci.yml/badge.svg)](https://github.com/AstroByte01/omarchy-on-cachyos/actions/workflows/ci.yml)

Based on [mroboff/omarchy-on-cachyos](https://github.com/mroboff/omarchy-on-cachyos) (MIT); this is an independently maintained continuation.

- UPDATE 19-Jul-2026 (production gates): Production installs now require an approved Hyprland/Aquamarine version pair and a root BTRFS/Snapper snapshot. CI watches the CachyOS v3, v4, and znver4 repositories for unapproved package drift. After Omarchy finishes, the adapter verifies the installed package versions, checks `ldd` for unresolved libraries, and runs `Hyprland --version` before closing the Snapper pre/post pair.
- UPDATE 19-Jul-2026 (profile safety): Existing Chromium preferences are now preserved during Omarchy's recursive config copy. The adapter merges Omarchy's small theme default into the existing JSON instead of replacing the full browser profile preferences file.
- UPDATE 19-Jul-2026 (production hardening): The mkinitcpio repair now returns safely to Omarchy's sourced post-install flow and never overwrites an active hook. Hyprland/Aquamarine compatibility is checked against freshly synchronized temporary metadata and checked again against the exact system databases used for the upgrade. Existing profile overlays can be rolled back to `upstream`, and the Omarchy repository now requires trusted package signatures while allowing its unsigned database.
- UPDATE 19-Jul-2026: Re-verified all compatibility patches (mise `--shims` activation, `omarchy-update-restart` kernel detection, guard relaxations) against the current Omarchy release; no drift found. Added a CachyOS-side mitigation for upstream Omarchy issue #6188: the adapter now keeps mkinitcpio pacman hooks active during package installation and adds a post-install repair for stranded `.hook.disabled` files before reboot. Also added an opt-in `--profile th3rig` overlay for local application defaults, starting with Ghostty as the preferred terminal and the upstream terminal as the fallback.
- UPDATE 12-Jul-2026: Every compatibility patch is now verified after applying (the installer aborts if upstream Omarchy drifts), Omarchy's hibernation setup is disabled on CachyOS, non-interactive version selection via `--ref`, and CI tests every supported Omarchy release weekly. Also: dry-run, prepare-only, safer defaults, SDDM backup, optional autologin, and optional NetworkManager/iwd changes.
- UPDATE 20-May-2026: The install script now includes interactive version selection for choosing between Stable releases and Bleeding Edge.
- UPDATE 1-Oct-2025: The install script has been updated to support Omarchy 3.0+ out of the box.

## 1. Introduction

This project provides an installation script for implementing DHH's Omarchy configuration on top of CachyOS. Omarchy is an 'opinionated' desktop setup, based on Hyprland that emphasizes simplicity and productivity, while CachyOS offers a performance-optimized Arch Linux distribution.

## 2. What This Script Does and Does Not Do

This installation script does the following four things:

  1) Prompts for and fetches your preferred version of Omarchy. The latest stable tag is the default, and "Bleeding Edge" is upstream's `dev` branch.
  2) Makes adjustments to the Omarchy install scripts to support installation on CachyOS, verifying every patch after applying it (the installer aborts with the name of the failed patch if upstream Omarchy has changed underneath it)
  3) Launches the installation of Omarchy on an already setup CachyOS system
  4) Detects NVIDIA hardware, preserves existing CachyOS NVIDIA drivers, and installs drivers via `chwd` only when no NVIDIA driver is present

This script does not:

 1) Install CachyOS or any other Linux operating system
 2) Partition, format, or encrypt hard disks
 3) Install or configure a boot loader
 4) Install or configure a login display manager, beyond the optional autologin/selectable-session integration described below

All of the above need to be done when you install CachyOS. 

## 3. Important Notes

This script (and README.md) is intended primarily for the experienced Arch Linux user. The author of this README.md assumes the reader is comfortable using a shell/command line and is familiar with Arch specific terms such as AUR.

The philosophy behind this script is to produce a strong and stable blend of CachyOS and Omarchy that changes as little as possible between the two. This script does not add software or make configuration changes outside of what CachyOS or Omarchy provide as default, except when such software or configurations provided by CachyOS and Omarchy are in conflict. In these cases, the script will choose the following:

1. AUR helper: CachyOS uses Paru by default while Omarchy uses Yay. This script opts for Yay and will install it if not already installed.

2. Shell: CachyOS uses the Fish shell by default while Omarchy uses Bash. This script will keep Fish as the default interactive shell.

3. TLDR implementation: CachyOS installs Tealdeer by default, which is a TLDR implementation written in Rust. This script will preserve use of Tealdeer.

4. Mise: Omarchy activates mise with `mise activate bash --shims`, which is a shell-agnostic PATH addition that uwsm exports session-wide — fish shells inherit it without any changes. This script leaves that line alone and only upgrades the archaic non-`--shims` form if an old Omarchy release still ships it.

5. Login System: As a distribution, Omarchy skips installation of a login display manager. Instead, Hyprland autostarts and password protection is provided upon boot by the LUKS full disk encryption service. This script can either keep your existing display-manager login flow or allow Omarchy autologin. If autologin is enabled, `/etc/sddm.conf` is backed up before removal.

6. Full Disk Encryption: As a distribution, Omarchy automatically turns on full disk encryption via LUKS. This script, however, leaves this decision up to the user. CachyOS can be installed with or without full disk encryption, and this script will install Omarchy on either setup.

7. NVIDIA Drivers: The current script does not force a downgrade or pin to the 580xx proprietary series. It detects NVIDIA hardware, respects an existing CachyOS NVIDIA driver installation, and only calls CachyOS `chwd` when no NVIDIA driver is present.

8. Network: The script does not force NetworkManager to use `iwd` unless you explicitly choose that option. Without that option, it preserves the existing NetworkManager/wpa_supplicant behavior beyond Omarchy's upstream hardware script.

9. Hibernation: Omarchy's installer runs its hibernation setup non-interactively, which on CachyOS would silently create a swapfile as large as your RAM and write resume configuration only its own Limine bootloader understands — GRUB, the CachyOS default, would never see it. This script disables that step. If you want hibernation, configure it with CachyOS's own tools afterwards.

10. Chromium profile: Omarchy's upstream recursive config copy includes a minimal `Default/Preferences` file. This adapter preserves an existing Chromium preferences file and deep-merges Omarchy's theme fields into it, so browser settings, extensions, sessions, and other profile preferences are not discarded.

## 4. Pre-Requisites

IMPORTANT: This script does not install CachyOS. You must do that separately (and first.) This script is intended to be run on a fresh installation of CachyOS with the following configuration choices made: (Note, for information on installing CachyOS, please refer to https://www.cachyos.org.) 

1. File System: A full production install requires a BTRFS root with a Snapper config named `root`. The adapter creates a root pre-install snapshot before its first package/system change and a linked post-install snapshot after validation. A non-BTRFS or unconfigured system stops unless `--allow-no-snapshot` is supplied explicitly. The root snapshot protects package and system configuration changes; it does not roll back files on a separate `/home` subvolume.

2. Shell: You must choose Fish as the default shell for this installation script to work properly. (This is the default CachyOS shell choice.)

3. Desktop Environment to Install: A fresh minimal or CachyOS Hyprland install is still the safest target. The adapter can also keep an existing display-manager login flow and install Omarchy as a selectable Wayland session.

4. Graphics Drivers for NVIDIA users: This script automatically handles NVIDIA driver setup by preserving the driver CachyOS already installed. If no NVIDIA driver is detected, it uses CachyOS `chwd` to install one. It also installs `libva-nvidia-driver` (the VAAPI backend for hardware video decode) and writes the NVIDIA session environment to `~/.config/uwsm/env.d/90-nvidia.conf`, where Omarchy's own config refreshes cannot overwrite it.

   **Important:** 

   To enable hardware video decode via NVDEC in chromium, you must:
   
   1. Add the following to `~/.config/chromium-flags.conf`:

      ```
      --enable-features=VaapiOnNvidiaGPUs
      ```

   2. Install the [enhanced-h264ify extension](https://chromewebstore.google.com/detail/enhanced-h264ify/omkfmpieigblcllmkgbflkikinpkodlk) and disable **VP8** and **AV1** codecs.
   
   To fully enable hardware acceleration in Firefox, you must 
   
   1. Install the [enhanced-h264ify add-on](https://addons.mozilla.org/en-US/firefox/addon/enhanced-h264ify/) and disable **VP8** and **AV1** codecs and manually add the following overrides to your `user.js`:
   
   ```js
   // FORCE NVIDIA HARDWARE ACCELERATION
   user_pref("media.hardware-video-decoding.force-enabled", true);
   user_pref("media.hardware-video-encoding.force-enabled", true);
   user_pref("layers.acceleration.force-enabled", true);
   user_pref("webgl.force-enabled", true);
   user_pref("media.ffmpeg.vaapi.enabled", true);
   user_pref("media.rdd-ffmpeg.enabled", true);
   user_pref("media.av1.enabled", true);
   user_pref("widget.dmabuf.force-enabled", true);
   user_pref("gfx.x11-egl.force-enabled", true);
   ```

5. Package metadata check: `fakeroot` and `pacman-conf` must be available. They are normally installed with the CachyOS/Arch package toolchain and let the adapter synchronize a temporary pacman database without changing the system database during preflight.

Other configuration changes are up to you. Note, however, that this script has not been extensively tested on various CachyOS installations other than the author's own machine.

## 5. Installation Instructions

```bash
# Clone the repository
git clone https://github.com/AstroByte01/omarchy-on-cachyos.git

# Navigate to the project directory
cd omarchy-on-cachyos

# Inspect what would happen without changing the system
./bin/install-omarchy-on-cachyos.sh --dry-run

# Optional: fetch and patch Omarchy, then stop before sudo/pacman/install.sh
./bin/install-omarchy-on-cachyos.sh --prepare-only --no-auto-login --keep-network

# Optional: apply the th3rig opinionated overlay on top of Omarchy
./bin/install-omarchy-on-cachyos.sh --prepare-only --profile th3rig --no-auto-login --keep-network

# Run the full installer only after reviewing the dry-run and prepare-only output
./bin/install-omarchy-on-cachyos.sh --no-auto-login --keep-network
```

**Note:** Please review the script contents before running to understand what changes will be made to your system.

### Installer Options

- `--dry-run`: prints preflight state and planned actions without cloning, installing packages, touching `/etc`, changing services, or running Omarchy.
- `--prepare-only`: fetches Omarchy and applies compatibility patches, then stops before sudo system setup, `pacman`, copying to `~/.local/share/omarchy`, or running `install.sh`. Does not prompt for name/email (those are only used by the full install).
- `--ref <tag|branch>`: fetches that Omarchy version without showing the interactive menu (for example `--ref v3.8.2` or `--ref dev`). Also honored from the `OMARCHY_REF` environment variable.
- `--profile <upstream|th3rig>`: applies an optional local customization overlay after the CachyOS compatibility patches. The default is `upstream`, which keeps Omarchy's application defaults. `th3rig` currently installs Ghostty and makes it the preferred terminal, while keeping the selected Omarchy release's original terminal as the fallback. Also honored from the `OMARCHY_PROFILE` environment variable.
- `--staging-allow-unverified-pair`: marks the run as staging and permits a Hyprland/Aquamarine pair that is not yet listed in `config/hyprland-aquamarine-compatibility.tsv`. This exception must not be used to approve or deploy a production system.
- `--allow-no-snapshot`: allows a full install to continue only when the required root Snapper snapshot is unavailable or cannot be created. Without this explicit exception, the installer fails closed before its first system change.
- `--auto-login`: allows Omarchy to configure SDDM autologin. If `/etc/sddm.conf` exists, it is backed up before removal.
- `--no-auto-login`: keeps the existing display-manager flow, including CachyOS `plasmalogin`, and installs Omarchy as a selectable Wayland session when supported by the display manager.
- `--network-iwd`: adds a CachyOS compatibility block that disables `wpa_supplicant` and writes `/etc/NetworkManager/conf.d/omarchy-iwd.conf`.
- `--keep-network`: avoids the extra NetworkManager/iwd compatibility block.

Recommended first pass:

```bash
./bin/install-omarchy-on-cachyos.sh --dry-run
./bin/install-omarchy-on-cachyos.sh --prepare-only --no-auto-login --keep-network
```

If the prepare-only output looks correct, run the full installer with the same login/network choices.

If the fetched Omarchy tree already exists, the fetch step asks whether to keep or replace it; `bin/fetch-omarchy.sh` also accepts `--keep-existing` and `--force` (env `OMARCHY_ON_EXISTING=keep|replace`) for scripted runs.

### Profiles

Profiles are opt-in overlays for choices that are personal rather than strictly required for CachyOS compatibility. They are applied after the adapter patches upstream Omarchy, so they can be tested and re-applied without forking all of Omarchy.

- `upstream`: restores Omarchy's application defaults, including removing a previously applied `th3rig` Ghostty overlay when the fetched tree is reused.
- `th3rig`: keeps Omarchy's base, installs Ghostty, and makes Ghostty the preferred terminal through `xdg-terminal-exec`, with the selected Omarchy release's original terminal still available as a fallback.

### CachyOS Safety Patches

The adapter removes Omarchy's manual-install mkinitcpio hook disable step on CachyOS. This avoids upstream issue [#6188](https://github.com/basecamp/omarchy/issues/6188), where a manual install can leave `/boot` stale on GRUB systems if kernel packages change while mkinitcpio pacman hooks are disabled. The adapter also wires a post-install repair script that restores a stranded `60-mkinitcpio-remove.hook.disabled` or `90-mkinitcpio-install.hook.disabled` only when its active hook is missing, then regenerates initramfs before the install finishes. If both copies exist, the active hook wins and the older disabled copy is left untouched for manual inspection.

For upstream issue [#6224](https://github.com/basecamp/omarchy/issues/6224), the adapter does not pin Hyprland/Aquamarine versions. During `--dry-run` and before a full install, it synchronizes an isolated temporary pacman database and requires `hyprland` and `aquamarine` to resolve from the same CachyOS repo with matching required/provided `libaquamarine.so` sonames. The exact version pair must also appear in `config/hyprland-aquamarine-compatibility.tsv`; a new pair fails closed even when its SONAME still matches. `--staging-allow-unverified-pair` is the only bypass and labels the run as staging. During the full install the adapter synchronizes the system database once, repeats all checks against that exact database, and then upgrades with `pacman -Su` so no second refresh can change the checked package set.

Immediately before the first package change, the adapter creates a numbered Snapper pre-snapshot and prints bootloader-specific recovery instructions. On CachyOS with GRUB, the supported path is to boot the numbered snapshot from GRUB's snapshots submenu and then launch the restore UI with:

```bash
sudo -E btrfs-assistant
```

The output also includes the exact numbered `snapper rollback` command as a fallback, explicitly limited to systems configured to boot Snapper's default subvolume; CachyOS GRUB installations commonly use an explicit `subvol=@` and should use the boot-menu/Btrfs Assistant workflow instead. If a later command fails or the installation is interrupted, the instructions are printed again. After Omarchy finishes, the adapter requires the installed Hyprland/Aquamarine versions to equal the checked pair, rejects unresolved `ldd` entries, confirms that Hyprland links to Aquamarine, and runs `Hyprland --version`. Only then does it create the linked post-snapshot.

The `[omarchy]` repository is accepted only at `https://pkgs.omarchy.org/$arch` and uses `SigLevel = Required DatabaseOptional TrustedOnly`: packages must carry a signature from the trusted Omarchy key, while the currently unsigned repository database remains allowed. Existing adapter-created `Optional TrustedOnly` configuration is migrated automatically; unexpected servers or ambiguous duplicate signature directives stop the installer.

When CI reports a new Hyprland/Aquamarine pair, approve it with this sequence:

1. Run the installer in a disposable CachyOS VM with `--staging-allow-unverified-pair`.
2. Complete the post-install validation, reboot, log in to Hyprland, and exercise the session.
3. Add the exact versions, verification date, and evidence to `config/hyprland-aquamarine-compatibility.tsv`.
4. Re-run CI without the staging exception. Production remains blocked until the manifest change is merged.

### Supported Omarchy versions

The version menu offers the five newest upstream release tags plus Bleeding Edge (upstream's `dev` branch). CI runs the patching step against all of them weekly — the supported versions are exactly the ones the CI badge is green for. A separate scheduled matrix reads the live CachyOS v3, v4, and znver4 package databases and fails as soon as any repository publishes a Hyprland/Aquamarine pair absent from the compatibility manifest. Every patch is verified after it is applied, so if upstream Omarchy changes in a way this adapter doesn't expect, the installer stops with the name of the failed patch instead of continuing with a half-patched tree.

## 6. Statement of Lack of Warranty

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Use this script at your own risk. Always backup your system and important data before running installation scripts.

## 7. How to Contribute

We welcome contributions to improve this project! Here's how you can help:

1. **Fork the Repository**: Click the "Fork" button on GitHub to create your own copy
2. **Create a Feature Branch**: `git checkout -b feature/your-feature-name`
3. **Make Your Changes**: Implement your improvements or fixes
4. **Commit Your Changes**: `git commit -m "Add descriptive commit message"`
5. **Push to Your Fork**: `git push origin feature/your-feature-name`
6. **Open a Pull Request**: Submit a PR with a clear description of your changes

### Contribution Guidelines
- Test your changes thoroughly on CachyOS before submitting
- Follow existing code style and conventions
- Update documentation if adding new features
- Report bugs using GitHub Issues 
