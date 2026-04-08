#!/bin/bash

set -e

# --- Configuration ---
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
error_exit() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

trap 'echo -e "${RED}Script interrupted or failed unexpectedly.${NC}"' ERR

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log "Step 1: Cloning Base Image"
if [ ! -f "$BASE_IMG" ]; then
    error_exit "Base image $BASE_IMG not found!"
fi

cp "$BASE_IMG" "$RPI5_IMG"

log "Step 2: Launching Docker for Injection"
docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd xz-utils fdisk dosfstools e2fsprogs curl > /dev/null

    cd /work
    
    # Create loop nodes
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod /dev/loop\$i b 7 \$i || true; done

    echo 'Fetching mirror indexes...'
    CORE_LIST=\$(curl -sL $MIRROR_CORE/)
    ALARM_LIST=\$(curl -sL $MIRROR_ALARM/)
    
    # SWITCHED: Using linux-rpi (4k) instead of 16k for maximum driver compatibility
    KERNEL_PKG=\$(echo \"\$CORE_LIST\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    BOOT_PKG=\$(echo \"\$ALARM_LIST\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    FIRM_PKG=\$(echo \"\$ALARM_LIST\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    echo \"Found Kernel (4k): \$KERNEL_PKG\"
    echo \"Found Bootloader: \$BOOT_PKG\"
    echo \"Found Firmware: \$FIRM_PKG\"

    [ ! -f \"\$KERNEL_PKG\" ] && wget -q --show-progress \"$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$BOOT_PKG\"
    [ ! -f \"\$FIRM_PKG\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$FIRM_PKG\"

    kpartx -d $RPI5_IMG || true
    KOUT=\$(kpartx -asv $RPI5_IMG)
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/root
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    echo 'CLEANUP: Purging old modules/boot files...'
    rm -rf /mnt/root/usr/lib/modules/*
    rm -rf /mnt/root/boot/*

    echo 'Injecting Files...'
    PKGS=(\"\$KERNEL_PKG\" \"\$BOOT_PKG\" \"\$FIRM_PKG\")
    for pkg in \"\${PKGS[@]}\"; do
        tar -xpf \"\$pkg\" -C /mnt/root --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.INSTALL'
    done

    if [ -d /mnt/root/boot/boot ]; then
        mv /mnt/root/boot/boot/* /mnt/root/boot/
        rmdir /mnt/root/boot/boot
    fi

    echo 'Configuring config.txt with RP1 USB Fixes...'
    cat <<EOF > /mnt/root/boot/config.txt
# RPi 5 Arch Linux Config (4k Kernel)
arm_64bit=1
enable_uart=1

# Use the standard kernel
kernel=Image

# RPi 5 Hardware Identity
device_tree=bcm2712-rpi-5-b.dtb
overlay_prefix=overlays/

# USB/RP1 Fixes
# Force high current mode for USB
usb_max_current_enable=1
# Ensure the RP1 chip initializes correctly
dtparam=pcie_aspm=off

# General features
dtparam=audio=on
dtoverlay=vc4-kms-v3d-pi5
max_framebuffers=2
EOF

    echo 'root=/dev/mmcblk0p2 rw rootwait console=serial0,115200 console=tty1 selinux=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0' > /mnt/root/boot/cmdline.txt

    # Headless Access
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /mnt/root/etc/ssh/sshd_config
    mkdir -p /mnt/root/root/.ssh && chmod 700 /mnt/root/root/.ssh
    if [ -f /work/id_rsa.pub ]; then cp /work/id_rsa.pub /mnt/root/root/.ssh/authorized_keys; fi
    [ -f /mnt/root/root/.ssh/authorized_keys ] && chmod 600 /mnt/root/root/.ssh/authorized_keys

    echo '/dev/mmcblk0p1  /boot   vfat    defaults        0       0' > /mnt/root/etc/fstab
    echo '/dev/mmcblk0p2  /       ext4    defaults,noatime  0       1' >> /mnt/root/etc/fstab

    sync
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
    echo 'Done.'
"

log "${GREEN}--- SUCCESS: Compatibility RPi 5 Image Ready ---${NC}"
