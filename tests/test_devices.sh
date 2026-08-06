#!/usr/bin/env bash
set -Eeuo pipefail

readonly TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$TEST_ROOT/lib/common.sh"
# shellcheck source=../lib/devices.sh
source "$TEST_ROOT/lib/devices.sh"

declare -A MOCK_PARENT=(
    [/dev/mockp1]=/dev/mockdisk
    [/dev/mockp2]=/dev/mockdisk
    [/dev/mockp3]=/dev/mockdisk
    [/dev/otherp1]=/dev/otherdisk
)
declare -A MOCK_FS=(
    [/dev/mockp1]=vfat
    [/dev/mockp2]=""
    [/dev/mockp3]=""
    [/dev/otherp1]=""
)
declare -A MOCK_PARTTYPE=(
    [/dev/mockp1]="$EFI_SYSTEM_GUID"
    [/dev/mockp2]="$LINUX_FILESYSTEM_GUID"
    [/dev/mockp3]="$LINUX_FILESYSTEM_GUID"
    [/dev/otherp1]="$LINUX_FILESYSTEM_GUID"
)
declare -A MOCK_SIZE=(
    [/dev/mockp1]=268435456
    [/dev/mockp2]=1073741824
    [/dev/mockp3]=107374182400
    [/dev/otherp1]=107374182400
)

require_disk() { [[ "$1" == /dev/mockdisk ]] || die "unexpected disk"; }
require_partition() { [[ -v "MOCK_PARENT[$1]" ]] || die "unexpected partition"; }
parent_disk() { printf '%s\n' "${MOCK_PARENT[$1]}"; }
filesystem_type() { printf '%s\n' "${MOCK_FS[$1]}"; }
partition_type() { printf '%s\n' "${MOCK_PARTTYPE[$1]}"; }
device_size_bytes() { printf '%s\n' "${MOCK_SIZE[$1]}"; }
is_mounted() { return 1; }
require_no_bitlocker() { return 0; }

expect_failure() {
    local description=$1
    shift
    if ("$@" >/dev/null 2>&1); then
        printf 'FAIL: expected failure: %s\n' "$description" >&2
        exit 1
    fi
}

validate_install_devices /dev/mockdisk /dev/mockp1 /dev/mockp2 /dev/mockp3

expect_failure "duplicate targets" \
    validate_install_devices /dev/mockdisk /dev/mockp1 /dev/mockp2 /dev/mockp2

expect_failure "partition from another disk" \
    validate_install_devices /dev/mockdisk /dev/mockp1 /dev/mockp2 /dev/otherp1

MOCK_FS[/dev/mockp2]=ntfs
expect_failure "NTFS destructive target" \
    validate_install_devices /dev/mockdisk /dev/mockp1 /dev/mockp2 /dev/mockp3
MOCK_FS[/dev/mockp2]=""

MOCK_PARTTYPE[/dev/mockp3]="$WINDOWS_RECOVERY_GUID"
expect_failure "Windows recovery destructive target" \
    validate_install_devices /dev/mockdisk /dev/mockp1 /dev/mockp2 /dev/mockp3
MOCK_PARTTYPE[/dev/mockp3]="$LINUX_FILESYSTEM_GUID"

gpu_output="$(detect_gpu_vendors $'0000:05:00.0 0300: 1002:1681\n0000:01:00.0 0302: 10de:1fb6')"
grep -qx AMD <<<"$gpu_output"
grep -qx NVIDIA <<<"$gpu_output"

printf 'Device validation tests passed\n'
