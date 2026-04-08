#!/bin/bash

set -e

# --- CONFIGURATION (FILL YOUR WIFI) ---
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
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log "Step 1: Preparing Clean Image"
cp "$BASE_IMG" "$RPI5_IMG"

log "Step 2: Launching Docker for Direct Loop Injection"
docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -qq && apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod > /dev/null

    cd /work
    
    echo 'Provisioning loop devices manually...'
    # Force creation of device nodes 0 through 15
    for i in {0..15}; do
        if [ ! -b /dev/loop\$i ]; then
            mknod -m 0660 /dev/loop\$i b 7 \$i || true
        fi
    done

    echo 'Finding matching Kernel/Module package...'
    KERNEL_PKG=\$(curl -sL $MIRROR_CORE/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    FIRM_RPI=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    BOOT_PKG=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    [ ! -f \"\$KERNEL_PKG\" ] && wget -q \"$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$FIRM_RPI\" ] && wget -q \"$MIRROR_ALARM/\$FIRM_RPI\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q \"$MIRROR_ALARM/\$BOOT_PKG\"

    echo 'Mapping image partitions (using explicit loop binding)...'
    # Detach everything first to be safe
    losetup -D
    
    # Manually find and bind the first free loop device
    LOOP_DEV=\$(losetup -f)
    losetup \"\$LOOP_DEV\" $RPI5_IMG
    
    # Use kpartx on the specific device we just bound
    KOUT=\$(kpartx -asv \"\$LOOP_DEV\")
    echo \"\$KOUT\"
    
    # Extract partition mapper names
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/root
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    echo 'Syncing Kernel and Modules...'
    rm -rf /mnt/root/usr/lib/modules/* /mnt/root/boot/*
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/root
    tar -xpf \"\$FIRM_RPI\" -C /mnt/root
    tar -xpf \"\$BOOT_PKG\" -C /mnt/root

    [ -d /mnt/root/boot/boot ] && mv /mnt/root/boot/boot/* /mnt/root/boot/ && rmdir /mnt/root/boot/boot

    # Generate module map
    KVER=\$(ls /mnt/root/usr/lib/modules | head -n 1)
    depmod -b /mnt/root \$KVER

    echo 'Injecting WiFi and enabling SSH...'
    mkdir -p /mnt/root/etc/wpa_supplicant
    cat <<EOF > /mnt/root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASS\"
}
EOF
    cat <<EOF > /mnt/root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
DHCP=yes
EOF
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service

    echo 'Finalizing config.txt...'
    cat <<EOF > /mnt/root/boot/config.txt
arm_64bit=1
kernel=Image
device_tree=bcm2712-rpi-5-b.dtb
overlay_prefix=overlays/
usb_max_current_enable=1
dtparam=pcie_aspm=off
EOF

    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0\" > /mnt/root/boot/cmdline.txt
    sed -i 's/root:\*:/root::/' /mnt/root/etc/shadow

    sync
    umount -R /mnt/root
    kpartx -d \"\$LOOP_DEV\"
    losetup -d \"\$LOOP_DEV\"
    echo 'Done.'
"

log "${GREEN}--- SUCCESS: Fully Synced Image Ready ---${NC}"
