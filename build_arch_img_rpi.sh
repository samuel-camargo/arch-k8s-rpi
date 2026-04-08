#!/bin/bash

set -e

# --- CONFIGURATION ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="NL"  # Set to NL based on your current location (Amsterdam)

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
B_WHITE='\033[1;37m'
NC='\033[0m' 

# Outside-Docker Logging Helpers
log_header() { echo -e "\n${B_MAGENTA}==================== $1 ====================${NC}"; }
log_step()   { echo -e "${B_CYAN}[🚀 STEP]${NC} $1"; }
log_error()  { echo -e "${B_RED}[❌ ERROR]${NC} $1"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log_header "RPI 5 ARCH LINUX MASTER PATCHER"

log_step "Cloning base image to Master destination..."
if [ ! -f "$BASE_IMG" ]; then
    log_error "Base image $BASE_IMG not found. Run base build script first."
    exit 1
fi
cp "$BASE_IMG" "$RPI5_IMG"
echo -e "       Check: ${B_GREEN}✔${NC} $RPI5_IMG initialized."

log_step "Starting hardware injection via Docker container..."

docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    # Internal Docker Logging Helpers
    info() { echo -e \"\033[1;36m  [INFO]\033[0m \$1\"; }
    task() { echo -e \"\033[1;35m  [TASK]\033[0m \$1\"; }
    pkg()  { echo -e \"         📦 \033[1;32m\$1\033[0m: \$2\"; }
    succ() { echo -e \"         \033[1;32m✔\033[0m \$1\"; }

    task 'Installing necessary build tools inside container...'
    apt-get update -qq && apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod > /dev/null
    succ 'Dependencies installed.'

    task 'Provisioning virtual loop device nodes...'
    for i in {0..15}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    succ 'Loop nodes 0-15 ready.'

    task 'Querying mirror for latest stable hardware packages...'
    KERNEL_PKG=\$(curl -sL $MIRROR_CORE/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    FIRM_RPI=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    BOOT_PKG=\$(curl -sL $MIRROR_ALARM/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    pkg 'Kernel   ' \"\$KERNEL_PKG\"
    pkg 'Firmware ' \"\$FIRM_RPI\"
    pkg 'Boot     ' \"\$BOOT_PKG\"

    task 'Ensuring packages are local...'
    [ ! -f \"\$KERNEL_PKG\" ] && wget -q --show-progress \"$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$FIRM_RPI\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$FIRM_RPI\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q --show-progress \"$MIRROR_ALARM/\$BOOT_PKG\"

    task 'Mapping disk image partitions...'
    losetup -D
    LOOP_DEV=\$(losetup -f)
    losetup \"\$LOOP_DEV\" $RPI5_IMG
    KOUT=\$(kpartx -asv \"\$LOOP_DEV\")
    BOOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p1 ' | awk '{print \$3}')
    ROOT_MAPPER=\$(echo \"\$KOUT\" | grep 'p2 ' | awk '{print \$3}')
    
    mkdir -p /mnt/root && mount \"/dev/mapper/\$ROOT_MAPPER\" /mnt/root
    mkdir -p /mnt/root/boot && mount \"/dev/mapper/\$BOOT_MAPPER\" /mnt/root/boot
    succ \"Mounted via \$LOOP_DEV\"

    task 'Wiping generic drivers and syncing hardware-specific files...'
    rm -rf /mnt/root/usr/lib/modules/* /mnt/root/boot/*
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$FIRM_RPI\" -C /mnt/root --exclude='.PKGINFO'
    tar -xpf \"\$BOOT_PKG\" -C /mnt/root --exclude='.PKGINFO'
    [ -d /mnt/root/boot/boot ] && mv /mnt/root/boot/boot/* /mnt/root/boot/ && rmdir /mnt/root/boot/boot
    succ 'File injection complete.'

    task 'Building module dependency map (Keyboard/WiFi fix)...'
    KVER=\$(ls /mnt/root/usr/lib/modules | head -n 1)
    depmod -b /mnt/root \$KVER
    info \"Injected module tree for version: \$KVER\"

    task 'Configuring WiFi with Regulatory Domain: $REG_DOMAIN'
    mkdir -p /mnt/root/etc/conf.d /mnt/root/etc/wpa_supplicant /mnt/root/etc/systemd/network
    echo \"WIRELESS_REGDOM='$REG_DOMAIN'\" > /mnt/root/etc/conf.d/wireless-regdom
    cat <<EOF > /mnt/root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
country=$REG_DOMAIN
network={
    ssid=\\\"$WIFI_SSID\\\"
    psk=\\\"$WIFI_PASS\\\"
}
EOF
    cat <<EOF > /mnt/root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan*
[Network]
DHCP=yes
EOF
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    succ 'WiFi 📡 configured and wlan0 naming forced.'

    task 'Managing security credentials...'
    # Use explicit root removal to fix the password loop
    sed -i 's/^root:[^:]*:/root::/' /mnt/root/etc/shadow
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service
    succ 'Root password cleared 🔑 and SSH enabled.'

    task 'Applying final boot optimization for RPi 5...'
    echo 'arm_64bit=1' > /mnt/root/boot/config.txt
    echo 'kernel=Image' >> /mnt/root/boot/config.txt
    echo 'device_tree=bcm2712-rpi-5-b.dtb' >> /mnt/root/boot/config.txt
    echo 'usb_max_current_enable=1' >> /mnt/root/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0\" > /mnt/root/boot/cmdline.txt
    succ 'Boot parameters written.'

    task 'Finalizing disk and sync...'
    sync
    umount -R /mnt/root
    kpartx -d \"\$LOOP_DEV\"
    losetup -d \"\$LOOP_DEV\"
    succ 'Cleanup complete.'
"

log_header "SUCCESS"
echo -e "${B_GREEN}The RPi 5 Master Image is ready for deployment.${NC}"
echo -e "${B_WHITE}Next Steps:${NC}"
echo -e "  1. Flash: ${B_CYAN}sudo dd if=$RPI5_IMG of=/dev/rdiskX bs=4M status=progress${NC}"
echo -e "  2. Boot: Pi 5 will connect to ${B_YELLOW}$WIFI_SSID${NC} automatically."
echo -e "  3. Login: Username ${B_GREEN}root${NC}, press ${B_GREEN}ENTER${NC} at password prompt."
echo -e "${B_MAGENTA}============================================${NC}"
