#!/usr/bin/env bash
set -Eeuo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

((EUID == 0)) || die "Run this script as root"
lspci -Dn | grep -qE '030[02]:.*10de:' || die "No Nvidia GPU was detected"

headers=()
pacman -Q linux >/dev/null 2>&1 && headers+=(linux-headers)
pacman -Q linux-lts >/dev/null 2>&1 && headers+=(linux-lts-headers)
pacman -Q linux-zen >/dev/null 2>&1 && headers+=(linux-zen-headers)
((${#headers[@]})) || die "No supported Artix kernel package was detected"

pacman -Syu --needed "${headers[@]}" nvidia-dkms nvidia-utils nvidia-settings

install -d /etc/modprobe.d
cat > /etc/modprobe.d/nvidia-power-management.conf <<'EOF'
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia-drm modeset=1
EOF

mkinitcpio -P
printf '%s\n' \
    'Nvidia packages installed. Reboot, then verify with:' \
    '  lspci -k | grep -A3 -E "VGA|3D"' \
    '  nvidia-smi'
