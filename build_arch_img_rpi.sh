#!/bin/bash

# Exit on error
set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"
MIRROR="http://mirror.archlinuxarm.org/aarch64/alarm"

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
log "Cloned $BASE_IMG to $RPI5_IMG."

log "Step 2: Launching Docker for Offline Injection"
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    echo 'Installing system dependencies...'
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd fdisk dosfstools e2fsprogs curl > /dev/null

    cd /work
    
    echo 'Checking mirror connectivity...'
    if ! curl -s --head $MIRROR/ | grep '200 OK' > /dev/null; then
        echo 'ERROR: Cannot reach Arch Linux ARM mirror.'
        exit 1
    fi

    echo 'Discovering latest RPi 5 packages...'
    HTML_LIST=\$(curl -sL $MIRROR/)
    
    # Robust filename extraction:
    # 1. Finds the prefix (e.g. linux-rpi-)
    # 2. Captures everything until .pkg.tar.zst
    # 3. Sorts version-wise and takes the latest
    GET_LATEST() {
        echo \"\$HTML_LIST\" | grep -oE \"\$1-[0-9][a-zA-Z0-9._-]+-aarch64\.pkg\.tar\.zst|\$1-[0-9][a-zA-Z0-9._-]+-any\.pkg\.tar\.zst\" | sort -V | tail -n 1
    }

    KERNEL_PKG=\$(GET_LATEST \"linux-rpi\")
    BOOT_PKG=\$(GET_LATEST \"raspberrypi-bootloader\")
    FIRM_PKG=\$(GET_LATEST \"raspberrypi-firmware\")

    echo \"Found:\"
    echo \"  - Kernel: \$KERNEL_PKG\"
    echo \"  - Bootloader: \$BOOT_PKG\"
    echo \"  - Firmware: \$FIRM_PKG\"

    if [ -z \"\$KERNEL_PKG\" ] || [ -z \"\$BOOT_PKG\" ] || [ -z \"\$FIRM_PKG\" ]; then
        echo 'ERROR: One or more packages could not be identified on the mirror.'
        exit 1
    fi

    PKGS=(\"\$KERNEL_PKG\" \"\$BOOT_PKG\" \"\$FIRM_PKG\")

    for pkg in \"\${PKGS[@]}\"; do
        if [ ! -f \"\$pkg\" ]; then
            echo \"Downloading \$pkg...\"
            wget --show-progress -q \"$MIRROR/\$pkg\"
        else
            echo \"\$pkg is already present.\"
        fi
    done

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
    for pkg in \"\${PKGS[@]}\"; do
        echo \"Extracting \$pkg...\"
        tar --zstd -xpf \"\$pkg\" -C /mnt/root --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.INSTALL'
    done

    echo 'Configuring boot parameters...'
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
