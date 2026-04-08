#!/bin/bash

set -e

# --- CONFIGURATION (CRITICAL: FILL YOUR WIFI) ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
RPI5_IMG="rpi5_master.img"

# Mirror for Arch base packages
MIRROR_CORE="http://fl.us.mirror.archlinuxarm.org/aarch64/core"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log "Step 1: Preparing Clean Image"
cp "$BASE_IMG" "$RPI5_IMG"

log "Step 2: Launching Docker for Hardware-Level Injection"
docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    echo 'Installing system dependencies...'
    apt-get update -qq && apt-get install -y -qq kpartx wget zstd xz-utils fdisk curl git kmod > /dev/null

    cd /work
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod /dev/loop\$i b 7 \$i || true; done

    echo 'Downloading official RPi Stable Kernel/Firmware (This is the guarantee)...'
    # We download only the necessary blobs from the official repo
    mkdir -p rpi-firmware
    wget -q https://github.com/raspberrypi/firmware/raw/master/boot/kernel8.img -O rpi-firmware/kernel8.img
    wget -q https://github.com/raspberrypi/firmware/raw/master/boot/bcm2712-rpi-5-b.dtb -O rpi-firmware/bcm2712-rpi-5-b.dtb
    
    # Download the essential bootloader files
    for f in fixup.dat start.elf fixup4.dat start4.elf fixup8.dat start8.elf; do
        wget -q https://github.com/raspberrypi/firmware/raw/master/boot/\$f -O rpi-firmware/\$f
    done

    echo 'Mapping image partitions...'
    kpartx -d $RPI5_IMG || true
    KOUT=\$(kpartx -asv $RPI5_IMG)
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/root
    mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot
    mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot

    echo 'Wiping unstable boot files...'
    rm -rf /mnt/root/boot/*

    echo 'Injecting Stable Kernel and Device Tree...'
    cp rpi-firmware/* /mnt/root/boot/
    # Official kernel expects to be named kernel8.img or Image
    cp rpi-firmware/kernel8.img /mnt/root/boot/Image

    echo 'Injecting WiFi Configuration...'
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
Name=wlan0
[Network]
DHCP=yes
EOF
    # Force services to be enabled
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service

    echo 'Configuring Ultimate Compatibility Boot Files...'
    # Use config.txt settings that force the keyboard and USB alive
    cat <<EOF > /mnt/root/boot/config.txt
arm_64bit=1
# Force 4k page size compatibility
kernel=Image
device_tree=bcm2712-rpi-5-b.dtb
usb_max_current_enable=1
# Force USB controller to stay awake
dtparam=pcie_aspm=off
EOF

    # cmdline.txt: We use 'rw' early and force the terminal to tty1
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0\" > /mnt/root/boot/cmdline.txt

    echo 'Allowing Root login without password (FOR RECOVERY)...'
    # This ensures that even if typing works but login fails, you get in
    sed -i 's/root:\*:/root::/' /mnt/root/etc/shadow
    sed -i 's/#PermitEmptyPasswords no/PermitEmptyPasswords yes/' /mnt/root/etc/ssh/sshd_config
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /mnt/root/etc/ssh/sshd_config

    sync
    umount -R /mnt/root
    kpartx -d $RPI5_IMG
    echo 'Done.'
"

log "${GREEN}--- SUCCESS: Stable Transplant Image Ready ---${NC}"
