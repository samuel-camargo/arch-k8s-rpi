#!/bin/bash

set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo "--- Step 1: Cloning Base Image for RPi 5 ---"
if [ ! -f "$RPI5_IMG" ]; then
    cp "$BASE_IMG" "$RPI5_IMG"
    echo "Created $RPI5_IMG."
else
    echo "$RPI5_IMG already exists. Patching existing file..."
fi

echo "--- Step 2: Patching Kernel for RPi 5 via Docker ---"
# Note: Removed the qemu volume mount as it's not needed on Apple Silicon
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive

    echo 'Installing dependencies (kpartx, fdisk, libarchive)...'
    apt-get update -qq
    apt-get install -y -qq kpartx fdisk e2fsprogs dosfstools libarchive-tools > /dev/null

    cd /work
    
    echo 'Mapping partitions...'
    # Clean up any stale mappings
    kpartx -d $RPI5_IMG || true
    
    # Map partitions and capture output
    KOUT=\$(kpartx -asv $RPI5_IMG)
    echo \"\$KOUT\"
    
    # Identify mapper nodes
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/rpi5
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/rpi5
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/rpi5/boot

    echo 'Injecting RPi 5 specific kernel and firmware...'
    # We use 'chroot' to run pacman inside the Arch image.
    # On M1/M2/M3 Macs, this runs at native speed.
    chroot /mnt/rpi5 /usr/bin/bash -c \"
        set -e
        # Initialize pacman keys
        pacman-key --init
        pacman-key --populate archlinuxarm
        
        # Update system and swap kernels
        # linux-rpi is the package for RPi 4 and 5
        pacman -Sy --noconfirm
        pacman -R --noconfirm linux-aarch64 || true
        pacman -S --noconfirm linux-rpi raspberrypi-bootloader raspberrypi-firmware
    \"

    echo 'Finalizing boot configuration...'
    # Ensure the RPi 5 knows how to find its partitions
    echo '/dev/mmcblk0p1  /boot   vfat    defaults        0       0' > /mnt/rpi5/etc/fstab
    echo '/dev/mmcblk0p2  /       ext4    defaults,noatime  0       1' >> /mnt/rpi5/etc/fstab

    sync
    echo 'Unmounting and cleaning up...'
    umount -R /mnt/rpi5
    kpartx -d $RPI5_IMG
    echo 'Patch complete.'
"

echo "------------------------------------------------"
echo "--- SUCCESS: RPi 5 Master Image is Ready ---"
echo "------------------------------------------------"
