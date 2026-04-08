#!/bin/bash

# Exit on error
set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"
MIRROR="http://mirror.archlinuxarm.org/aarch64/alarm"

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error_exit() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

trap 'echo -e "${RED}Script interrupted or failed unexpectedly.${NC}"' ERR

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log "Step 1: Cloning Base Image for RPi 5"
if [ ! -f "$BASE_IMG" ]; then
    error_exit "Base image $BASE_IMG not found! Run the base build script first."
fi

if [ ! -f "$RPI5_IMG" ]; then
    cp "$BASE_IMG" "$RPI5_IMG"
    log "Cloned $BASE_IMG to $RPI5_IMG."
else
    log "$RPI5_IMG already exists. Patching existing file."
fi

log "Step 2: Launching Docker for Offline Injection"
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    BLUE='\033[0;34m'
    NC='\033[0m'

    echo -e \"\${BLUE}[Container]${NC} Installing system dependencies...\"
    apt-get update -qq
    apt-get install -y -qq kpartx wget zstd fdisk dosfstools e2fsprogs curl > /dev/null

    cd /work
    
    echo -e \"\${BLUE}[Container]${NC} Discovering latest RPi 5 packages from mirror...\"
    # Get the directory listing
    HTML_LIST=\$(curl -sL $MIRROR/)
    
    # Robust discovery function
    # 1. Finds the package name
    # 2. Extracts everything between href=\" and \"
    # 3. Filters for the correct architecture (aarch64 or any)
    # 4. Takes the last one (usually highest version)
    GET_LATEST() {
        echo \"\$HTML_LIST\" | grep -oE \"href=\\\"\$1-[0-9][^\ ]+\.pkg\.tar\.zst\\\"\" | sed 's/href=\"//;s/\"//' | sort -V | tail -n 1
    }

    KERNEL_PKG=\$(GET_LATEST \"linux-rpi\")
    BOOT_PKG=\$(GET_LATEST \"raspberrypi-bootloader\")
    FIRM_PKG=\$(GET_LATEST \"raspberrypi-firmware\")

    echo -e \"\${BLUE}[Container]${NC} Discovered:\"
    echo \"  - Kernel: \$KERNEL_PKG\"
    echo \"  - Bootloader: \$BOOT_PKG\"
    echo \"  - Firmware: \$FIRM_PKG\"

    PKGS=(\"\$KERNEL_PKG\" \"\$BOOT_PKG\" \"\$FIRM_PKG\")

    for pkg in \"\${PKGS[@]}\"; do
        if [ -z \"\$pkg\" ]; then 
            echo -e \"\${RED}[ERROR] Failed to discover one or more packages on mirror.\${NC}\"
            exit 1
        fi
        if [ ! -f \"\$pkg\" ]; then
            echo \"Downloading \$pkg...\"
            wget --show-progress -q \"$MIRROR/\$pkg\"
        else
            echo \"\$pkg already present in workspace.\"
        fi
    done

    echo -e \"\${BLUE}[Container]${NC} Mapping image partitions...\"
    kpartx -d $RPI5_IMG || true
    KOUT=\$(kpartx -asv $RPI5_IMG)
    
    # Use grep to find the specific loop device created
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/root
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    echo -e \"\${BLUE}[Container]${NC} Injecting files into partitions...\"
    for pkg in \"\${PKGS[@]}\"; do
        echo \"Extracting \$pkg...\"
        tar --zstd -xpf \"\$pkg\" -C /mnt/root --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.INSTALL'
    done

    echo -e \"\${BLUE}[Container]${NC} Finalizing boot configuration...\"
    # Ensure fstab uses the SD card device naming
    cat <<EOF > /mnt/root/etc/fstab
/dev/mmcblk0p1  /boot   vfat    defaults        0       0
/dev/mmcblk0p2  /       ext4    defaults,noatime  0       1
EOF

    # Configure cmdline.txt for RPi 5
    echo 'root=/dev/mmcblk0p2 rw rootwait console=serial0,115200 console=tty1 selinux=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0' > /mnt/root/boot/cmdline.txt

    # Clean up any generic kernel modules to save space
    rm -rf /mnt/root/usr/lib/modules/*-ARCH || true

    sync
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
    echo -e \"\${BLUE}[Container]${NC} Injection successful.\"
"

echo -e "${GREEN}------------------------------------------------${NC}"
echo -e "${GREEN}--- SUCCESS: RPi 5 Master Image is Ready ---${NC}"
echo -e "${GREEN}------------------------------------------------${NC}"
