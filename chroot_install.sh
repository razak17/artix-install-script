#!/usr/bin/env bash

# Importing Variables
formfactor="$(</tempfiles/formfactor)"
cpu="$(</tempfiles/cpu)"
threads_minus_one="$(</tempfiles/threads_minus_one)"
gpu="$(</tempfiles/gpu)"
disk="$(</tempfiles/disk)"
boot="$(</tempfiles/boot)"
username="$(</tempfiles/username)"
hostname="$(</tempfiles/hostname)"
user_password="$(</tempfiles/user_password)"
root_password="$(</tempfiles/root_password)"
timezone="$(</tempfiles/timezone)"

# Configure the system clock
ln -s /usr/share/zoneinfo/Africa/"$timezone" /etc/localtime
hwclock --systohc --utc

# Configure locale and clock Settings
echo 'en_US.UTF-8 UTF-8' >/etc/locale.gen
echo 'LANG=en_US.UTF-8' >/etc/locale.conf
locale-gen

# Network configuration
echo "$hostname" >/etc/hostname
echo "hostname='$hostname'" >/mnt/etc/conf.d/hostname

echo "127.0.0.1       localhost" >>/etc/hosts
echo "::1             localhost" >>/etc/hosts
echo "127.0.1.1       $hostname.localdomain $hostname" >>/etc/hosts

echo "nameserver 1.1.1.1" >>/etc/resolv.conf
echo "nameserver 1.0.0.1" >>/etc/resolv.conf
chattr +i /etc/resolv.conf

pacman -S networkmanager-openrc connman-openrc --noconfirm
rc-update add NetworkManager
rc-update add connmand

# Bootloader installation and configuration
pacman -S grub efibootmgr os-prober mtools dosfstools --noconfirm
if [ "$boot" == 1 ]; then
	grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB-razakmo
fi
if [ "$boot" == 2 ]; then
	grub-install --recheck "$disk"
fi
cp /usr/share/locale/en\@quot/LC_MESSAGES/grub.mo /boot/grub/locale/en.mo
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/grub -o /etc/default/grub
if [ "$gpu" != 'NVIDIA' ]; then
	echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet nowatchdog retbleed=off mem_sleep_default=deep nohz_full=1-$threads_minus_one\"" >>/etc/default/grub
else
	echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet nowatchdog retbleed=off mem_sleep_default=deep nohz_full=1-$threads_minus_one nvidia-drm.modeset=1\"" >>/etc/default/grub
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Add User
groupadd classmod
echo "$root_password
$root_password
" | passwd
useradd -m -g users -G classmod "$username"
echo "$user_password
$user_password
" | passwd "$username"

# Opendoas configuration
[ -e "/etc/doas.conf" ] && rm /etc/doas.conf
[ -e "/usr/bin/sudo" ] && rm /usr/bin/sudo
echo "permit persist keepenv $username as root
permit nopass $username as root cmd /usr/bin/poweroff
permit nopass $username as root cmd /usr/bin/reboot
" >/etc/doas.conf
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/doas-completion -o /usr/share/bash-completion/completions/doas
ln -s /usr/bin/doas /usr/bin/sudo

# Misc. configuration
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/makepkg.conf -o /etc/makepkg.conf

# Pacman configuration
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/pacman.conf -o /etc/pacman.conf
pacman -Sy artix-archlinux-support --noconfirm
[ -e "/etc/pacman.conf" ] && rm /etc/pacman.conf
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/pacman-arch.conf -o /etc/pacman.conf
pacman -Sy pacman-contrib --noconfirm
mkdir -p /etc/pacman.d/hooks
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/paccache-clean-hook -o /etc/pacman.d/hooks/paccache-clean.hook
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/modemmanager-hook -o /etc/pacman.d/hooks/modemmanager.hook
if [ "$gpu" == 'NVIDIA' ]; then
	curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/nvidia-hook -o /etc/pacman.d/hooks/nvidia.hook
fi

# Captive Portals
curl https://raw.githubusercontent.com/razak17/artix-install-script/main/config-files/captive-portal -o /etc/NetworkManager/dispatcher.d/90-open_captive_portal
echo "==> INFO: Create /etc/NetworkManager/dispatcher.d/90-open_captive_portal successfully"
# Installing hardware-specific packages
if [ "$cpu" == 'AuthenticAMD' ]; then
	pacman -S amd-ucode --noconfirm
else
	pacman -S intel-ucode --noconfirm
fi
if [ "$gpu" == 'AMD' ] || [ "$gpu" == 'Advanced' ]; then
	pacman -S mesa vulkan-icd-loader vulkan-radeon libva-mesa-driver libva-utils --needed --noconfirm
elif [ "$gpu" == 'Intel' ]; then
	pacman -S mesa vulkan-icd-loader vulkan-intel --needed --noconfirm
elif [ "$gpu" == 'NVIDIA' ]; then
	pacman -S nvidia nvidia-utils nvidia-settings vulkan-icd-loader --needed --noconfirm
	echo 'options nvidia "NVreg_DynamicPowerManagement=0x02"' >/etc/modprobe.d/nvidia.conf
	echo 'options nvidia-drm modeset=1' >/etc/modprobe.d/zz-nvidia-modeset.conf
fi

# Disable kernel watchdog
echo 'blacklist iTCO_wdt' >/etc/modprobe.d/blacklist.conf

if [ "$formfactor" == 2 ] || [ "$formfactor" == 1 ]; then
	pacman -S powertop acpid-openrc acpilight --needed --noconfirm
	rc-update add acpid
	echo 'SUBSYSTEM=="backlight", ACTION=="add", \
        RUN+="/bin/chgrp classmod /sys/class/backlight/%k/brightness", \
        RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
    ' >/etc/udev/rules.d/screenbacklight.rules
fi

# Set home directory permissions
mkdir -p /home/"$username"/{.config,.local/share}
chmod 700 /home/"$username"
chown "$username":users /home/"$username"/{.config,.local}
chown "$username":users /home/"$username"/.local/share
chmod 755 /home/"$username"/{.config,.local/share}

# ssh configuration
pacman -S openssh --needed --noconfirm
mkdir /home/"$username"/.ssh
touch /home/"$username"/.ssh/authorized_keys
chown -R "$username" /home/"$username"/.ssh
chmod 600 /home/"$username"/.ssh/authorized_keys

# misc configuration
pacman -S dhcpcd neofetch --needed --noconfirm
rc-update add local default

# Install dotfiles
curl -s https://raw.githubusercontent.com/razak17/dotfiles/main/install.sh | sh
cp "/home/$username/.cache/wal/colors-wal-dwm(main).h" "/home/$username/.cache/wal/colors-wal-dwm.h"

# Finishing up + cleaning
rm -rf /chrootInstall.sh /tempfiles
echo -e "\n---------------------------------------------------------"
echo installation completed!
echo "type 'unmount -R /mnt' then reboot"
echo Do not forget to remove the installation media
echo -e "---------------------------------------------------------\n" exit
umount -R /mnt
