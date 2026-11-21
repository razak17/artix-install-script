#!/usr/bin/env bash

readonly BIOS_BOOT_GUID="21686148-6449-6e6f-744e-656564454649"
readonly EFI_SYSTEM_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
readonly MICROSOFT_BASIC_GUID="ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
readonly MICROSOFT_RESERVED_GUID="e3c9e316-0b5c-4db8-817d-f92df00215ae"
readonly WINDOWS_RECOVERY_GUID="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
readonly LINUX_FILESYSTEM_GUID="0fc63daf-8483-4772-8e79-3d69d8477de4"

print_block_devices() {
    lsblk -e 7 -o NAME,PATH,TYPE,SIZE,FSTYPE,FSVER,PARTTYPENAME,PARTUUID,MOUNTPOINTS,MODEL
}

canonical_device() {
    readlink -f -- "$1"
}

device_type() {
    lsblk -dnro TYPE -- "$1"
}

partition_table_type() {
    lsblk -dnro PTTYPE -- "$1" | tr '[:upper:]' '[:lower:]'
}

parent_disk() {
    local parent
    parent="$(lsblk -dnro PKNAME -- "$1")"
    [[ -n "$parent" ]] || return 1
    printf '/dev/%s\n' "$parent"
}

filesystem_type() {
    lsblk -dnro FSTYPE -- "$1"
}

partition_type() {
    lsblk -dnro PARTTYPE -- "$1" | tr '[:upper:]' '[:lower:]'
}

device_size_bytes() {
    blockdev --getsize64 "$1"
}

is_mounted() {
    findmnt -rn -S "$1" >/dev/null 2>&1
}

canonicalize_install_devices() {
    DISK="$(canonical_device "$DISK")"
    if [[ -n "$ESP_PARTITION" ]]; then ESP_PARTITION="$(canonical_device "$ESP_PARTITION")"; fi
    if [[ -n "${BIOS_BOOT_PARTITION:-}" ]]; then BIOS_BOOT_PARTITION="$(canonical_device "$BIOS_BOOT_PARTITION")"; fi
    BOOT_PARTITION="$(canonical_device "$BOOT_PARTITION")"
    ROOT_PARTITION="$(canonical_device "$ROOT_PARTITION")"
}

require_disk() {
    [[ -b "$1" ]] || die "Not a block device: $1"
    [[ "$(device_type "$1")" == disk ]] || die "Expected a whole disk: $1"
    [[ "$(partition_table_type "$1")" == gpt ]] || die "Expected a GPT disk: $1"
}

require_partition() {
    [[ -b "$1" ]] || die "Not a block device: $1"
    [[ "$(device_type "$1")" == part ]] || die "Expected a partition: $1"
}

require_same_parent_disk() {
    local expected_disk=$1 partition=$2 actual_disk
    actual_disk="$(parent_disk "$partition")" || die "Cannot determine parent disk for $partition"
    [[ "$actual_disk" == "$expected_disk" ]] ||
        die "$partition belongs to $actual_disk, not $expected_disk"
}

require_unmounted() {
    is_mounted "$1" && die "Partition is mounted: $1"
    return 0
}

require_esp() {
    local device=$1 fs_type part_type
    fs_type="$(filesystem_type "$device")"
    part_type="$(partition_type "$device")"
    [[ "$fs_type" =~ ^(vfat|fat|fat32)$ ]] || die "ESP is not FAT32/vfat: $device ($fs_type)"
    [[ "$part_type" == "$EFI_SYSTEM_GUID" ]] || die "Partition is not an EFI System Partition: $device"
}

require_safe_linux_target() {
    local device=$1 fs_type part_type size minimum_size=$2
    fs_type="$(filesystem_type "$device")"
    part_type="$(partition_type "$device")"
    size="$(device_size_bytes "$device")"

    case "${fs_type,,}" in
        ntfs|bitlocker|vfat|fat|fat32|exfat)
            die "Refusing Windows-compatible filesystem on destructive target $device ($fs_type)" ;;
    esac

    [[ "$part_type" == "$LINUX_FILESYSTEM_GUID" ]] ||
        die "Destructive target is not a Linux filesystem GPT partition: $device"

    ((size >= minimum_size)) || die "$device is smaller than the required $(human_size "$minimum_size")"
}

