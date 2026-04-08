#!/bin/bash

# --- Configuration ---
WORKSPACE="$HOME/rpi_arch_build"
IMG_FILE="$WORKSPACE/rpi_arch_base.img"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
DOWNLOAD_URL="http://os.archlinuxarm.org/os/$ARCH_TARBALL"
IMG_SIZE="4G" # Minimum size for K8s base OS

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# 1. Idempotent Download
echo "--- Step 1: Checking ALARM Image ---"
if [ ! -f "$ARCH_TARBALL" ]; then
    echo "Downloading Arch Linux ARM..."
    wget -c "$DOWNLOAD_URL"
else
    echo "Image already downloaded."
fi

# 2. Create Base Image (if not exists)
echo "--- Step 2: Creating Sparse Image ---"
if [ ! -f "$IMG_FILE" ]; then
    echo "Creating $IMG_SIZE image file..."
    # mkfile or truncate is faster than dd for sparse files
    truncate -s "$IMG_SIZE" "$IMG_FILE"
else
    echo "Image file already exists."
fi

# 3. Docker "Transplant" Operation
# We use a privileged Ubuntu container to partition/format the file
echo "--- Step 3: Running Linux Container to prepare OS ---"
docker run --rm --privileged \
    -v "$WORKSPACE":/work \
    ubuntu:latest bash -c "
    apt-get update && apt-get install -y fdisk e2fsprogs dosfstools bsdtar
    
    cd /work
    LOOP_DEV=\$(losetup -fP --show $IMG_FILE)
    echo 'Loop device created at '\$LOOP_DEV
    
    # Idempotent Partitioning
    echo 'Partitioning...'
    # Create MBR, 200MB Boot (FAT32), Remainder Root (Ext4)
    # This is wrapped in a check to see if partitions already exist
    if ! lsblk \$LOOP_DEV | grep -q 'p1'; then
        printf 'o\nn\np\n1\n\n+200M\nt\nc\nn\np\n2\n\n\nw\n' | fdisk \$LOOP_DEV
    fi
    
    # Idempotent Formatting
    echo 'Formatting partitions...'
    mkfs.vfat -n BOOT \${LOOP_DEV}p1
    mkfs.ext4 -L ROOT \${LOOP_DEV}p2
    
    # Extraction
    echo 'Extracting Arch Linux ARM...'
    mkdir -p /mnt/root
    mount \${LOOP_DEV}p2 /mnt/root
    mkdir -p /mnt/root/boot
    mount \${LOOP_DEV}p1 /mnt/root/boot
    
    # Extract with bsdtar (retains permissions better than GNU tar for this)
    bsdtar -xpf $ARCH_TARBALL -C /mnt/root
    
    # Clean up and Sync
    echo 'Syncing...'
    sync
    umount -R /mnt/root
    losetup -d \$LOOP_DEV
    echo 'Container work complete.'
"

echo "--- Setup Complete ---"
echo "Your base image is ready at: $IMG_FILE"
