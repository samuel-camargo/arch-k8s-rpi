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

# Beautiful Log Colors
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

log_header "RPI 5 MASTER: FINAL HANDSHAKE FIX (REASON 15)"

log_step "Creating build image..."
truncate -s 7G "$RPI5_IMG"

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
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    task() { echo -ne \"\033[1;35m  [TASK]\033[0m \$1... \"; }
    succ() { echo -e \"\033[1;32m✔ DONE\033[0m\"; }

    apt-get update -qq > /dev/null
    apt-get install -y -qq apt-utils > /dev/null 2>&1
    apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod rsync dosfstools e2fsprogs parted > /dev/null

    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    losetup -D
    
    task 'Repartitioning and Formatting'
    wipefs -af \"\$RPI5_IMG\" > /dev/null 2>&1
    fdisk \"\$RPI5_IMG\" <<EOF > /dev/null 2>&1
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
    mkfs.vfat -F32 \"\$MAP_BOOT\" > /dev/null 2>&1
    mkfs.ext4 -Fq \"\$MAP_ROOT\" > /dev/null 2>&1
    succ

    task 'Migrating System Data'
    mkdir -p /mnt/base_root /mnt/new_root
    LOOP_BASE=\$(losetup -f)
    losetup \"\$LOOP_BASE\" \"\$BASE_IMG\"
    kpartx -as \"\$LOOP_BASE\"
    mount \"/dev/mapper/\$(basename \$LOOP_BASE)p2\" /mnt/base_root
    mount \"\$MAP_ROOT\" /mnt/new_root
    mkdir -p /mnt/new_root/boot && mount \"\$MAP_BOOT\" /mnt/new_root/boot
    rsync -aAX /mnt/base_root/ /mnt/new_root/
    succ

    task 'Injecting FIXED Auto-Expand & Power-Save Disable'
    cat <<'EOF_SH' > /mnt/new_root/usr/local/bin/rpi-expand-root.sh
#!/bin/bash
# 1. Disable WiFi Power Management immediately (Fixes Reason 15)
iw dev wlan0 set power_save off || true
sleep 5
ROOT_DEV=\$(findmnt / -o SOURCE -n)
DISK_DEV=\$(echo \$ROOT_DEV | sed 's/p[0-9]\$//')
PART_NUM=\$(echo \$ROOT_DEV | grep -o '[0-9]\$')
echo -e \"d\n\$PART_NUM\nn\np\n\$PART_NUM\n\n\ny\nw\" | fdisk \$DISK_DEV > /dev/null 2>&1
partx -u \$DISK_DEV || true
resize2fs \$ROOT_DEV > /dev/null 2>&1
systemctl disable rpi-expand-root.service
rm /etc/systemd/system/rpi-expand-root.service
EOF_SH
    chmod +x /mnt/new_root/usr/local/bin/rpi-expand-root.sh
    cat <<EOF > /mnt/new_root/etc/systemd/system/rpi-expand-root.service
[Unit]
Description=Expand root and disable power save
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpi-expand-root.sh
[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/rpi-expand-root.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/rpi-expand-root.service
    succ

    task 'Configuring K8s Network and Hostname'
    echo \"\$HOSTNAME\" > /mnt/new_root/etc/hostname
    cat <<EOF > /mnt/new_root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
Address=\$STATIC_IP
Gateway=\$GATEWAY
DNS=1.1.1.1
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
    mkdir -p /mnt/new_root/etc/modules-load.d /mnt/new_root/etc/sysctl.d
    echo -e \"overlay\nbr_netfilter\" > /mnt/new_root/etc/modules-load.d/k8s.conf
    echo -e \"net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\" > /mnt/new_root/etc/sysctl.d/k8s.conf
    succ

    task 'Hardening Driver Modules (PT Region)'
    mkdir -p /mnt/new_root/etc/modprobe.d
    # roamoff=1 prevents the driver from jumping channels during handshake
    echo \"options brcmfmac roamoff=1 feature_disable=0x82000\" > /mnt/new_root/etc/modprobe.d/brcmfmac.conf
    succ

    task 'Injecting RPi 5 Kernel and regdb'
    K_RAW=\$(curl -sL http://fl.us.mirror.archlinuxarm.org/aarch64/core/)
    F_RAW=\$(curl -sL http://fl.us.mirror.archlinuxarm.org/aarch64/alarm/)
    KERNEL_PKG=\$(echo \"\$K_RAW\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    FIRM_RPI=\$(echo \"\$F_RAW\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    BOOT_PKG=\$(echo \"\$F_RAW\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    REGDB_PKG=\$(echo \"\$K_RAW\" | grep -oE 'wireless-regdb-[^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)

    [ ! -f \"\$KERNEL_PKG\" ] && wget -q \"http://fl.us.mirror.archlinuxarm.org/aarch64/core/\$KERNEL_PKG\"
    [ ! -f \"\$FIRM_RPI\" ] && wget -q \"http://fl.us.mirror.archlinuxarm.org/aarch64/alarm/\$FIRM_RPI\"
    [ ! -f \"\$BOOT_PKG\" ] && wget -q \"http://fl.us.mirror.archlinuxarm.org/aarch64/alarm/\$BOOT_PKG\"
    [ ! -f \"\$REGDB_PKG\" ] && wget -q \"http://fl.us.mirror.archlinuxarm.org/aarch64/core/\$REGDB_PKG\"

    tar -xpf \"\$KERNEL_PKG\" -C /mnt/new_root
    tar -xpf \"\$FIRM_RPI\" -C /mnt/new_root
    tar -xpf \"\$BOOT_PKG\" -C /mnt/new_root
    tar -xpf \"\$REGDB_PKG\" -C /mnt/new_root
    [ -d /mnt/new_root/boot/boot ] && mv /mnt/new_root/boot/boot/* /mnt/new_root/boot/ && rmdir /mnt/new_root/boot/boot
    depmod -b /mnt/new_root \$(ls /mnt/new_root/usr/lib/modules | head -n 1)
    succ

    task 'Finalizing WPA Handshake Stability'
    # p2p_disabled=1 prevents background scanning interference
    printf \"country=\$REG_DOMAIN\nctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\np2p_disabled=1\n\nnetwork={\n    ssid=\\\"\$WIFI_SSID\\\"\n    psk=\\\"\$WIFI_PASS\\\"\n    key_mgmt=WPA-PSK\n    ieee80211w=1\n}\n\" > /mnt/new_root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
    
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/new_root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    
    sed -i 's/^root:[^:]*:/root::/' /mnt/new_root/etc/shadow
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=bcm2712-rpi-5-b.dtb\nusb_max_current_enable=1\" > /mnt/new_root/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0 ipv6.disable=1 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 cfg80211.regdom=\$REG_DOMAIN\" > /mnt/new_root/boot/cmdline.txt
    succ

    sync
    umount -R /mnt/base_root /mnt/new_root > /dev/null 2>&1
    kpartx -d \"\$LOOP_BASE\" > /dev/null 2>&1 && kpartx -d \"\$LOOP_NEW\" > /dev/null 2>&1
    losetup -D
"

log_header "SUCCESS: READY TO FLASH"
echo -e "Hostname: ${B_GREEN}$HOSTNAME${NC}"
echo -e "IPv4:     ${B_GREEN}192.168.1.150${NC}"
echo -e "Flash:    ${B_CYAN}sudo dd if=$RPI5_IMG of=/dev/disk4 bs=4M status=progress${NC}"
log_header "========================================"
