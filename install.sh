#!/usr/bin/env bash

loadkeys us

echo -e '\nspecial devices:\n1. asus zephyrus g14 (2020)\ngeneric:\n2. laptop\n3. desktop\n4. server\n'
read -n 1 -r -p "formfactor: " formfactor

fdisk -l
read -rp "disk: (eg: /dev/sda) " disk

# Partition disk
# boot
read -rp "Enter boot partiton (eg. /dev/sda2): " boot_partition
if [ -n "$boot_partition" ]; then
	mkfs.fat -F 32 "$boot_partition"
	fatlabel "$boot_partition" BOOT
else
	echo "No boot partition entered" && exit 1
fi

# root
read -rp "Enter root partiton: " root_partition
if [ -n "$root_partition" ]; then
	mkfs.ext4 -L ROOT "$root_partition"
else
	echo "No root partition entered" && exit 1
fi

# home
read -rp "Enter home partiton: " home_partition
if [ -n "$home_partition" ]; then
	mkfs.ext4 -L HOME "$home_partition"
else
	echo "No home partition entered" && exit 1
fi

# Mount partitions
mount /dev/disk/by-label/ROOT /mnt
mkdir /mnt/boot
mkdir /mnt/home
mount /dev/disk/by-label/HOME /mnt/home
mount /dev/disk/by-label/BOOT /mnt/boot

# update system clock
rc-service ntpd start

# Install base system
base_devel='db diffutils gc guile libisl libmpc perl autoconf automake bash zsh binutils bison esysusers etmpfiles fakeroot file findutils flex gawk gcc gettext grep groff gzip libtool m4 cmake pacman pacman-contrib patch pkgconf python sed opendoas texinfo which bc udev'
basestrap /mnt base $base_devel openrc elogind-openrc linux linux-firmware git micro man-db curl

# Generate fstab
fstabgen -U /mnt >>/mnt/etc/fstab

# User Info
read -rp "username: " username
read -rp "$username password: " user_password
read -rp "root password: " root_password
read -rp "hostname (eg: Artix): " hostname
read -rp "timezone (eg. Accra): " timezone

# Start hardware detection
cpu=$(lscpu | grep 'Vendor ID:' | awk 'FNR == 1 {print $3;}')
threads_minus_one=$(echo "$(lscpu | grep 'CPU(s):' | awk 'FNR == 1 {print $2;}') - 1" | bc)
gpu=$(lspci | grep 'VGA compatible controller:' | awk 'FNR == 1 {print $5;}')
ram=$(echo "$(</proc/meminfo)" | grep 'MemTotal:' | awk '{print $2;}')
ram=$(echo "$ram / 1000000" | bc)

# start variable manipulation
username=$(echo "$username" | tr '[:upper:]' '[:lower:]')
hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')

# determine if running as UEFI or BIOS
if [ -d "/sys/firmware/efi" ]; then
	boot=1
else
	boot=2
fi

# exporting variables
mkdir /mnt/tempfiles
echo "$formfactor" >/mnt/tempfiles/formfactor
echo "$cpu" >/mnt/tempfiles/cpu
echo "$threads_minus_one" >/mnt/tempfiles/threads_minus_one
echo "$gpu" >/mnt/tempfiles/gpu
echo "$boot" >/mnt/tempfiles/boot
echo "$disk" >/mnt/tempfiles/disk
echo "$username" >/mnt/tempfiles/username
echo "$user_password" >/mnt/tempfiles/user_password
echo "$root_password" >/mnt/tempfiles/root_password
echo "$timezone" >/mnt/tempfiles/timezone

# Download and initiate part 2
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/chroot_install.sh -o /mnt/chroot_install.sh
chmod +x /mnt/chroot_install.sh
artix-chroot /mnt /chroot_install.sh
