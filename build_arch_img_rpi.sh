#!/bin/bash

# Exit on error
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

log "Step 1: Cloning Base Image for RPi 5"
if [ ! -f "$BASE_IMG" ]; then
    error_exit "Base image $BASE_IMG not found! Ensure build_arch_img.sh (10GB version) ran first."
fi

cp "$BASE_IMG" "$RPI5_IMG"
log "Cloned base image."

log "Step 2: Launching Docker for Injection"
docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    echo 'Installing system dependencies...'
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd xz-utils fdisk dosfstools e2fsprogs curl > /dev/null

    cd /work
    
    echo 'Fixing loop nodes...'
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod /dev/loop\$i b 7 \$i || true; done

    echo 'Fetching mirror indexes...'
    CORE_LIST=\$(curl -sL $MIRROR_CORE/)
    ALARM_LIST=\$(curl -sL $MIRROR_ALARM/)
    
    KERNEL_PKG=\$(echo \"\$CORE_LIST\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | sort -V | tail -n 1)
    BOOT_PKG=\$(echo \"\$ALARM_LIST\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    FIRM_PKG=\$(echo \"\$ALARM_LIST\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    echo \"Found Kernel: \$KERNEL_PKG\"
    echo \"Found Bootloader: \$BOOT_PKG\"
    echo \"Found Firmware: \$FIRM_PKG\"

    [ ! -f \"\$KERNEL_PKG\" ] && wget -q --show-progress \"$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$BOOT_PKG\"
    [ ! -f \"\$FIRM_PKG\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$FIRM_PKG\"

    echo 'Mapping image partitions...'
    kpartx -d $RPI5_IMG || true
    KOUT=\$(kpartx -asv $RPI5_IMG)
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/root
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    echo 'CLEANUP: Removing generic modules...'
    rm -rf /mnt/root/usr/lib/modules/*
    rm -rf /mnt/root/boot/*

    echo 'Injecting RPi 5 Kernel and Firmware...'
    PKGS=(\"\$KERNEL_PKG\" \"\$BOOT_PKG\" \"\$FIRM_PKG\")
    for pkg in \"\${PKGS[@]}\"; do
        echo \"Extracting \$pkg...\"
        tar -xpf \"\$pkg\" -C /mnt/root --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.INSTALL'
    done

    echo 'SURGERY: Fixing Boot partition directory structure...'
    # Arch packages put files in /boot/. Since we mounted P1 to /boot, 
    # the files end up in /boot/boot/. We must move them to the top level.
    if [ -d /mnt/root/boot/boot ]; then
        mv /mnt/root/boot/boot/* /mnt/root/boot/
        rmdir /mnt/root/boot/boot
    fi

    echo 'Configuring config.txt for RPi 5 USB support...'
    # Basic Pi 5 configuration
    cat <<EOF > /mnt/root/boot/config.txt
# Raspberry Pi 5 Arch Linux ARM Config
arm_64bit=1
enable_uart=1
uart_2ndstage=1

# Use the RPi kernel we injected
kernel=Image

# Required for RPi 5 USB (RP1 chip)
device_tree=bcm2712-rpi-5-b.dtb
overlay_prefix=overlays/

# Enable common features
dtparam=audio=on
dtoverlay=vc4-kms-v3d
max_framebuffers=2
EOF

    echo 'Configuring cmdline.txt...'
    # rootwait is vital for SD cards
    echo 'root=/dev/mmcblk0p2 rw rootwait console=serial0,115200 console=tty1 selinux=0 smsc95xx.turbo_mode=N' > /mnt/root/boot/cmdline.txt

    echo 'Setting up Headless Access...'
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /mnt/root/etc/ssh/sshd_config
    mkdir -p /mnt/root/root/.ssh && chmod 700 /mnt/root/root/.ssh
    if [ -f /work/id_rsa.pub ]; then cp /work/id_rsa.pub /mnt/root/root/.ssh/authorized_keys
    elif [ -f /work/id_ed25519.pub ]; then cp /work/id_ed25519.pub /mnt/root/root/.ssh/authorized_keys
    fi
    [ -f /mnt/root/root/.ssh/authorized_keys ] && chmod 600 /mnt/root/root/.ssh/authorized_keys

    echo 'Finalizing fstab...'
    cat <<EOF > /mnt/root/etc/fstab
/dev/mmcblk0p1  /boot   vfat    defaults        0       0
/dev/mmcblk0p2  /       ext4    defaults,noatime  0       1
EOF

    sync
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
    echo 'Done.'
"

log "${GREEN}--- SUCCESS: RPi 5 Master Image is Ready ---${NC}"
