#!/usr/bin/env bash

declare -ag INSTALL_MOUNTS=()
LUKS_OPENED=false

cleanup_install_resources() {
    local index mount_point
    set +e
    for ((index=${#INSTALL_MOUNTS[@]}-1; index>=0; index--)); do
        mount_point=${INSTALL_MOUNTS[index]}
        mountpoint -q "$mount_point" && umount "$mount_point"
    done
    if [[ "$LUKS_OPENED" == true && -e /dev/mapper/cryptroot ]]; then
        cryptsetup close cryptroot
    fi
    set -e
}

installation_failed() {
    local status=$?
    warn "Installation stopped at line ${BASH_LINENO[0]} (status $status)"
    cleanup_install_resources
    exit "$status"
}

install_cleanup_trap() {
    trap installation_failed ERR INT TERM
    trap cleanup_install_resources EXIT
}

prepare_storage() {
    local esp=$1 boot=$2 root=$3

    log "Formatting new Artix /boot partition: $boot"
    mkfs.ext4 -F -L ARTIX_BOOT "$boot"

    log "Creating LUKS2 container: $root"
    cryptsetup luksFormat --type luks2 "$root"
    cryptsetup open "$root" cryptroot
    LUKS_OPENED=true
    mkfs.ext4 -F -L ARTIX_ROOT /dev/mapper/cryptroot

    install -d /mnt
    mount /dev/mapper/cryptroot /mnt
    INSTALL_MOUNTS+=(/mnt)
    install -d /mnt/boot
    mount "$boot" /mnt/boot
    INSTALL_MOUNTS+=(/mnt/boot)
    install -d /mnt/boot/efi
    mount "$esp" /mnt/boot/efi
    INSTALL_MOUNTS+=(/mnt/boot/efi)
}

verify_windows_boot_files() {
    [[ -f /mnt/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi ]] ||
        die "Windows Boot Manager was not found on the selected ESP"
}
