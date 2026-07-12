#!/bin/bash
set -euo pipefail

# NVIDIA configuration for Omarchy on CachyOS.
# Detect and preserve the NVIDIA driver CachyOS already installed.

if ! command -v lspci >/dev/null 2>&1 || ! lspci -nn -d 10de: | grep -qE "VGA|3D"; then
    echo "[*] No NVIDIA GPU found. Skipping."
    exit 0
fi

GPU_NAME=$(lspci -d 10de: | grep -E "VGA|3D" | head -n1 | sed 's/.*: //')
echo "[*] NVIDIA GPU detected: $GPU_NAME"

DRIVER_PACKAGES=$(
    pacman -Qq 2>/dev/null |
        grep -E '^(nvidia|nvidia-open|nvidia-dkms|nvidia-open-dkms|nvidia-580xx-dkms|nvidia-lts|nvidia-utils|nvidia-580xx-utils|lib32-nvidia-utils|lib32-nvidia-580xx-utils)$' || true
)

KERNEL_DRIVER_PACKAGES=$(
    printf '%s\n' "$DRIVER_PACKAGES" |
        grep -E '^(nvidia|nvidia-open|nvidia-dkms|nvidia-open-dkms|nvidia-580xx-dkms|nvidia-lts)$' || true
)

if [[ -n "$KERNEL_DRIVER_PACKAGES" ]] || lsmod | grep -q '^nvidia'; then
    echo "[*] Existing NVIDIA driver packages found:"
    if [[ -n "$DRIVER_PACKAGES" ]]; then
        printf '    - %s\n' $DRIVER_PACKAGES
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | sed 's/^/    - active driver: /' || true
    fi
    echo "[*] Respecting existing CachyOS driver installation."
else
    if ! command -v chwd >/dev/null 2>&1; then
        echo "[!] No NVIDIA kernel driver package detected and chwd is unavailable."
        echo "[!] Install the appropriate CachyOS NVIDIA driver manually, then rerun Omarchy."
        exit 1
    fi

    echo "[!] No NVIDIA kernel driver package detected."
    echo "[!] Installing through CachyOS hardware detection (chwd)."
    sudo chwd -a
fi

sudo pacman -S --needed --noconfirm libva-nvidia-driver libva-utils

# uwsm sources ~/.config/uwsm/env.d/* with /bin/sh and exports the result
# session-wide. env.d is used instead of the env file because Omarchy manages
# ~/.config/uwsm/env and omarchy-refresh-config would overwrite additions.
NVIDIA_ENV_FILE="$HOME/.config/uwsm/env.d/90-nvidia.conf"

mkdir -p "$HOME/.config/uwsm/env.d"
if grep -qs "GBM_BACKEND=nvidia-drm" "$HOME/.config/uwsm/env" "$NVIDIA_ENV_FILE"; then
    echo "[*] NVIDIA environment variables already present."
else
    cat >"$NVIDIA_ENV_FILE" <<'EOF'
# NVIDIA environment for Omarchy on CachyOS
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
    echo "[*] NVIDIA environment variables written to $NVIDIA_ENV_FILE"
fi

echo "[*] NVIDIA configuration complete."
