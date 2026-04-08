#!/bin/bash

# Stop script on any error
set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
IMG_NAME="rpi_arch_base.img"
IMG_FILE="$WORKSPACE/$IMG_NAME"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
DOWNLOAD_URL="http://os.archlinuxarm.org/os/$ARCH_TARBALL"
# 6GB: 2GB Boot + ~3.5GB Root + overhead
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

# 2. Idempotent Image File Creation
echo "--- Step 2: Validating Image File ---"
if [ ! -f "$IMG_FILE" ]; then
    echo "Creating new $IMG_SIZE image file..."
    truncate -s "$IMG_SIZE" "$IMG_FILE"
else
    echo "File exists. Checking if it's a valid partitioned image..."
    # We use 'file' to see if there's a partition table. 
    # Blank files show as 'data'. Partitioned images show 'DOS/MBR boot sector'
    if file "$IMG_FILE" | grep -q "boot sector"; then
        echo "Valid partition table found. Keeping existing file."
    else
        echo "File is blank or invalid. Re-creating..."
        rm "$IMG_FILE"
        truncate -s "$IMG_SIZE" "$IMG_FILE"
    fi
fi

# 3. Docker "Transplant" Operation
echo "--- Step 3: Running Linux Container ---"
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:latest bash -c "
    set -e
    echo 'Installing dependencies (parted, fdisk, etc.)...'
    apt-get update -qq
    apt-get install -y -qq fdisk e2fsprogs dosfstools libarchive-tools parted > /dev/null

    cd /work
    
    echo 'Setting up loop device...'
    # Clean up any old loops to prevent 'Device Busy' errors
    EXISTING_LOOPS=\$(losetup -j $IMG_NAME | cut -d ':' -f1)
    for l in \$EXISTING_LOOPS; do losetup -d \$l; done
    
    LOOP_DEV=\$(losetup -fP --show $IMG_NAME)
    echo \"Loop device created at \$LOOP_DEV\"

    # Idempotent Partitioning
    # Check if partition 1 exists on the loop device
    if ! lsblk -n \$LOOP_DEV | grep -q \"p1\"; then
        echo 'Partitioning (2GB Boot, Remainder Root)...'
        printf 'o\nn\np\n1\n\n+2G\nt\nc\nn\np\n2\n\n\nw\n' | fdisk \$LOOP_DEV
        echo 'Forcing kernel to reload partition table...'
        partprobe \$LOOP_DEV
        sync
        sleep 2 # Give /dev/ entries a moment to populate
    else
        echo 'Partitions already exist.'
    fi

    # Final validation that device nodes exist before formatting
    if [ ! -b \"\${LOOP_DEV}p1\" ]; then
        echo 'ERROR: \${LOOP_DEV}p1 not found. Attempting manual mknod...'
        # Fallback for some Docker environments
        PART_NAME=\$(basename \$LOOP_DEV)
        MAJ=\$(cat /sys/block/\$PART_NAME/dev | cut -d: -f1)
        MIN_BOOT=\$(cat /sys/block/\$PART_NAME/\${PART_NAME}p1/dev | cut -d: -f2)
        MIN_ROOT=\$(cat /sys/block/\$PART_NAME/\${PART_NAME}p2/dev | cut -d: -f2)
        mknod \${LOOP_DEV}p1 b \$MAJ \$MIN_BOOT
        mknod \${LOOP_DEV}p2 b \$MAJ \$MIN_ROOT
    fi

    echo 'Formatting partitions...'
    mkfs.vfat -n BOOT \${LOOP_DEV}p1
    mkfs.ext4 -F -L ROOT \${LOOP_DEV}p2
    
    echo 'Extracting Arch Linux ARM...'
    mkdir -p /mnt/root
    mount \${LOOP_DEV}p2 /mnt/root
    mkdir -p /mnt/root/boot
    mount \${LOOP_DEV}p1 /mnt/root/boot
    
    bsdtar -xpf $ARCH_TARBALL -C /mnt/root
    
    echo 'Finalizing...'
    sync
    umount -R /mnt/root
    losetup -d \$LOOP_DEV
    echo 'Container work complete.'
"

echo "-------------------------------------------"
echo "--- SUCCESS: Your base image is ready ---"
echo "-------------------------------------------"
