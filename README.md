# Safe Artix OpenRC dual-boot installer

This installer installs an encrypted Artix OpenRC system beside Windows 11 on the same GPT/UEFI SSD. It is intentionally specific: it does not resize Windows, create partitions or support legacy BIOS installation.

## Resulting layout

```text
Existing Windows partitions — preserved
Existing Windows EFI System Partition — mounted at /boot/efi, never formatted
New 1 GiB Linux partition — unencrypted ext4 /boot
New Linux partition — LUKS2 container
└── ext4 /, including /home and an encrypted 8 GiB swap file
```

The installer places GRUB under `EFI/Artix` and preserves `EFI/Microsoft`.

## Important limitations

- This script erases the two Linux target partitions after an exact confirmation.
- It must be run from an Artix OpenRC live ISO booted in UEFI mode.
- It refuses disks containing a filesystem reported as BitLocker. Decrypt Windows first if Device Encryption is enabled.
- Secure Boot must remain disabled for this installation.
- Linux hibernation, automatic partition creation, desktop installation and dotfiles are out of scope.

## Prepare Windows

1. Back up important files and the BitLocker/device-encryption recovery key.
2. If Device Encryption or BitLocker is enabled, turn it off and allow decryption to finish.
3. Disable hibernation and Fast Startup in an Administrator terminal:

   ```bat
   powercfg /h off
   ```

4. Run a filesystem check:

   ```bat
   chkdsk C: /scan
   ```

5. Use Windows Disk Management to shrink C:. Leave the released space unallocated.
6. Perform a full shutdown:

   ```bat
   shutdown /s /t 0
   ```

## Create the Linux partitions

Boot the Artix USB through the ThinkPad `F12` menu. Confirm UEFI mode:

```bash
test -d /sys/firmware/efi && echo 'UEFI confirmed'
```

Inspect the disk carefully:

```bash
lsblk -e 7 -o NAME,PATH,TYPE,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINTS,MODEL
```

Use `cfdisk` on the correct parent disk to create exactly two partitions in the unallocated space:

- A 1 GiB Linux filesystem partition for `/boot`.
- A Linux filesystem partition using the remaining intended Artix space.

Do not change the existing EFI, Microsoft Reserved, NTFS or Recovery partitions.

## Run a non-destructive preflight

Clone or copy this complete repository onto the live environment. Do not use `curl | sh`.

Substitute the device paths shown by `lsblk`:

```bash
sudo ./install.sh \
  --disk /dev/nvme0n1 \
  --esp /dev/nvme0n1p1 \
  --boot /dev/nvme0n1p5 \
  --root /dev/nvme0n1p6 \
  --user razak \
  --hostname p15v \
  --preflight-only
```

The preflight validates the disk relationship, ESP type, target filesystem and GPT types, minimum sizes, mount state, UEFI environment and network. It does not format anything.

## Install

Rerun the same command without `--preflight-only`:

```bash
sudo ./install.sh \
  --disk /dev/nvme0n1 \
  --esp /dev/nvme0n1p1 \
  --boot /dev/nvme0n1p5 \
  --root /dev/nvme0n1p6 \
  --user razak \
  --hostname p15v
```

The script asks for two exact confirmations. The second confirmation names both partitions that will be erased. It then prompts interactively for:

- The LUKS passphrase
- The root password
- The initial user's password

Passwords are not stored in installer files.

The script never reboots automatically. When it reports success, remove the installer USB and reboot. GRUB should show Artix and Windows Boot Manager for five seconds.

## First boot

Confirm networking, audio, suspend and the AMD graphics driver before installing Nvidia support:

```bash
lspci -k | grep -A3 -E 'VGA|3D|Network'
rc-service NetworkManager status
```

The optional Nvidia installer is retained under root's installer directory:

```bash
doas /root/artix-installer/post-install/nvidia.sh
```

It installs the matching kernel headers, `nvidia-dkms`, utilities and conservative dynamic-power-management settings. Reboot and verify:

```bash
nvidia-smi
```

## Recovery

Use `F12` to select Windows Boot Manager directly if GRUB does not start. The installer does not remove that firmware entry or the Microsoft EFI files.

From an Artix live ISO, unlock and mount the installation with:

```bash
sudo cryptsetup open /dev/nvme0n1p6 cryptroot
sudo mount /dev/mapper/cryptroot /mnt
sudo mount /dev/nvme0n1p5 /mnt/boot
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
sudo artix-chroot /mnt
```

Replace the example partition numbers with the actual values from `lsblk`.

## Development checks

The tests use mocked device metadata and never operate on physical disks:

```bash
./tests/run.sh
```

Static syntax validation is included. If ShellCheck is installed, run:

```bash
shellcheck install.sh chroot_install.sh lib/*.sh post-install/*.sh tests/*.sh
```
