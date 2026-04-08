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
    error_exit "Base image $BASE_IMG not found!"
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
    
    echo 'Installing system dependencies (Added xz-utils)...'
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd xz-utils fdisk dosfstools e2fsprogs curl > /dev/null

    cd /work
    
    echo 'Fetching mirror indexes...'
    CORE_LIST=\$(curl -sL $MIRROR_CORE/)
    ALARM_LIST=\$(curl -sL $MIRROR_ALARM/)
    
    # Discovery logic: Added 'grep -v headers' to ensure we get the KERNEL, not the HEADERS
    KERNEL_PKG=\$(echo \"\$CORE_LIST\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | sort -V | tail -n 1)
    BOOT_PKG=\$(echo \"\$ALARM_LIST\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    FIRM_PKG=\$(echo \"\$ALARM_LIST\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    echo \"Found Kernel: \$KERNEL_PKG\"
    echo \"Found Bootloader: \$BOOT_PKG\"
    echo \"Found Firmware: \$FIRM_PKG\"

    if [ -z \"\$KERNEL_PKG\" ] || [ -z \"\$BOOT_PKG\" ] || [ -z \"\$FIRM_PKG\" ]; then
        echo 'ERROR: Discovery failed. One of the packages was not found.'
        exit 1
    fi

    # Download from appropriate source
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

    echo 'Injecting Kernel and Firmware...'
    PKGS=(\"\$KERNEL_PKG\" \"\$BOOT_PKG\" \"\$FIRM_PKG\")
    for pkg in \"\${PKGS[@]}\"; do
        echo \"Extracting \$pkg...\"
        tar -xpf \"\$pkg\" -C /mnt/root --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.INSTALL'
    done

    echo 'Enabling Headless Access (SSH/Root)...'
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /mnt/root/etc/ssh/sshd_config
    
    mkdir -p /mnt/root/root/.ssh && chmod 700 /mnt/root/root/.ssh
    if [ -f /work/id_rsa.pub ]; then cp /work/id_rsa.pub /mnt/root/root/.ssh/authorized_keys
    elif [ -f /work/id_ed25519.pub ]; then cp /work/id_ed25519.pub /mnt/root/root/.ssh/authorized_keys
    fi
    [ -f /mnt/root/root/.ssh/authorized_keys ] && chmod 600 /mnt/root/root/.ssh/authorized_keys

    echo 'Finalizing boot files...'
    cat <<EOF > /mnt/root/etc/fstab
/dev/mmcblk0p1  /boot   vfat    defaults        0       0
/dev/mmcblk0p2  /       ext4    defaults,noatime  0       1
EOF

    echo 'root=/dev/mmcblk0p2 rw rootwait console=serial0,115200 console=tty1 selinux=0 smsc95xx.turbo_mode=N' > /mnt/root/boot/cmdline.txt

    sync
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
    echo 'Done.'
"

echo -e "${GREEN}------------------------------------------------${NC}"
echo -e "${GREEN}--- SUCCESS: RPi 5 Master Image is Ready ---${NC}"
echo -e "${GREEN}------------------------------------------------${NC}"
