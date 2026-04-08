#!/bin/bash

# Stop script on any error
set -e

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
IMG_NAME="rpi_arch_base.img"
IMG_FILE="$WORKSPACE/$IMG_NAME"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
DOWNLOAD_URL="http://os.archlinuxarm.org/os/$ARCH_TARBALL"
# 7GB (2GB Boot + ~4.5GB Root + overhead)
IMG_SIZE="7G" 

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

# 2. Idempotent Image File Creation & Validation
echo "--- Step 2: Validating Image File ---"
if [ ! -f "$IMG_FILE" ]; then
    echo "Creating new $IMG_SIZE image file..."
    truncate -s "$IMG_SIZE" "$IMG_FILE"
else
    echo "File exists. Checking for partition table..."
    if file "$IMG_FILE" | grep -q "boot sector"; then
        echo "Valid partition table found."
    else
        echo "File is blank. Initializing..."
        truncate -s "$IMG_SIZE" "$IMG_FILE"
    fi
fi

# 3. Docker "Transplant" Operation
echo "--- Step 3: Running Linux Container ---"
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:latest bash -c "
    set -e
    echo 'Installing dependencies...'
    apt-get update -qq && apt-get install -y -qq fdisk e2fsprogs dosfstools libarchive-tools kpartx > /dev/null

    cd /work
    
    echo 'Cleaning up existing mappings...'
    kpartx -d $IMG_NAME || true
    
    # Partitioning
    if ! fdisk -l $IMG_NAME | grep -q \"${IMG_NAME}1\"; then
        echo 'Partitioning (2GB Boot, Remainder Root)...'
        printf 'o\nn\np\n1\n\n+2G\nt\nc\nn\np\n2\n\n\nw\n' | fdisk $IMG_NAME
        sync
    else
        echo 'Partition table already exists.'
    fi

    echo 'Mapping device partitions...'
    # Use -as to sync and wait for device nodes
    KOUT=\$(kpartx -asv $IMG_NAME)
    echo \"\$KOUT\"
    
    # Extract the loop device name (e.g., loop1) from 'add map loop1p1'
    LOOP_NAME=\$(echo \"\$KOUT\" | head -n 1 | awk '{print \$3}' | sed 's/p[0-9]//g')
    BOOT_DEV=\"/dev/mapper/\${LOOP_NAME}p1\"
    ROOT_DEV=\"/dev/mapper/\${LOOP_NAME}p2\"

    echo \"Formatting \$BOOT_DEV (BOOT) and \$ROOT_DEV (ROOT)...\"
    mkfs.vfat -n BOOT \"\$BOOT_DEV\"
    mkfs.ext4 -F -L ROOT \"\$ROOT_DEV\"
    
    echo 'Extracting Arch Linux ARM (this takes a minute)...'
    mkdir -p /mnt/root
    mount \"\$ROOT_DEV\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"\$BOOT_DEV\" /mnt/root/boot
    
    bsdtar -xpf $ARCH_TARBALL -C /mnt/root
    
    echo 'Finalizing...'
    sync
    umount -R /mnt/root
    kpartx -d $IMG_NAME
    echo 'Container work complete.'
"

echo "-------------------------------------------"
echo "--- SUCCESS: Your base image is ready ---"
echo "Location: $IMG_FILE"
echo "-------------------------------------------"
