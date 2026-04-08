#!/bin/bash

set -e

# --- Configuration (FILL THESE IN) ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

MIRROR_CORE="http://fl.us.mirror.archlinuxarm.org/aarch64/core"
MIRROR_ALARM="http://fl.us.mirror.archlinuxarm.org/aarch64/alarm"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error_exit() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

trap 'echo -e "${RED}Script interrupted or failed unexpectedly.${NC}"' ERR

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log "Step 1: Cloning Base Image"
cp "$BASE_IMG" "$RPI5_IMG"

log "Step 2: Launching Docker for WiFi and Keyboard Injection"
docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd xz-utils fdisk curl > /dev/null

    cd /work
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod /dev/loop\$i b 7 \$i || true; done

    echo 'Fetching mirror indexes...'
    CORE_LIST=\$(curl -sL $MIRROR_CORE/)
    ALARM_LIST=\$(curl -sL $MIRROR_ALARM/)
    
    # Using standard 4k kernel for maximum compatibility
    KERNEL_PKG=\$(echo \"\$CORE_LIST\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    BOOT_PKG=\$(echo \"\$ALARM_LIST\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    FIRM_PKG=\$(echo \"\$ALARM_LIST\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    [ ! -f \"\$KERNEL_PKG\" ] && wget -q --show-progress \"$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$BOOT_PKG\"
    [ ! -f \"\$FIRM_PKG\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$FIRM_PKG\"

    kpartx -d $RPI5_IMG || true
    KOUT=\$(kpartx -asv $RPI5_IMG)
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/root
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    echo 'Injecting Kernel/Firmware...'
    rm -rf /mnt/root/usr/lib/modules/* /mnt/root/boot/*
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$BOOT_PKG\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$FIRM_PKG\" -C /mnt/root --exclude='.PKGINFO'

    if [ -d /mnt/root/boot/boot ]; then
        mv /mnt/root/boot/boot/* /mnt/root/boot/
        rmdir /mnt/root/boot/boot
    fi

    # --- KEYBOARD FIX 1: Early Module Loading ---
    echo 'Forcing early USB HID module loading...'
    mkdir -p /mnt/root/etc/modules-load.d
    echo 'usbhid' > /mnt/root/etc/modules-load.d/keyboard.conf
    echo 'hid_generic' >> /mnt/root/etc/modules-load.d/keyboard.conf

    # --- KEYBOARD FIX 2: Config.txt adjustments ---
    cat <<EOF > /mnt/root/boot/config.txt
arm_64bit=1
enable_uart=1
kernel=Image
device_tree=bcm2712-rpi-5-b.dtb
overlay_prefix=overlays/
usb_max_current_enable=1
# Disabling power management for the RP1 chip helps some keyboards
dtparam=pcie_aspm=off
EOF

    # --- KEYBOARD FIX 3: Prioritize TTY1 in cmdline ---
    echo 'root=/dev/mmcblk0p2 rw rootwait console=tty1 console=serial0,115200 selinux=0' > /mnt/root/boot/cmdline.txt

    # --- WIFI INJECTION: systemd-networkd + wpa_supplicant ---
    echo 'Injecting WiFi configuration...'
    cat <<EOF > /mnt/root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASS\"
}
EOF
    # Create the network profile
    cat <<EOF > /mnt/root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
DHCP=yes
EOF
    # Enable services by symlinking (manual enablement)
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/dbus-org.freedesktop.network1.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/systemd-resolved.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-resolved.service

    # SSH Headless Prep
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /mnt/root/etc/ssh/sshd_config
    mkdir -p /mnt/root/root/.ssh && chmod 700 /mnt/root/root/.ssh
    if [ -f /work/id_rsa.pub ]; then cp /work/id_rsa.pub /mnt/root/root/.ssh/authorized_keys; fi
    [ -f /mnt/root/root/.ssh/authorized_keys ] && chmod 600 /mnt/root/root/.ssh/authorized_keys

    sync
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
    echo 'Done.'
"

log "${GREEN}--- SUCCESS: WiFi & Keyboard Patched Image Ready ---${NC}"
