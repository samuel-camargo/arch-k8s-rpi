#!/bin/bash

# Exit on error
set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error_exit() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Trap unexpected exits
trap 'echo -e "${RED}Script interrupted or failed unexpectedly.${NC}"' ERR

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log "Step 1: Cloning Base Image for RPi 5"
if [ ! -f "$BASE_IMG" ]; then
    error_exit "Base image $BASE_IMG not found! Run the base build script first."
fi

cp "$BASE_IMG" "$RPI5_IMG"
log "Cloned $BASE_IMG to $RPI5_IMG."

log "Step 2: Launching Docker for Offline Injection"
# We'll download packages INSIDE the container to handle mirror variations
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    # Colors inside container
    BLUE='\033[0;34m'
    NC='\033[0m'

    echo -e \"\${BLUE}[Container]${NC} Installing system dependencies (kpartx, wget, zstd, tar)...\"
    apt-get update -qq
    apt-get install -y -qq kpartx wget zstd fdisk dosfstools e2fsprogs > /dev/null

    cd /work
    
    # Mirror and Package definitions
    MIRROR=\"http://mirror.archlinuxarm.org/aarch64/alarm\"
    # We use more generic names or fetch 'latest' if possible. 
    # Note: If these exact versions fail, the mirror likely updated.
    PKGS=(
        \"linux-rpi-6.6.22-1-aarch64.pkg.tar.zst\"
        \"raspberrypi-bootloader-20240314-1-any.pkg.tar.zst\"
        \"raspberrypi-firmware-20240314-1-aarch64.pkg.tar.zst\"
    )

    echo -e \"\${BLUE}[Container]${NC} Downloading RPi 5 packages...\"
    for pkg in \${PKGS[@]}; do
        if [ ! -f \"\$pkg\" ]; then
            echo \"Downloading \$pkg...\"
            wget --show-progress -q \"\$MIRROR/\$pkg\" || exit 1
        else
            echo \"\$pkg already present.\"
        fi
    done

    echo -e \"\${BLUE}[Container]${NC} Mapping image partitions...\"
    kpartx -d $RPI5_IMG || true
    KOUT=\$(kpartx -asv $RPI5_IMG)
    echo \"\$KOUT\"
    
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    [ -z \"\$BOOT_MAPPER\" ] && echo 'Failed to map BOOT partition' && exit 1
    [ -z \"\$ROOT_MAPPER\" ] && echo 'Failed to map ROOT partition' && exit 1

    mkdir -p /mnt/root
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    echo -e \"\${BLUE}[Container]${NC} Injecting RPi 5 Kernel and Firmware...\"
    for pkg in \${PKGS[@]}; do
        echo \"Extracting \$pkg...\"
        tar --zstd -xpf \"\$pkg\" -C /mnt/root --exclude='.PKGINFO' --exclude='.MTREE'
    done

    echo -e \"\${BLUE}[Container]${NC} Configuring fstab and cmdline.txt...\"
    # Idempotent fstab
    cat <<EOF > /mnt/root/etc/fstab
/dev/mmcblk0p1  /boot   vfat    defaults        0       0
/dev/mmcblk0p2  /       ext4    defaults,noatime  0       1
EOF

    # RPi 5 cmdline setup
    echo 'root=/dev/mmcblk0p2 rw rootwait console=serial0,115200 console=tty1 selinux=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0' > /mnt/root/boot/cmdline.txt

    echo -e \"\${BLUE}[Container]${NC} Finalizing...\"
    sync
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
    echo -e \"\${BLUE}[Container]${NC} Done.\"
"

echo -e "${GREEN}------------------------------------------------${NC}"
echo -e "${GREEN}--- SUCCESS: RPi 5 Master Image is Ready ---${NC}"
echo -e "${GREEN}------------------------------------------------${NC}"
