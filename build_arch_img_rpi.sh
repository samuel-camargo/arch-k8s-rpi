#!/bin/bash

set -e

# --- CONFIGURATION ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="NL"  # Netherlands

WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

MIRROR_CORE="http://fl.us.mirror.archlinuxarm.org/aarch64/core"
MIRROR_ALARM="http://fl.us.mirror.archlinuxarm.org/aarch64/alarm"

# --- COLOR DEFINITIONS ---
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

log_header "RPI 5 ARCH LINUX MASTER PATCHER"

log_step "Initializing RPi 5 Master Image..."
cp "$BASE_IMG" "$RPI5_IMG"
echo -e "       ${B_GREEN}✔${NC} Destination: $RPI5_IMG"

log_step "Entering Docker Environment..."

docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" \
    -e WIFI_PASS="$WIFI_PASS" \
    -e REG_DOMAIN="$REG_DOMAIN" \
    -e RPI5_IMG="$RPI5_IMG" \
    -e MIRROR_CORE="$MIRROR_CORE" \
    -e MIRROR_ALARM="$MIRROR_ALARM" \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    # Internal UI Helpers
    task() { echo -e \"\033[1;35m  [TASK]\033[0m \$1\"; }
    pkg()  { echo -e \"         📦 \033[1;32m\$1\033[0m: \$2\"; }
    succ() { echo -e \"         \033[1;32m✔\033[0m \$1\"; }

    # FIX: Install apt-utils first to stop debconf warnings
    task 'Silencing debconf and installing build tools...'
    apt-get update -qq && apt-get install -y -qq apt-utils > /dev/null
    apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod > /dev/null
    succ 'Environment cleaned and dependencies ready.'

    task 'Provisioning loop device nodes...'
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    succ 'Loop nodes 0-15 initialized.'

    task 'Scanning mirror for latest hardware packages...'
    K_RAW=\$(curl -sL \$MIRROR_CORE/)
    F_RAW=\$(curl -sL \$MIRROR_ALARM/)
    KERNEL_PKG=\$(echo \"\$K_RAW\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    FIRM_RPI=\$(echo \"\$F_RAW\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    BOOT_PKG=\$(echo \"\$F_RAW\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    pkg 'Kernel'   \"\$KERNEL_PKG\"
    pkg 'Firmware' \"\$FIRM_RPI\"
    pkg 'Boot'     \"\$BOOT_PKG\"

    cd /work
    task 'Downloading packages to workspace...'
    [ ! -f \"\$KERNEL_PKG\" ] && wget -q --show-progress \"\$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$FIRM_RPI\" ] && wget -q --show-progress \"\$MIRROR_ALARM/\$FIRM_RPI\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q --show-progress \"\$MIRROR_ALARM/\$BOOT_PKG\"

    task 'Mounting \$RPI5_IMG...'
    losetup -D
    LOOP_DEV=\$(losetup -f)
    losetup \"\$LOOP_DEV\" \"\$RPI5_IMG\"
    KOUT=\$(kpartx -asv \"\$LOOP_DEV\")
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    mkdir -p /mnt/root && mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot && mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot
    succ 'FileSystems mounted.'

    task 'Injecting hardware support files...'
    rm -rf /mnt/root/usr/lib/modules/* /mnt/root/boot/*
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$FIRM_RPI\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$BOOT_PKG\" -C /mnt/root --exclude='.PKGINFO'
    [ -d /mnt/root/boot/boot ] && mv /mnt/root/boot/boot/* /mnt/root/boot/ && rmdir /mnt/root/boot/boot
    KVER=\$(ls /mnt/root/usr/lib/modules | head -n 1)
    depmod -b /mnt/root \$KVER
    succ \"Modules synced for \$KVER\"

    # FIX: Simplified WPA syntax to avoid extra characters/slashes
    task 'Configuring WiFi (wlan0) and Regional Domain...'
    mkdir -p /mnt/root/etc/conf.d /mnt/root/etc/wpa_supplicant /mnt/root/etc/systemd/network
    echo \"WIRELESS_REGDOM='\$REG_DOMAIN'\" > /mnt/root/etc/conf.d/wireless-regdom
    
    cat <<EOF > /mnt/root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
country=\$REG_DOMAIN
network={
    ssid=\"\$WIFI_SSID\"
    psk=\"\$WIFI_PASS\"
}
EOF

    cat <<EOF > /mnt/root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
DHCP=yes
EOF
    
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service
    succ 'Network configured.'

    task 'Clearing root password...'
    sed -i 's/^root:[^:]*:/root::/' /mnt/root/etc/shadow
    succ 'Passwordless login enabled.'

    task 'Writing Boot Config...'
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=bcm2712-rpi-5-b.dtb\nusb_max_current_enable=1\" > /mnt/root/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0\" > /mnt/root/boot/cmdline.txt
    succ 'Bootloader optimized.'

    sync
    umount -R /mnt/root
    kpartx -d \"\$LOOP_DEV\"
    losetup -d \"\$LOOP_DEV\"
    succ 'Cleanup complete.'
"

log_header "SUCCESS"
echo -e "${B_GREEN}RPi 5 Master Image is ready.${NC}"
echo -e "Next steps:"
echo -e " 1. Flash using ${B_CYAN}/dev/rdiskX${NC} for speed."
echo -e " 2. Boot and login as ${B_GREEN}root${NC} (just press Enter for password)."
echo -e "${B_MAGENTA}============================================${NC}"
