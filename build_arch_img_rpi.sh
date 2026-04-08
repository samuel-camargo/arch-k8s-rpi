#!/bin/bash

# Exit on error
set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

# We will check both of these locations
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
log "Cloned $BASE_IMG to $RPI5_IMG."

log "Step 2: Launching Docker for Offline Injection"
docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    echo 'Installing system dependencies...'
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd fdisk dosfstools e2fsprogs curl > /dev/null

    cd /work
    
    echo 'Fetching mirror indexes (Core & Alarm)...'
    CORE_LIST=\$(curl -sL $MIRROR_CORE/)
    ALARM_LIST=\$(curl -sL $MIRROR_ALARM/)
    FULL_LIST=\"\$CORE_LIST \$ALARM_LIST\"
    
    # Discovery function that returns the full URL
    FIND_URL() {
        PKG_NAME=\$(echo \"\$FULL_LIST\" | grep -oE \"\$1-[0-9][^[:space:]\\\">]+\.pkg\.tar\.(zst|xz)\" | sort -V | tail -n 1)
        if echo \"\$CORE_LIST\" | grep -q \"\$PKG_NAME\"; then
            echo \"$MIRROR_CORE/\$PKG_NAME\"
        else
            echo \"$MIRROR_ALARM/\$PKG_NAME\"
        fi
    }

    KERNEL_URL=\$(FIND_URL \"linux-rpi\")
    BOOT_URL=\$(FIND_URL \"raspberrypi-bootloader\")
    FIRM_URL=\$(FIND_URL \"raspberrypi-firmware\")

    # Extract filenames for the extraction loop
    KERNEL_PKG=\$(basename \$KERNEL_URL)
    BOOT_PKG=\$(basename \$BOOT_URL)
    FIRM_PKG=\$(basename \$FIRM_URL)

    echo \"Found Kernel: \$KERNEL_PKG\"
    echo \"Found Bootloader: \$BOOT_PKG\"
    echo \"Found Firmware: \$FIRM_PKG\"

    if [[ \"\$KERNEL_PKG\" == \"/\" || \"\$BOOT_PKG\" == \"/\" ]]; then
        echo 'ERROR: Discovery failed. Check mirror paths.'
        exit 1
    fi

    URLS=(\"\$KERNEL_URL\" \"\$BOOT_URL\" \"\$FIRM_URL\")
    for url in \"\${URLS[@]}\"; do
        pkg=\$(basename \$url)
        if [ ! -f \"\$pkg\" ]; then
            echo \"Downloading \$pkg...\"
            wget --show-progress -q \"\$url\"
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
    PKGS=(\"\$KERNEL_PKG\" \"\$BOOT_PKG\" \"\$FIRM_PKG\")
    for pkg in \"\${PKGS[@]}\"; do
        echo \"Extracting \$pkg...\"
        tar -xpf \"\$pkg\" -C /mnt/root --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.INSTALL'
    done

    echo 'Configuring Headless Access...'
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
