#!/usr/bin/env bash

log() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    ((EUID == 0)) || die "Run this installer as root"
}

require_uefi() {
    [[ -d /sys/firmware/efi ]] || die "The live ISO was not booted in UEFI mode"
}

require_artix_openrc_live() {
    command -v openrc >/dev/null 2>&1 || die "Use an Artix OpenRC live ISO"
    command -v basestrap >/dev/null 2>&1 || die "basestrap is unavailable"
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
    done
}

require_network() {
    curl --fail --silent --show-error --head --max-time 10 https://artixlinux.org/ >/dev/null ||
        die "Could not reach artixlinux.org"
}

human_size() {
    numfmt --to=iec-i --suffix=B "$1"
}
