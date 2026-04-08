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

log_header "RPI 5 MASTER: FAST-FLASH (4GB) + AUTO-EXPAND"

log_step "Creating 4GB optimized image..."
truncate -s 4G "$RPI5_IMG"

log_step "Launching Docker for Hardware Injection & Auto-Expand Logic..."

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

    apt-get update -qq > /dev/null
    apt-get install -y -qq apt-utils > /dev/null 2>&1
    apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod rsync dosfstools e2fsprogs > /dev/null

    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    losetup -D
    
    # --- PARTITIONING ---
    task 'Wiping old signatures and Partitioning...'
    # wipefs prevents fdisk from asking 'Remove signature? Y/N'
    wipefs -a \"\$RPI5_IMG\"
    
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
    succ 'Partition table written.'

    task 'Mapping loop devices...'
    LOOP_NEW=\$(losetup -f)
    losetup \"\$LOOP_NEW\" \"\$RPI5_IMG\"
    kpartx -as \"\$LOOP_NEW\"
    
    # Robustly identify the mapper paths
    LNAME=\$(basename \$LOOP_NEW)
    MAP_BOOT=\"/dev/mapper/\${LNAME}p1\"
    MAP_ROOT=\"/dev/mapper/\${LNAME}p2\"

    task 'Formatting partitions...'
    mkfs.vfat -F32 \"\$MAP_BOOT\" > /dev/null
    mkfs.ext4 -F \"\$MAP_ROOT\" > /dev/null
    succ 'Formatting complete.'

    task 'Migrating System Data...'
    mkdir -p /mnt/base_root /mnt/new_root
    LOOP_BASE=\$(losetup -f)
    losetup \"\$LOOP_BASE\" \"\$BASE_IMG\"
    kpartx -as \"\$LOOP_BASE\"
    LBASE_NAME=\$(basename \$LOOP_BASE)
    MAP_BASE_ROOT=\"/dev/mapper/\${LBASE_NAME}p2\"
    
    mount \"\$MAP_BASE_ROOT\" /mnt/base_root
    mount \"\$MAP_ROOT\" /mnt/new_root
    mkdir -p /mnt/new_root/boot
    mount \"\$MAP_BOOT\" /mnt/new_root/boot
    rsync -aAX /mnt/base_root/ /mnt/new_root/
    succ 'System migration complete.'

    # --- AUTO-EXPAND SCRIPT ---
    task 'Injecting Auto-Expand Service...'
    cat <<'EOF_SH' > /mnt/new_root/usr/local/bin/rpi-expand-root.sh
#!/bin/bash
# Wait for the system to settle
sleep 5
ROOT_DEV=\$(findmnt / -o SOURCE -n)
PART_NUM=\$(echo \$ROOT_DEV | grep -o '[0-9]\$')
DISK_DEV=\$(echo \$ROOT_DEV | sed 's/[0-9]\$//')

# Expand partition 2 to fill disk (y answers the signature prompt if it appears)
echo -e \"d\n\$PART_NUM\nn\np\n\$PART_NUM\n\n\ny\nw\" | fdisk \$DISK_DEV
partprobe \$DISK_DEV
resize2fs \$ROOT_DEV

# Self-destruct
systemctl disable rpi-expand-root.service
rm /etc/systemd/system/rpi-expand-root.service
rm /usr/local/bin/rpi-expand-root.sh
EOF_SH
    chmod +x /mnt/new_root/usr/local/bin/rpi-expand-root.sh

    cat <<EOF > /mnt/new_root/etc/systemd/system/rpi-expand-root.service
[Unit]
Description=Expand root partition to fill SD card
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpi-expand-root.sh
[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/rpi-expand-root.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/rpi-expand-root.service

    # --- KERNEL & 5GHz WiFi FIX ---
    task 'Applying Kernel & 5GHz (PT) WiFi Patches...'
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
    depmod -b /mnt/new_root \$(ls /mnt/new_root/usr/lib/modules | head -n 1)

    # 5GHz Precise Config (Forces WPA2/AES and PT region)
    printf \"ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\ncountry=\$REG_DOMAIN\n\nnetwork={\n    ssid=\\\"\$WIFI_SSID\\\"\n    psk=\\\"\$WIFI_PASS\\\"\n    scan_ssid=1\n    key_mgmt=WPA-PSK\n    proto=RSN\n}\n\" > /mnt/new_root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
    
    sed -i 's/^root:[^:]*:/root::/' /mnt/new_root/etc/shadow
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=bcm2712-rpi-5-b.dtb\nusb_max_current_enable=1\" > /mnt/new_root/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0\" > /mnt/new_root/boot/cmdline.txt

    sync
    umount -R /mnt/base_root || true
    umount -R /mnt/new_root || true
    kpartx -d \"\$LOOP_BASE\"
    kpartx -d \"\$LOOP_NEW\"
    losetup -D
    succ 'Image Ready.'
"

log_header "SUCCESS"
echo -e "1. ${B_WHITE}Unmount:${NC} ${B_YELLOW}diskutil unmountDisk /dev/disk4${NC}"
echo -e "2. ${B_WHITE}Flash:${NC}   ${B_CYAN}sudo dd if=$RPI5_IMG of=/dev/disk4 bs=4M status=progress${NC}"
log_header "========================================"
