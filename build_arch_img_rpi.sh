#!/bin/bash

set -e

# --- CONFIGURATION ---
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="PT"

# Static Network Details
STATIC_IP="192.168.1.150/24"
GATEWAY="192.168.1.1"
HOSTNAME="kube-master-01"

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

log_header "RPI 5 MASTER: KUBE-MASTER-01 CONFIG"

log_step "Creating 4GB optimized image..."
truncate -s 4G "$RPI5_IMG"

log_step "Launching Docker context..."

docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" \
    -e WIFI_PASS="$WIFI_PASS" \
    -e REG_DOMAIN="$REG_DOMAIN" \
    -e STATIC_IP="$STATIC_IP" \
    -e GATEWAY="$GATEWAY" \
    -e HOSTNAME="$HOSTNAME" \
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
    apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod rsync dosfstools e2fsprogs parted > /dev/null

    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    losetup -D
    
    task 'Preparing Partition Table...'
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
    
    LOOP_NEW=\$(losetup -f)
    losetup \"\$LOOP_NEW\" \"\$RPI5_IMG\"
    kpartx -as \"\$LOOP_NEW\"
    LNAME=\$(basename \$LOOP_NEW)
    MAP_BOOT=\"/dev/mapper/\${LNAME}p1\"
    MAP_ROOT=\"/dev/mapper/\${LNAME}p2\"

    task 'Formatting and Migrating Data...'
    mkfs.vfat -F32 \"\$MAP_BOOT\" > /dev/null
    mkfs.ext4 -F \"\$MAP_ROOT\" > /dev/null
    
    mkdir -p /mnt/base_root /mnt/new_root
    LOOP_BASE=\$(losetup -f)
    losetup \"\$LOOP_BASE\" \"\$BASE_IMG\"
    kpartx -as \"\$LOOP_BASE\"
    LBASE_NAME=\$(basename \$LOOP_BASE)
    mount \"/dev/mapper/\${LBASE_NAME}p2\" /mnt/base_root
    mount \"\$MAP_ROOT\" /mnt/new_root
    mkdir -p /mnt/new_root/boot && mount \"\$MAP_BOOT\" /mnt/new_root/boot
    rsync -aAX /mnt/base_root/ /mnt/new_root/

    # --- THE FIXED AUTO-EXPAND SCRIPT ---
    task 'Injecting Fixed Auto-Expand Logic...'
    cat <<'EOF_SH' > /mnt/new_root/usr/local/bin/rpi-expand-root.sh
#!/bin/bash
sleep 5
ROOT_DEV=\$(findmnt / -o SOURCE -n)
# Fixed Disk Identification for mmcblk0
DISK_DEV=\$(echo \$ROOT_DEV | sed 's/p[0-9]\$//')
PART_NUM=\$(echo \$ROOT_DEV | grep -o '[0-9]\$')

echo -e \"d\n\$PART_NUM\nn\np\n\$PART_NUM\n\n\ny\nw\" | fdisk \$DISK_DEV
partx -u \$DISK_DEV || true
resize2fs \$ROOT_DEV

systemctl disable rpi-expand-root.service
rm /etc/systemd/system/rpi-expand-root.service
rm /usr/local/bin/rpi-expand-root.sh
EOF_SH
    chmod +x /mnt/new_root/usr/local/bin/rpi-expand-root.sh

    cat <<EOF > /mnt/new_root/etc/systemd/system/rpi-expand-root.service
[Unit]
Description=Expand root partition
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpi-expand-root.sh
[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/rpi-expand-root.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/rpi-expand-root.service

    # --- NETWORK: HOSTNAME & STATIC IP & IPv6 DISABLE ---
    task 'Configuring Hostname and Networking...'
    echo \"\$HOSTNAME\" > /mnt/new_root/etc/hostname
    
    # Static IPv4 Configuration
    cat <<EOF > /mnt/new_root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0

[Network]
Address=\$STATIC_IP
Gateway=\$GATEWAY
DNS=\$GATEWAY
DNS=8.8.8.8
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF

    # --- KERNEL & 5GHz WiFi FIX ---
    task 'Patching Hardware Drivers...'
    K_RAW=\$(curl -sL \$MIRROR_CORE/)
    F_RAW=\$(curl -sL \$MIRROR_ALARM/)
    KERNEL_PKG=\$(echo \"\$K_RAW\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | grep -v '16k' | sort -V | tail -n 1)
    FIRM_RPI=\$(echo \"\$F_RAW\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    BOOT_PKG=\$(echo \"\$F_RAW\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)

    [ ! -f \"\$KERNEL_PKG\" ] && wget -q \"\$MIRROR_CORE/\$KERNEL_PKG\"
    [ ! -f \"\$FIRM_RPI\" ] && wget -q \"\$MIRROR_ALARM/\$FIRM_RPI\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q \"\$MIRROR_ALARM/\$BOOT_PKG\"

    rm -rf /mnt/new_root/usr/lib/modules/* /mnt/new_root/boot/*
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/new_root
    tar -xpf \"\$FIRM_RPI\" -C /mnt/new_root
    tar -xpf \"\$BOOT_PKG\" -C /mnt/new_root
    [ -d /mnt/new_root/boot/boot ] && mv /mnt/new_root/boot/boot/* /mnt/new_root/boot/ && rmdir /mnt/new_root/boot/boot
    depmod -b /mnt/new_root \$(ls /mnt/new_root/usr/lib/modules | head -n 1)

    # WiFi Handshake (5GHz Optimization)
    printf \"ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\ncountry=\$REG_DOMAIN\n\nnetwork={\n    ssid=\\\"\$WIFI_SSID\\\"\n    psk=\\\"\$WIFI_PASS\\\"\n    scan_ssid=1\n    key_mgmt=WPA-PSK\n    proto=RSN\n}\n\" > /mnt/new_root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
    
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/sshd.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/sshd.service

    sed -i 's/^root:[^:]*:/root::/' /mnt/new_root/etc/shadow
    
    # BOOT: ipv6.disable=1 is critical for Kubernetes stability
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=bcm2712-rpi-5-b.dtb\nusb_max_current_enable=1\" > /mnt/new_root/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0 ipv6.disable=1\" > /mnt/new_root/boot/cmdline.txt

    sync
    umount -R /mnt/base_root /mnt/new_root
    kpartx -d \"\$LOOP_BASE\" && kpartx -d \"\$LOOP_NEW\"
    losetup -D
    succ 'Master Image Configured.'
"

log_header "SUCCESS"
echo -e "Hostname: ${B_GREEN}$HOSTNAME${NC}"
echo -e "IPv4:     ${B_GREEN}192.168.1.150 (IPv6 Disabled)${NC}"
echo -e "Flash:    ${B_CYAN}sudo dd if=$RPI5_IMG of=/dev/disk4 bs=4M status=progress${NC}"
