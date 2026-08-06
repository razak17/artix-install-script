#!/usr/bin/env bash
set -Eeuo pipefail

readonly TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for script in \
    "$TEST_ROOT/install.sh" \
    "$TEST_ROOT/chroot_install.sh" \
    "$TEST_ROOT"/lib/*.sh \
    "$TEST_ROOT"/post-install/*.sh \
    "$TEST_ROOT"/tests/*.sh; do
    bash -n "$script"
done

"$TEST_ROOT/tests/test_devices.sh"

if grep -R -E 'mkfs\.[[:alnum:]]+.*ESP_PARTITION|mkfs\.[[:alnum:]]+.*\$esp' \
    "$TEST_ROOT/install.sh" "$TEST_ROOT/lib"; then
    printf 'FAIL: found a command that may format the ESP\n' >&2
    exit 1
fi

printf 'All tests passed\n'
