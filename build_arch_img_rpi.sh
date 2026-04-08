#!/bin/bash

# Configuration
DISK="/dev/disk4" # CHANGE THIS to your actual SD card disk
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
DOWNLOAD_URL="http://os.archlinuxarm.org/os/$ARCH_TARBALL"
BOOT_SIZE="200M"

# 1. Environment Validation
echo "--- Validating Environment ---"
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: This script is designed for macOS."
    exit 1
fi

if ! command -v wget &> /dev/null; then
    echo "Error: wget not found. Install via 'brew install wget'."
    exit 1
fi

# 2. Idempotent Download
echo "--- Checking ALARM Image ---"
if [ -f "$ARCH_TARBALL" ]; then
    echo "Tarball already exists. Skipping download."
else
    echo "Downloading Arch Linux ARM..."
    wget -O "$ARCH_TARBALL" "$DOWNLOAD_URL"
fi

# 3. Target Disk Validation
echo "--- Validating Target Disk ---"
# Check if disk exists and is external
DISK_INFO=$(diskutil info $DISK)
if [[ $? -ne 0 ]]; then
    echo "Error: Disk $DISK not found."
    exit 1
fi

if [[ "$DISK_INFO" != *"Device Location: External"* ]]; then
    echo "Error: $DISK is not an external drive! Safety first."
    exit 1
fi

# 4. Idempotent Partitioning
echo "--- Partitioning SD Card ---"
# This will wipe the card and create:
# P1: BOOT (FAT32) - 200MB
# P2: ROOT (Linux) - Remainder of the card
# Using 'diskutil' to ensure the card is unmounted and partitioned correctly
echo "WARNING: This will erase all data on $DISK. Proceed? (y/n)"
read -r response
if [[ "$response" != "y" ]]; then
    exit 1
fi

# Unmount the disk before partitioning
diskutil unmountDisk $DISK

# Partition the disk
# MBR partition map is required for RPi boot
diskutil partitionDisk $DISK MBR \
    "MS-DOS FAT32" "BOOT" $BOOT_SIZE \
    "Free Space" "ROOT" R

echo "--- Disk Prepared ---"
echo "Partition 1 (BOOT) created as FAT32."
echo "Partition 2 (ROOT) space reserved."
