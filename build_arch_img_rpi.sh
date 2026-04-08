#!/bin/bash

set -e

# --- CONFIGURATION ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="US"  # <--- CHANGE THIS to your country code (US, GB, ES, DE, etc.)

WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

MIRROR_CORE="http://fl.us.mirror.archlinuxarm.org/aarch64/core"
MIRROR_ALARM="http://fl.us.mirror.archlinuxarm.org/aarch64/alarm"

# Colors
B_MAGENTA='\033[1;35m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
NC='\033[0m'

echo -e "${B_MAGENTA}====================================================${NC}"
echo -e "${B_MAGENTA}      FINAL HARDWARE & NETWORK POLISH (RPi 5)       ${NC}"
echo -e "${B_MAGENTA}====================================================${NC}"

cd "$WORKSPACE"
cp "$BASE_IMG" "$RPI5_IMG"

docker run --rm --privileged -v "$WORKSPACE":/work ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod > /dev/null

    cd /work
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done

    # 1. Discovery
    KERNEL_PKG=\$(curl -sL $MIRROR_CORE/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    FIRM_RPI=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    BOOT_PKG=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    echo -e \"\033[1;32m✔️ USING KERNEL:\033[0m \$KERNEL_PKG\"

    # 2. Mount
    losetup -D
    LOOP_DEV=\$(losetup -f)
    losetup \"\$LOOP_DEV\" $RPI5_IMG
    KOUT=\$(kpartx -asv \"\$LOOP_DEV\")
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    mkdir -p /mnt/root && mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot && mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    # 3. Clean and Extract
    rm -rf /mnt/root/usr/lib/modules/* /mnt/root/boot/*
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$FIRM_RPI\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$BOOT_PKG\" -C /mnt/root --exclude='.PKGINFO'
    [ -d /mnt/root/boot/boot ] && mv /mnt/root/boot/boot/* /mnt/root/boot/ && rmdir /mnt/root/boot/boot
    KVER=\$(ls /mnt/root/usr/lib/modules | head -n 1)
    depmod -b /mnt/root \$KVER

    # 4. WIFI FIX: The Regulatory Domain
    echo 'Setting WiFi Regulatory Domain to $REG_DOMAIN...'
    mkdir -p /mnt/root/etc/conf.d
    echo \"WIRELESS_REGDOM='\$REG_DOMAIN'\" > /mnt/root/etc/conf.d/wireless-regdom
    
    # WiFi Credentials (applying to all wl* interfaces)
    mkdir -p /mnt/root/etc/wpa_supplicant
    cat <<EOF > /mnt/root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
country=$REG_DOMAIN
network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASS\"
}
EOF

    # 5. Networkd Config
    cat <<EOF > /mnt/root/etc/systemd/network/25-wireless.network
[Match]
Name=wl*
[Network]
DHCP=yes
EOF

    # 6. Enable Services
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service

    # 7. PASSWORD FIX: The Official Way
    echo 'Removing root password...'
    # Use 'sed' to change ANY character between the first and second colon to nothing
    sed -i 's/^root:[^:]*:/root::/' /mnt/root/etc/shadow

    # 8. Boot Config
    echo 'arm_64bit=1' > /mnt/root/boot/config.txt
    echo 'kernel=Image' >> /mnt/root/boot/config.txt
    echo 'device_tree=bcm2712-rpi-5-b.dtb' >> /mnt/root/boot/config.txt
    echo 'usb_max_current_enable=1' >> /mnt/root/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0\" > /mnt/root/boot/cmdline.txt

    sync
    umount -R /mnt/root
    kpartx -d \"\$LOOP_DEV\"
    losetup -d \"\$LOOP_DEV\"
"

echo -e "${B_GREEN}--- SUCCESS: Password and WiFi Regulatory Fixes Applied ---${NC}"
