#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/devices.sh
source "$SCRIPT_DIR/lib/devices.sh"
# shellcheck source=lib/storage.sh
source "$SCRIPT_DIR/lib/storage.sh"

DISK=""
ESP_PARTITION=""
BOOT_PARTITION=""
ROOT_PARTITION=""
USERNAME=""
HOSTNAME=""
PREFLIGHT_ONLY=false
INSTALL_MODE=dual-boot
BOOT_MODE=auto
BIOS_BOOT_PARTITION=""

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Required options may also be entered interactively:
  --disk DEVICE       Parent GPT disk, for example /dev/nvme0n1
  --esp DEVICE        Prepared FAT EFI System Partition (UEFI); never formatted
  --bios-boot DEVICE  Unformatted GPT BIOS boot partition (BIOS only)
  --mode MODE         dual-boot (default) or standalone
  --boot-mode MODE    auto (default), uefi or bios
  --boot DEVICE       New Artix /boot partition; WILL BE ERASED
  --root DEVICE       New Artix encrypted-root partition; WILL BE ERASED
  --user NAME         Initial user name
  --hostname NAME     Host name

Other options:
  --preflight-only    Validate and print the plan without formatting anything
  -h, --help          Show this help
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --mode) INSTALL_MODE="${2:?missing value for --mode}"; shift 2 ;;
            --boot-mode) BOOT_MODE="${2:?missing value for --boot-mode}"; shift 2 ;;
            --bios-boot) BIOS_BOOT_PARTITION="${2:?missing value for --bios-boot}"; shift 2 ;;
            --disk) DISK="${2:?missing value for --disk}"; shift 2 ;;
            --esp) ESP_PARTITION="${2:?missing value for --esp}"; shift 2 ;;
            --boot) BOOT_PARTITION="${2:?missing value for --boot}"; shift 2 ;;
            --root) ROOT_PARTITION="${2:?missing value for --root}"; shift 2 ;;
            --user) USERNAME="${2:?missing value for --user}"; shift 2 ;;
            --hostname) HOSTNAME="${2:?missing value for --hostname}"; shift 2 ;;
            --preflight-only) PREFLIGHT_ONLY=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

prompt_missing_values() {
    print_block_devices
    [[ -n "$DISK" ]] || read -r -p "Parent disk: " DISK
    if [[ "$BOOT_MODE" == uefi ]]; then
        [[ -n "$ESP_PARTITION" ]] || read -r -p "Prepared EFI partition (preserved): " ESP_PARTITION
    else
        [[ -n "$BIOS_BOOT_PARTITION" ]] || read -r -p "Unformatted BIOS boot partition (GRUB writes here): " BIOS_BOOT_PARTITION
    fi
    [[ -n "$BOOT_PARTITION" ]] || read -r -p "New Artix /boot partition (erased): " BOOT_PARTITION
    [[ -n "$ROOT_PARTITION" ]] || read -r -p "New Artix encrypted-root partition (erased): " ROOT_PARTITION
    [[ -n "$USERNAME" ]] || read -r -p "User name: " USERNAME
    [[ -n "$HOSTNAME" ]] || read -r -p "Host name: " HOSTNAME
}

validate_identity() {
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
        die "Invalid user name: $USERNAME"
    [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] ||
        die "Invalid host name: $HOSTNAME"
}

preflight() {
    require_root
    resolve_install_modes
    require_artix_openrc_live
    require_commands \
        artix-chroot basestrap blkid blockdev cryptsetup curl df findmnt \
        fstabgen lsblk mkfs.ext4 mktemp mount mountpoint numfmt readlink umount
    require_network
    validate_identity
    validate_install_devices "$DISK" "$ESP_PARTITION" "$BOOT_PARTITION" "$ROOT_PARTITION" "$BIOS_BOOT_PARTITION"
    require_install_mounts_available
    if [[ "$BOOT_MODE" == uefi ]]; then verify_esp_contents_readonly "$ESP_PARTITION"; fi
    if [[ "$INSTALL_MODE" == dual-boot ]]; then require_windows_prepared; fi
}

