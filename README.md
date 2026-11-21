# Artix OpenRC installer

This installer installs encrypted Artix OpenRC either as a standalone system (UEFI or legacy BIOS) or beside Windows 11 (UEFI only). All modes require a GPT disk and manually prepared partitions. It does not resize existing systems or create partitions.

The default remains Windows dual boot. Select `--mode standalone` for a Linux-only installation. `--boot-mode auto` detects how the live ISO was booted; use `--boot-mode uefi` or `--boot-mode bios` to require a specific mode. An explicit mode must match the live environment. Legacy MBR partition tables and BIOS Windows dual boot are not supported.

## Dual-boot layout

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
- Run from an Artix OpenRC live ISO booted in the intended firmware mode. Windows dual boot requires UEFI.
- It refuses disks containing a filesystem reported as BitLocker. Decrypt Windows first if Device Encryption is enabled.
- Secure Boot must remain disabled for this installation.
- Linux hibernation, automatic partition creation, desktop installation and dotfiles are out of scope.

## Standalone installation

Back up any data before preparing partitions. Standalone mode does not automatically wipe the disk or remove an existing OS. It still refuses NTFS, FAT, exFAT and BitLocker filesystems as `/boot` or root erase targets. Repartitioning an existing Windows installation must be done manually after backup.

Inspect the disk with:

```bash
lsblk -e 7 -o NAME,PATH,TYPE,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINTS,MODEL
```

Use `cfdisk` on the intended disk to prepare one of the GPT layouts below. These are examples for `/dev/sda`; substitute your actual disk and partition paths. The root partition needs at least 40 GiB. The installer accepts `/boot` sizes from 768 MiB to 4 GiB; 1 GiB is recommended.

### Standalone UEFI

Boot the live ISO in UEFI mode with Secure Boot disabled. Prepare:

| Example | Size | GPT partition type | Use |
| --- | --- | --- | --- |
| `/dev/sda1` | 512 MiB | EFI System | FAT32 ESP |
| `/dev/sda2` | 1 GiB | Linux filesystem | ext4 `/boot`, erased by installer |
| `/dev/sda3` | Remaining space, at least 40 GiB | Linux filesystem | LUKS2 root, erased by installer |

For a **new, empty ESP only**, format it before running the installer (this command erases that partition):

```bash
sudo mkfs.fat -F 32 /dev/sda1
```

An existing FAT32 ESP can be reused without formatting. The installer preserves its filesystem and files, requires at least 16 MiB free and writes GRUB under `EFI/Artix`. It does not require Windows files.

Run a preflight from the complete repository:

```bash
sudo ./install.sh --mode standalone --boot-mode uefi \
  --disk /dev/sda --esp /dev/sda1 \
  --boot /dev/sda2 --root /dev/sda3 \
  --user razak --hostname artix --preflight-only
```

After reviewing the plan, rerun without `--preflight-only` to install.

### Standalone BIOS

Boot the live ISO in legacy BIOS/CSM mode. GPT is still required. Prepare:

| Example | Size | GPT partition type | Use |
| --- | --- | --- | --- |
| `/dev/sda1` | 1 MiB | BIOS boot (`EF02` in gdisk) | Unformatted GRUB embedding area |
| `/dev/sda2` | 1 GiB | Linux filesystem | ext4 `/boot`, erased by installer |
| `/dev/sda3` | Remaining space, at least 40 GiB | Linux filesystem | LUKS2 root, erased by installer |

Do not format or mount the BIOS boot partition. No ESP is needed. GRUB writes boot code to the selected parent disk and embeds data in the BIOS boot partition; the confirmation explicitly names both. This follows [GRUB's BIOS/GPT installation requirements](https://www.gnu.org/software/grub/manual/grub/html_node/BIOS-installation.html).

```bash
sudo ./install.sh --mode standalone --boot-mode bios \
  --disk /dev/sda --bios-boot /dev/sda1 \
  --boot /dev/sda2 --root /dev/sda3 \
  --user razak --hostname artix --preflight-only
```

After reviewing the plan, rerun without `--preflight-only`. Do not pass `--esp` in BIOS mode or `--bios-boot` in UEFI mode.

Both standalone modes ask for one exact destructive confirmation, then the LUKS passphrase, root password and user password. They install an 8 GiB encrypted swap file and never reboot automatically. GRUB contains Artix entries without probing for other operating systems.

## Prepare Windows (dual boot only)

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

## Create the Linux partitions (dual boot)

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

## Run a non-destructive preflight (dual boot)

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

## Install (dual boot)

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

For standalone installations, boot an Artix live ISO in the installed firmware mode and substitute your actual partitions:

```bash
sudo cryptsetup open /dev/sda3 cryptroot
sudo mount /dev/mapper/cryptroot /mnt
sudo mount /dev/sda2 /mnt/boot
# UEFI only:
sudo mount /dev/sda1 /mnt/boot/efi
sudo artix-chroot /mnt
```

For BIOS, skip the ESP mount and reinstall GRUB to the **parent disk** with `grub-install --target=i386-pc --recheck /dev/sda`. For UEFI, use `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Artix --recheck`. Then run `grub-mkconfig -o /boot/grub/grub.cfg`.

### Dual-boot recovery

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
