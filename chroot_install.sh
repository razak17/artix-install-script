#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALLER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE=/root/artix-installer.env

# shellcheck source=lib/common.sh
source "$INSTALLER_ROOT/lib/common.sh"

load_install_environment() {
    [[ -r "$ENV_FILE" ]] || die "Missing chroot environment: $ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    : "${INSTALL_USER:?}" "${INSTALL_HOSTNAME:?}" "${LUKS_UUID:?}" "${TIMEZONE:?}"
    : "${INSTALL_MODE:?}" "${BOOT_MODE:?}" "${INSTALL_DISK:?}"
    case "$INSTALL_MODE/$BOOT_MODE" in
        dual-boot/uefi|standalone/uefi) : "${ESP_UUID:?}" ;;
        standalone/bios) ;;
        *) die "Invalid installation/boot mode in chroot environment" ;;
    esac
}

configure_base_system() {
    log "Configuring timezone, locale and hostname"
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc --utc
    printf 'en_US.UTF-8 UTF-8\n' > /etc/locale.gen
    locale-gen
    printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
    printf 'KEYMAP=us\n' > /etc/vconsole.conf
    printf '%s\n' "$INSTALL_HOSTNAME" > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $INSTALL_HOSTNAME.localdomain $INSTALL_HOSTNAME
EOF
}

configure_user() {
    log "Creating user $INSTALL_USER"
    getent group wheel >/dev/null || groupadd wheel
    useradd --create-home --groups wheel --shell /bin/bash "$INSTALL_USER"

    printf '\nSet the root password.\n'
    passwd root
    printf '\nSet the password for %s.\n' "$INSTALL_USER"
    passwd "$INSTALL_USER"

    cat > /etc/doas.conf <<EOF
permit keepenv :wheel
permit nopass $INSTALL_USER as root cmd /usr/bin/poweroff
permit nopass $INSTALL_USER as root cmd /usr/bin/reboot
EOF
    chmod 0400 /etc/doas.conf
    doas -C /etc/doas.conf >/dev/null
}

configure_services() {
    log "Enabling NetworkManager"
    rc-update add NetworkManager default
}

configure_encrypted_boot() {
    local hooks
    hooks="$(grep -E '^HOOKS=' /etc/mkinitcpio.conf)"
    [[ -n "$hooks" ]] || die "Could not find HOOKS in /etc/mkinitcpio.conf"

    if ! grep -qw encrypt <<<"$hooks"; then
        sed -Ei '/^HOOKS=/ s/(block)([[:space:]])/\1 encrypt\2/' /etc/mkinitcpio.conf
    fi

    hooks="$(grep -E '^HOOKS=' /etc/mkinitcpio.conf)"
    grep -qw encrypt <<<"$hooks" || die "Failed to add the encrypt initramfs hook"
    mkinitcpio -P
}

configure_swap_file() {
    log "Creating an 8 GiB encrypted swap file"
    if [[ ! -e /swapfile ]]; then
        fallocate -l 8G /swapfile
        chmod 0600 /swapfile
        mkswap /swapfile
    fi
    grep -qE '^/swapfile[[:space:]]' /etc/fstab ||
        printf '/swapfile none swap defaults 0 0\n' >> /etc/fstab
}

configure_grub() {
    local custom_windows_entry="" efi_entries disable_os_prober=true
    [[ "$INSTALL_MODE" != dual-boot ]] || disable_os_prober=false
    log "Installing GRUB for $INSTALL_MODE / $BOOT_MODE"
    cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Artix"
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_TERMINAL_INPUT=console
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=$disable_os_prober
GRUB_CMDLINE_LINUX="cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"
EOF

    if [[ "$INSTALL_MODE" == dual-boot ]] && ! os-prober | grep -qi windows; then
        custom_windows_entry="menuentry 'Windows Boot Manager' --class windows --class os {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=esp $ESP_UUID
    chainloader (\$esp)/EFI/Microsoft/Boot/bootmgfw.efi
}"
        warn "os-prober did not detect Windows; installing a verified EFI fallback entry"
    fi

    cat > /etc/grub.d/40_custom <<EOF
#!/bin/sh
exec tail -n +3 \$0
$custom_windows_entry
EOF
    chmod 0755 /etc/grub.d/40_custom

    if [[ "$BOOT_MODE" == uefi ]]; then
        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=Artix \
            --recheck
    else
        grub-install --target=i386-pc --recheck "$INSTALL_DISK"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg

    if [[ "$INSTALL_MODE" == dual-boot ]]; then
        grep -q 'Windows Boot Manager' /boot/grub/grub.cfg ||
            die "GRUB configuration does not contain Windows Boot Manager"
    fi
    if [[ "$BOOT_MODE" == uefi ]]; then
        efi_entries="$(efibootmgr)"
        grep -qi 'Artix' <<<"$efi_entries" || die "Artix UEFI boot entry was not created"
        if [[ "$INSTALL_MODE" == dual-boot ]]; then
            grep -qi 'Windows Boot Manager' <<<"$efi_entries" ||
                die "Existing Windows UEFI boot entry was not found"
        fi
    fi
}

verify_graphics() {
    local pci_data
    pci_data="$(lspci -Dn)"
    if grep -qE '030[02]:.*1002:' <<<"$pci_data"; then
        log "AMD integrated graphics detected and configured"
    else
        warn "AMD graphics was not detected"
    fi
    if grep -qE '030[02]:.*10de:' <<<"$pci_data"; then
        log "Nvidia GPU detected; its optional driver is deferred until first boot"
    fi
}

main() {
    load_install_environment
    configure_base_system
    configure_user
    configure_services
    configure_encrypted_boot
    configure_swap_file
    configure_grub
    verify_graphics
    rm -f "$ENV_FILE"
    log "Chroot configuration completed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
