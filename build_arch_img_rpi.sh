#!/bin/bash

set -e

# --- CONFIGURATION ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

MIRROR_CORE="http://fl.us.mirror.archlinuxarm.org/aarch64/core"
MIRROR_ALARM="http://fl.us.mirror.archlinuxarm.org/aarch64/alarm"

# --- COLOR PALETTE ---
# Bold Colors
B_BLUE='\033[1;34m'
B_GREEN='\033[1;32m'
B_CYAN='\033[1;36m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
B_MAGENTA='\033[1;35m'
NC='\033[0m' # No Color

# Helper functions for logging
log_step() { echo -e "${B_BLUE}[STEP]${NC} $1"; }
log_info() { echo -e "${B_CYAN}[INFO]${NC} $1"; }
log_pkg()  { echo -e "       📦 ${B_GREEN}$1${NC}: $2"; }
log_warn() { echo -e "${B_YELLOW}[WARN]${NC} $1"; }
log_done() { echo -e "${B_GREEN}[SUCCESS]${NC} $1"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo -e "${B_MAGENTA}====================================================${NC}"
echo -e "${B_MAGENTA}   RASPBERRY PI 5 ARCH LINUX MASTER PATCHER         ${NC}"
echo -e "${B_MAGENTA}====================================================${NC}"

log_step "Cloning base image to RPi 5 Master image..."
if [ ! -f "$BASE_IMG" ]; then
    echo -e "${B_RED}[ERROR] Base image not found. Run build_arch_img.sh first.${NC}"
    exit 1
fi
cp "$BASE_IMG" "$RPI5_IMG"
log_info "Workspace verified at: $WORKSPACE"

log_step "Launching Docker context for hardware injection..."
docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    # Internal Logging
    msg_info() { echo -e \"\033[1;36m[DOCKER]\033[0m \$1\"; }
    msg_pkg()  { echo -e \"       \033[1;32m✔️ FOUND\033[0m \$1\"; }

    apt-get update -qq && apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod > /dev/null

    cd /work
    
    msg_info 'Provisioning virtual device nodes...'
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done

    msg_info 'Querying Florida Mirror for latest hardware-specific packages...'
    
    # Discovery
    KERNEL_PKG=\$(curl -sL $MIRROR_CORE/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    FIRM_RPI=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    BOOT_PKG=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    msg_pkg \"Kernel:   \$KERNEL_PKG\"
    msg_pkg \"Firmware: \$FIRM_RPI\"
    msg_pkg \"Boot:     \$BOOT_PKG\"

    # Downloads
    msg_info 'Downloading missing packages...'
    [ ! -f \"\$KERNEL_PKG\" ] && wget -q --show-progress \"$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$FIRM_RPI\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$FIRM_RPI\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$BOOT_PKG\"

    msg_info 'Binding image to loop device...'
    losetup -D
    LOOP_DEV=\$(losetup -f)
    losetup \"\$LOOP_DEV\" $RPI5_IMG
    KOUT=\$(kpartx -asv \"\$LOOP_DEV\")
    
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    msg_info \"Mounted partitions via \$LOOP_DEV\"
    mkdir -p /mnt/root && mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot && mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    msg_info 'Performing partition surgery (Wiping old drivers/boot)...'
    rm -rf /mnt/root/usr/lib/modules/*
    rm -rf /mnt/root/boot/*

    msg_info 'Injecting RPi 5 hardware support files...'
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$FIRM_RPI\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$BOOT_PKG\" -C /mnt/root --exclude='.PKGINFO'

    msg_info 'Fixing directory structure...'
    [ -d /mnt/root/boot/boot ] && mv /mnt/root/boot/boot/* /mnt/root/boot/ && rmdir /mnt/root/boot/boot

    msg_info 'Running depmod to initialize driver paths...'
    KVER=\$(ls /mnt/root/usr/lib/modules | head -n 1)
    depmod -b /mnt/root \$KVER

    msg_info 'Injecting WiFi credentials (Forcing wlan0 naming)...'
    mkdir -p /mnt/root/etc/wpa_supplicant
    cat <<EOF > /mnt/root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASS\"
}
EOF
    
    mkdir -p /mnt/root/etc/systemd/network
    cat <<EOF > /mnt/root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan*
[Network]
DHCP=yes
EOF

    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service

    msg_info 'Finalizing config.txt and cmdline.txt...'
    echo 'arm_64bit=1' > /mnt/root/boot/config.txt
    echo 'kernel=Image' >> /mnt/root/boot/config.txt
    echo 'device_tree=bcm2712-rpi-5-b.dtb' >> /mnt/root/boot/config.txt
    echo 'usb_max_current_enable=1' >> /mnt/root/boot/config.txt
    
    # The 'net.ifnames=0' flag forces the interface to be named wlan0 instead of wld0
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0\" > /mnt/root/boot/cmdline.txt

    msg_info 'Clearing root password for easy first login...'
    sed -i 's/root:\*:/root::/' /mnt/root/etc/shadow

    sync
    umount -R /mnt/root
    kpartx -d \"\$LOOP_DEV\"
    losetup -d \"\$LOOP_DEV\"
"

echo -e "${B_MAGENTA}----------------------------------------------------${NC}"
log_done "RPi 5 Master Image is Ready for Flashing!"
echo -e "Next steps:"
echo -e " 1. Flash to SD card: ${B_CYAN}sudo dd if=$RPI5_IMG of=/dev/rdiskX bs=4M status=progress${NC}"
echo -e " 2. Boot Pi 5 and wait 60 seconds."
echo -e " 3. Login as ${B_GREEN}root${NC} (no password)."
echo -e " 4. Check network: ${B_GREEN}ip addr show wlan0${NC}"
echo -e "${B_MAGENTA}====================================================${NC}"
