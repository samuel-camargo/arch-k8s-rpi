#!/bin/bash

set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

# Arch Linux ARM Mirror for RPi 5 packages
MIRROR="http://mirror.archlinuxarm.org/aarch64/alarm"
PKGS=(
    "linux-rpi-6.6.22-1-aarch64.pkg.tar.zst"
    "raspberrypi-bootloader-20240314-1-any.pkg.tar.zst"
    "raspberrypi-firmware-20240314-1-aarch64.pkg.tar.zst"
)

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo "--- Step 1: Cloning Base Image for RPi 5 ---"
cp "$BASE_IMG" "$RPI5_IMG"

echo "--- Step 2: Injecting RPi 5 Kernel/Firmware (Offline) ---"
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    echo 'Installing injection tools (zstd, kpartx)...'
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd > /dev/null

    cd /work
    
    # Download packages if not present
    for pkg in ${PKGS[@]}; do
        if [ ! -f \"\$pkg\" ]; then
            echo \"Downloading \$pkg...\"
            wget -q \"$MIRROR/\$pkg\"
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

    echo 'Injecting files into image (Manual Extraction)...'
    # We extract the packages directly into the mount points
    # This bypasses the need to 'run' any Arch binaries
    for pkg in ${PKGS[@]}; do
        echo \"Extracting \$pkg...\"
        # Use tar with zstd support
        tar --zstd -xpf \"\$pkg\" -C /mnt/root
    done

    echo 'Cleaning up generic kernel traces...'
    rm -f /mnt/root/boot/Image
    rm -rf /mnt/root/usr/lib/modules/*-ARCH

    echo 'Updating fstab...'
    echo '/dev/mmcblk0p1  /boot   vfat    defaults        0       0' > /mnt/root/etc/fstab
    echo '/dev/mmcblk0p2  /       ext4    defaults,noatime  0       1' >> /mnt/root/etc/fstab

    echo 'Configuring cmdline.txt for RPi 5...'
    echo 'root=/dev/mmcblk0p2 rw rootwait console=serial0,115200 console=tty1 selinux=0 plymouth.enable=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 kgdboc=serial0,115200' > /mnt/root/boot/cmdline.txt

    sync
    echo 'Unmounting...'
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
    echo 'RPi 5 Patch Complete.'
"

echo "------------------------------------------------"
echo "--- SUCCESS: RPi 5 Master Image is Ready ---"
echo "------------------------------------------------"
