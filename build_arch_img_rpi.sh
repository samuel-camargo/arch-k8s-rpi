#!/bin/bash

set -e

# --- CONFIGURATION ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="PT"

WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

MIRROR_CORE="http://fl.us.mirror.archlinuxarm.org/aarch64/core"
MIRROR_ALARM="http://fl.us.mirror.archlinuxarm.org/aarch64/alarm"

# Colors
B_MAGENTA='\033[1;35m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m' 

log_header() { echo -e "\n${B_MAGENTA}==================== $1 ====================${NC}"; }
log_step()   { echo -e "${B_CYAN}[🚀 STEP]${NC} $1"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log_header "RPI 5 MASTER: 128GB RESIZE & 5GHz FIX"

# 1. Create a 128GB Sparse Image
log_step "Creating 128GB expanded image container..."
# Truncate creates a 'sparse' file that looks 128GB but takes 0 space until written
truncate -s 120G "$RPI5_IMG" 
echo -e "       ${B_GREEN}✔${NC} 128GB (Sparse) target initialized."

log_step "Launching Docker for Partition Surgery & Injection..."

docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" \
    -e WIFI_PASS="$WIFI_PASS" \
    -e REG_DOMAIN="$REG_DOMAIN" \
    -e RPI5_IMG="$RPI5_IMG" \
    -e BASE_IMG="$BASE_IMG" \
    -e MIRROR_CORE="$MIRROR_CORE" \
    -e MIRROR_ALARM="$MIRROR_ALARM" \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    task() { echo -e \"\033[1;35m  [TASK]\033[0m \$1\"; }
    succ() { echo -e \"         \033[1;32m✔\033[0m \$1\"; }

    apt-get update -qq > /dev/null && apt-get install -y -qq apt-utils > /dev/null 2>&1
    apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod rsync > /dev/null

    cd /work
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done

    # --- PARTITION SURGERY ---
    task 'Re-partitioning to 2GB Boot + 126GB Root...'
    # Create new partition table on the empty 128GB image
    fdisk \"\$RPI5_IMG\" <<EOF
o
n
p
1

+2G
t
c
n
p
2


w
EOF
    succ 'Partition table rewritten.'

    task 'Formatting new partitions...'
    losetup -D
    LOOP_NEW=\$(losetup -f)
    losetup \"\$LOOP_DEV\" \"\$RPI5_IMG\"
    kpartx -as \"\$LOOP_NEW\"
    
    # Identify new mappers (assumes loop0p1, loop0p2)
    MAP_NEW_BOOT=\"/dev/mapper/\$(ls /dev/mapper | grep 'p1' | head -1)\"
    MAP_NEW_ROOT=\"/dev/mapper/\$(ls /dev/mapper | grep 'p2' | head -1)\"

    mkfs.vfat -F32 \"\$MAP_NEW_BOOT\" > /dev/null
    mkfs.ext4 -F \"\$MAP_NEW_ROOT\" > /dev/null
    succ 'Formatting complete.'

    # --- DATA MIGRATION ---
    task 'Migrating Arch Linux Base to new 128GB structure...'
    mkdir -p /mnt/base_root /mnt/new_root /mnt/new_boot
    
    # Mount the old base image
    LOOP_BASE=\$(losetup -f)
    losetup \"\$LOOP_BASE\" \"\$BASE_IMG\"
    KOUT_BASE=\$(kpartx -asv \"\$LOOP_BASE\")
    MAP_BASE_ROOT=\"/dev/mapper/\$(echo \"\$KOUT_BASE\" | grep 'p2' | awk '{print \$3}')\"
    
    mount \"\$MAP_BASE_ROOT\" /mnt/base_root
    mount \"\$MAP_NEW_ROOT\" /mnt/new_root
    mount \"\$MAP_NEW_BOOT\" /mnt/new_root/boot

    # Copy everything from base to new
    rsync -aAX /mnt/base_root/ /mnt/new_root/
    succ 'Base system migrated.'

    # --- HARDWARE INJECTION ---
    task 'Injecting RPi 5 Kernel and Firmware...'
    # Discovery
    K_RAW=\$(curl -sL \$MIRROR_CORE/)
    F_RAW=\$(curl -sL \$MIRROR_ALARM/)
    KERNEL_PKG=\$(echo \"\$K_RAW\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    FIRM_RPI=\$(echo \"\$F_RAW\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    BOOT_PKG=\$(echo \"\$F_RAW\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    [ ! -f \"\$KERNEL_PKG\" ] && wget -q \"\$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$FIRM_RPI\" ] && wget -q \"\$MIRROR_ALARM/\$FIRM_RPI\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q \"\$MIRROR_ALARM/\$BOOT_PKG\"

    rm -rf /mnt/new_root/usr/lib/modules/* /mnt/new_root/boot/*
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/new_root --exclude='.PKGINFO'
    tar -xpf \"\$FIRM_RPI\" -C /mnt/new_root --exclude='.PKGINFO'
    tar -xpf \"\$BOOT_PKG\" -C /mnt/new_root --exclude='.PKGINFO'
    [ -d /mnt/new_root/boot/boot ] && mv /mnt/new_root/boot/boot/* /mnt/new_root/boot/ && rmdir /mnt/new_root/boot/boot
    KVER=\$(ls /mnt/new_root/usr/lib/modules | head -n 1)
    depmod -b /mnt/new_root \$KVER

    # --- 5GHz WiFi FIX ---
    task 'Applying 5GHz WiFi (PT) Stability Patch...'
    echo \"WIRELESS_REGDOM='\$REG_DOMAIN'\" > /mnt/new_root/etc/conf.d/wireless-regdom
    
    # Extra flags for 5GHz: scan_ssid=1, key_mgmt, proto
    printf \"ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\ncountry=\$REG_DOMAIN\n\nnetwork={\n    ssid=\\\"\$WIFI_SSID\\\"\n    psk=\\\"\$WIFI_PASS\\\"\n    scan_ssid=1\n    key_mgmt=WPA-PSK\n    proto=RSN\n    pairwise=CCMP\n    group=CCMP\n}\n\" > /mnt/new_root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf

    cat <<EOF > /mnt/new_root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
DHCP=yes
IgnoreCarrierLoss=3s
EOF
    
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/sshd.service

    # --- CLEANUP & BOOT CONFIG ---
    sed -i 's/^root:[^:]*:/root::/' /mnt/new_root/etc/shadow
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=bcm2712-rpi-5-b.dtb\nusb_max_current_enable=1\" > /mnt/new_root/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0\" > /mnt/new_root/boot/cmdline.txt

    sync
    umount -R /mnt/base_root || true
    umount -R /mnt/new_root || true
    kpartx -d \"\$LOOP_BASE\"
    kpartx -d \"\$LOOP_NEW\"
    losetup -D
    succ '128GB Image stretch and 5GHz fix complete.'
"

log_header "SUCCESS: READY TO FLASH"
echo -e "Follow these steps on your Mac terminal:\n"
echo -e "1. ${B_WHITE}Identify SD Card:${NC} ${B_YELLOW}diskutil list${NC}"
echo -e "2. ${B_WHITE}Unmount Card:${NC}    ${B_YELLOW}diskutil unmountDisk /dev/diskX${NC}"
echo -e "3. ${B_WHITE}Flash:${NC}           ${B_CYAN}sudo dd if=$WORKSPACE/$RPI5_IMG of=/dev/diskX bs=4M status=progress${NC}"
echo -e "\n${B_YELLOW}NOTE: The image is now 128GB. The 'dd' command will take much longer.${NC}"
log_header "========================================"