verify_esp_contents_readonly() {
    local device=$1 temporary_mount problem="" available_bytes
    temporary_mount="$(mktemp -d /tmp/artix-esp-check.XXXXXX)"

    if ! mount -o ro "$device" "$temporary_mount"; then
        rmdir "$temporary_mount"
        die "Could not mount the ESP read-only for verification"
    fi

    if [[ "${INSTALL_MODE:-dual-boot}" == dual-boot && ! -f "$temporary_mount/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        problem="Windows Boot Manager is missing from the selected ESP"
    fi
    available_bytes="$(df --output=avail -B1 "$temporary_mount" | tail -n 1 | tr -d ' ')"
    if [[ "$available_bytes" =~ ^[0-9]+$ ]] && ((available_bytes < 16777216)); then
        problem="The selected ESP has less than 16 MiB free"
    fi

    umount "$temporary_mount"
    rmdir "$temporary_mount"
    [[ -z "$problem" ]] || die "$problem"
}

require_no_bitlocker() {
    if lsblk -nrpo FSTYPE "$1" | grep -Eiq 'bitlocker'; then
        die "BitLocker filesystem detected. Decrypt Windows before running this installer"
    fi
}

require_windows_prepared() {
    local answer expected="WINDOWS IS BACKED UP AND FULLY SHUT DOWN"
    printf '\nConfirm that Windows Fast Startup/hibernation is disabled and your recovery key is backed up.\n'
    printf 'Type exactly: %s\n> ' "$expected"
    read -r answer
    [[ "$answer" == "$expected" ]] || die "Windows preparation was not confirmed"
}

require_bios_boot() {
    local device=$1
    [[ "$(partition_type "$device")" == "$BIOS_BOOT_GUID" ]] || die "Not a GPT BIOS boot partition: $device"
    [[ -z "$(filesystem_type "$device")" ]] || die "BIOS boot partition must be unformatted: $device"
    (( $(device_size_bytes "$device") >= 1048576 )) || die "BIOS boot partition must be at least 1 MiB"
}

validate_install_devices() {
    local disk=$1 esp=$2 boot=$3 root=$4 bios=${5:-} boot_size root_size partition firmware_partition
    require_disk "$disk"
    if [[ "${BOOT_MODE:-uefi}" == uefi ]]; then
        [[ -z "$bios" ]] || die "--bios-boot is only valid in BIOS mode"
        [[ -n "$esp" ]] || die "UEFI requires --esp"
        firmware_partition=$esp
    else
        [[ -z "$esp" ]] || die "--esp is only valid in UEFI mode"
        [[ -n "$bios" ]] || die "BIOS requires --bios-boot"
        firmware_partition=$bios
    fi
    [[ "$firmware_partition" != "$boot" && "$firmware_partition" != "$root" && "$boot" != "$root" ]] ||
        die "Firmware, /boot and encrypted-root targets must be distinct"
    for partition in "$firmware_partition" "$boot" "$root"; do
        require_partition "$partition"
        require_same_parent_disk "$disk" "$partition"
        require_unmounted "$partition"
    done
    if [[ "${BOOT_MODE:-uefi}" == uefi ]]; then require_esp "$esp"; else require_bios_boot "$bios"; fi
    require_safe_linux_target "$boot" 805306368
    require_safe_linux_target "$root" 42949672960
    boot_size="$(device_size_bytes "$boot")"
    root_size="$(device_size_bytes "$root")"
    ((boot_size <= 4294967296)) || die "/boot target is unexpectedly larger than 4 GiB: $boot"
    ((root_size > boot_size)) || die "Encrypted-root target must be larger than /boot"
    require_no_bitlocker "$disk"
}

detect_gpu_vendors() {
    local pci_data=${1:-}
    [[ -n "$pci_data" ]] || pci_data="$(lspci -Dn)"
    grep -qE '030[02]:.*1002:' <<<"$pci_data" && printf '%s\n' AMD
    grep -qE '030[02]:.*10de:' <<<"$pci_data" && printf '%s\n' NVIDIA
}
