#!/bin/bash

set -e

# --- Configuration (RE-FILL YOUR WIFI) ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

MIRROR_CORE="http://fl.us.mirror.archlinuxarm.org/aarch64/core"
MIRROR_ALARM="http://fl.us.mirror.archlinuxarm.org/aarch64/alarm"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo "--- Step 1: Preparing Clean Image ---"
cp "$BASE_IMG" "$RPI5_IMG"

echo "--- Step 2: Injecting Drivers and Debug Shell ---"
docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd xz-utils fdisk curl kmod > /dev/null

    cd /work
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod /dev/loop\$i b 7 \$i || true; done

    echo 'Finding packages...'
    # 4k Kernel and Firmwares
    KERNEL_PKG=\$(curl -sL $MIRROR_CORE/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    BOOT_PKG=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    FIRM_RPI=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    # ADDED: Standard Linux firmware for WiFi chips
    FIRM_GENERIC=\$(curl -sL $MIRROR_CORE/ | grep -oE 'linux-firmware-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    PKGS=(\"\$KERNEL_PKG\" \"\$BOOT_PKG\" \"\$FIRM_RPI\" \"\$FIRM_GENERIC\")
    for pkg in \"\${PKGS[@]}\"; do
        if [ ! -f \"\$pkg\" ]; then
            echo \"Downloading \$pkg...\"
            # Try core first, then alarm
            wget -q \"$MIRROR_CORE/\$pkg\" || wget -q \"$MIRROR_ALARM/\$pkg\"
        fi
    done

    kpartx -d $RPI5_IMG || true
    KOUT=\$(kpartx -asv $RPI5_IMG)
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/root
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    echo 'Wiping old kernel/modules to prevent mismatches...'
    rm -rf /mnt/root/usr/lib/modules/*
    rm -rf /mnt/root/boot/*

    echo 'Extracting new packages...'
    for pkg in \"\${PKGS[@]}\"; do
        tar -xpf \"\$pkg\" -C /mnt/root --exclude='.PKGINFO'
    done

    # Fix nested boot
    [ -d /mnt/root/boot/boot ] && mv /mnt/root/boot/boot/* /mnt/root/boot/ && rmdir /mnt/root/boot/boot

    echo 'Building module dependencies (CRITICAL)...'
    # Find the version string from the folder name we just extracted
    KVER=\$(ls /mnt/root/usr/lib/modules | head -n 1)
    # Run depmod using the host kmod tool to ensure modules are searchable
    depmod -b /mnt/root \$KVER

    echo 'Injecting WiFi...'
    mkdir -p /mnt/root/etc/wpa_supplicant
    cat <<EOF > /mnt/root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASS\"
}
EOF
    mkdir -p /mnt/root/etc/systemd/network
    cat <<EOF > /mnt/root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
DHCP=yes
EOF
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service

    echo 'Configuring Boot with Debug Shell...'
    cat <<EOF > /mnt/root/boot/config.txt
arm_64bit=1
kernel=Image
device_tree=bcm2712-rpi-5-b.dtb
overlay_prefix=overlays/
usb_max_current_enable=1
EOF

    # ADDED: init=/usr/bin/bash drops you straight to a prompt to bypass login issues
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 init=/usr/bin/bash\" > /mnt/root/boot/cmdline.txt

    sync
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
"

echo -e "${GREEN}--- SUCCESS: Image Ready with Debug Shell ---${NC}"
