#!/bin/bash

# Stop script on any error
set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
IMG_NAME="rpi_arch_base.img"
IMG_FILE="$WORKSPACE/$IMG_NAME"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
DOWNLOAD_URL="http://os.archlinuxarm.org/os/$ARCH_TARBALL"
# Increased image size to 6GB to accommodate the 2GB boot partition + rootfs
IMG_SIZE="6G" 

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# 1. Idempotent Download
echo "--- Step 1: Checking ALARM Image ---"
if [ ! -f "$ARCH_TARBALL" ]; then
    echo "Downloading Arch Linux ARM..."
    wget -c "$DOWNLOAD_URL"
else
    echo "Image already downloaded. Skipping."
fi

# 2. Create Base Image (if not exists)
echo "--- Step 2: Creating Sparse Image ---"
if [ ! -f "$IMG_FILE" ]; then
    echo "Creating $IMG_SIZE image file..."
    truncate -s "$IMG_SIZE" "$IMG_FILE"
else
    echo "Image file $IMG_NAME already exists. Skipping creation."
fi

# 3. Docker "Transplant" Operation
echo "--- Step 3: Running Linux Container to prepare OS ---"
# We pass the filename only, as the path inside the container is /work/
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:latest bash -c "
    set -e
    echo 'Installing dependencies inside container...'
    apt-get update -qq
    apt-get install -y -qq fdisk e2fsprogs dosfstools libarchive-tools > /dev/null

    cd /work
    
    echo 'Setting up loop device...'
    # Detach any existing loop devices for this file first to ensure idempotency
    EXISTING_LOOP=\$(losetup -j $IMG_NAME | cut -d ':' -f1)
    for l in \$EXISTING_LOOP; do losetup -d \$l; done
    
    LOOP_DEV=\$(losetup -fP --show $IMG_NAME)
    echo \"Loop device created at \$LOOP_DEV\"

    # Idempotent Partitioning: Only partition if p1 doesn't exist
    if ! lsblk \$LOOP_DEV | grep -q \"\${LOOP_DEV##*/}p1\"; then
        echo 'Partitioning (2GB Boot, Remainder Root)...'
        # o: clear, n: new, p: primary, 1: part num, default start, +2G: size, t: type, c: W95 FAT32 (LBA)
        printf 'o\nn\np\n1\n\n+2G\nt\nc\nn\np\n2\n\n\nw\n' | fdisk \$LOOP_DEV
        sync
    else
        echo 'Partitions already exist. Skipping.'
    fi

    echo 'Formatting partitions...'
    mkfs.vfat -n BOOT \${LOOP_DEV}p1
    mkfs.ext4 -F -L ROOT \${LOOP_DEV}p2
    
    echo 'Extracting Arch Linux ARM...'
    mkdir -p /mnt/root
    mount \${LOOP_DEV}p2 /mnt/root
    mkdir -p /mnt/root/boot
    mount \${LOOP_DEV}p1 /mnt/root/boot
    
    # Use bsdtar (package libarchive-tools) to extract
    bsdtar -xpf $ARCH_TARBALL -C /mnt/root
    
    echo 'Finalizing and Syncing...'
    sync
    umount -R /mnt/root
    losetup -d \$LOOP_DEV
    echo 'Container work complete.'
"

echo "-------------------------------------------"
echo "--- SUCCESS: Your base image is ready ---"
echo "Location: $IMG_FILE"
echo "-------------------------------------------"