show_plan() {
    local boot_size root_size
    boot_size="$(human_size "$(device_size_bytes "$BOOT_PARTITION")")"
    root_size="$(human_size "$(device_size_bytes "$ROOT_PARTITION")")"

    cat <<EOF

Installation plan
=================
Installation mode: $INSTALL_MODE / $BOOT_MODE
Parent disk:       $DISK
Preserve ESP:      ${ESP_PARTITION:-none}
BIOS boot target:  ${BIOS_BOOT_PARTITION:-none}
ERASE for /boot:   $BOOT_PARTITION ($boot_size)
ERASE for LUKS:    $ROOT_PARTITION ($root_size)
Encrypted mapping: /dev/mapper/cryptroot
User / hostname:   $USERNAME / $HOSTNAME

The installer will not repartition, format the ESP, or reboot automatically.
EOF
    if [[ "$BOOT_MODE" == bios ]]; then
        printf "GRUB will write boot code to %s and BIOS boot partition %s.\n" "$DISK" "$BIOS_BOOT_PARTITION"
    fi
}

confirm_destructive_actions() {
    local expected answer
    expected="ERASE $BOOT_PARTITION AND $ROOT_PARTITION"
    if [[ "$BOOT_MODE" == bios ]]; then expected+=" AND INSTALL BIOS GRUB ON $DISK USING $BIOS_BOOT_PARTITION"; fi
    printf '\nType exactly: %s\n> ' "$expected"
    read -r answer
    [[ "$answer" == "$expected" ]] || die "Confirmation did not match; nothing was changed"
}

bootstrap_system() {
    local -a packages=(
        base base-devel openrc openrc-system elogind-openrc linux linux-firmware amd-ucode
        cryptsetup grub efibootmgr os-prober mtools dosfstools ntfs-3g
        networkmanager-openrc mesa vulkan-icd-loader vulkan-radeon
        libva-mesa-driver libva-utils opendoas
        git curl micro man-db openssh pciutils
    )

    log "Bootstrapping Artix OpenRC"
    basestrap /mnt "${packages[@]}"
    fstabgen -U /mnt > /mnt/etc/fstab
}

copy_installer_resources() {
    local target=/mnt/root/artix-installer
    install -d -m 700 "$target" "$target/lib" "$target/post-install"
    install -m 700 "$SCRIPT_DIR/chroot_install.sh" "$target/chroot_install.sh"
    install -m 600 "$SCRIPT_DIR/lib/common.sh" "$target/lib/common.sh"
    install -m 700 "$SCRIPT_DIR/post-install/nvidia.sh" "$target/post-install/nvidia.sh"
}

write_chroot_environment() {
    local luks_uuid esp_uuid env_file=/mnt/root/artix-installer.env
    luks_uuid="$(blkid -s UUID -o value "$ROOT_PARTITION")"
    esp_uuid=""
    [[ -n "$luks_uuid" ]] || die "Could not determine LUKS UUID"
    if [[ "$BOOT_MODE" == uefi ]]; then
        esp_uuid="$(blkid -s UUID -o value "$ESP_PARTITION")"
        [[ -n "$esp_uuid" ]] || die "Could not determine ESP UUID"
    fi

    umask 077
    {
        printf 'INSTALL_MODE=%q\n' "$INSTALL_MODE"
        printf 'BOOT_MODE=%q\n' "$BOOT_MODE"
        printf 'INSTALL_DISK=%q\n' "$DISK"
        printf 'INSTALL_USER=%q\n' "$USERNAME"
        printf 'INSTALL_HOSTNAME=%q\n' "$HOSTNAME"
        printf 'LUKS_UUID=%q\n' "$luks_uuid"
        printf 'ESP_UUID=%q\n' "$esp_uuid"
        printf 'TIMEZONE=%q\n' "Africa/Accra"
    } > "$env_file"
}

main() {
    parse_args "$@"
    resolve_install_modes
    prompt_missing_values
    canonicalize_install_devices
    preflight
    show_plan

    if [[ "$PREFLIGHT_ONLY" == true ]]; then
        log "Preflight passed; no changes were made"
        return 0
    fi

    confirm_destructive_actions
    install_cleanup_trap
    prepare_storage "$ESP_PARTITION" "$BOOT_PARTITION" "$ROOT_PARTITION"
    if [[ "$INSTALL_MODE" == dual-boot ]]; then verify_windows_boot_files; fi
    bootstrap_system
    copy_installer_resources
    write_chroot_environment

    log "Entering chroot; you will be prompted for passwords"
    artix-chroot /mnt /root/artix-installer/chroot_install.sh

    sync
    cleanup_install_resources
    trap - EXIT ERR INT TERM
    log "Installation completed. Remove the installer USB and reboot when ready."
    log "After the first Artix boot, Nvidia setup is available at /root/artix-installer/post-install/nvidia.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
