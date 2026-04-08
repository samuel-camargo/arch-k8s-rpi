#!/bin/bash

set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

cd "$WORKSPACE"

echo "--- Step 1: Cloning Base Image for RPi 5 ---"
if [ ! -f "$RPI5_IMG" ]; then
    cp "$BASE_IMG" "$RPI5_IMG"
    echo "Created $RPI5_IMG."
else
    echo "$RPI5_IMG already exists. Patching existing file."
fi

echo "--- Step 2: Patching Kernel for RPi 5 (via Docker + QEMU) ---"
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    -v /usr/bin/qemu-aarch64-static:/usr/bin/qemu-aarch64-static \
    ubuntu:latest bash -c "
    set -e
    apt-get update -qq && apt-get install -y -qq kpartx libarchive-tools qemu-user-static > /dev/null

    cd /work
    kpartx -d $RPI5_IMG || true
    KOUT=\$(kpartx -asv $RPI5_IMG)
    
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/rpi5
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/rpi5
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/rpi5/boot

    echo 'Entering Chroot to swap kernels...'
    # Use systemd-nspawn or chroot with QEMU to run ARM pacman
    # We initialize the pacman keys and swap the kernel
    chroot /mnt/rpi5 /usr/bin/bash -c \"
        # Initialize pacman keys
        pacman-key --init
        pacman-key --populate archlinuxarm
        
        # Remove generic kernel and install RPi specific kernel
        # --noconfirm makes it idempotent/scriptable
        pacman -R --noconfirm linux-aarch64 || true
        pacman -Syu --noconfirm linux-rpi raspberrypi-bootloader raspberrypi-firmware
    \"

    echo 'Updating fstab for RPi boot...'
    # Ensure /boot points to the correct partition
    echo '/dev/mmcblk0p1  /boot   vfat    defaults        0       0' > /mnt/rpi5/etc/fstab
    echo '/dev/mmcblk0p2  /       ext4    defaults,noatime  0       1' >> /mnt/rpi5/etc/fstab

    sync
    umount -R /mnt/rpi5
    kpartx -d $RPI5_IMG
"

echo "------------------------------------------------"
echo "--- SUCCESS: RPi 5 Master Image is Ready ---"
echo "Location: $WORKSPACE/$RPI5_IMG"
echo "------------------------------------------------"
