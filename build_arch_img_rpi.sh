#!/bin/bash

# Stop script on any error
set -e

# --- CONFIGURATION (Customize per node) ---
HOSTNAME="kube-worker-01"         
PI_VERSION="4"                    # 4 for Worker, 5 for Master
STATIC_IP="192.168.1.160/24"      
GATEWAY="192.168.1.1"
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="PT"

# --- SYSTEM PATHS ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
TARGET_IMG="${HOSTNAME}.img"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"

# Colors for "Beautiful" Logging
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

# =========================================================
# PHASE 1: IDEMPOTENT BASE IMAGE GENERATION (10GB)
# =========================================================
log_header "PHASE 1: BASE IMAGE ARCHITECTURE"

if [ ! -f "$ARCH_TARBALL" ]; then
    log_step "Downloading Arch Linux ARM Tarball..."
    wget -c "http://os.archlinuxarm.org/os/$ARCH_TARBALL"
else
    echo -e "       ${B_GREEN}✔${NC} Tarball exists."
fi

if [ ! -f "$BASE_IMG" ]; then
    log_step "Building Clean Base Image (10GB)..."
    truncate -s 10G "$BASE_IMG"
    docker run --rm --privileged -v "$WORKSPACE":/work ubuntu:22.04 bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq > /dev/null
        apt-get install -y -qq apt-utils > /dev/null 2>&1
        apt-get install -y -qq fdisk e2fsprogs dosfstools libarchive-tools kpartx kmod > /dev/null 2>&1
        
        cd /work
        # FORCE create loop nodes if they don't exist
        for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
        
        # Partitioning
        wipefs -af $BASE_IMG > /dev/null 2>&1
        printf 'o\nn\np\n1\n\n+2G\nt\nc\nn\np\n2\n\n\nw\n' | fdisk $BASE_IMG > /dev/null 2>&1
        
        # Robust Mapping
        LOOP_DEV=\$(losetup -f --show $BASE_IMG)
        kpartx -as \"\$LOOP_DEV\"
        LNAME=\$(basename \"\$LOOP_DEV\")
        BOOT_DEV=\"/dev/mapper/\${LNAME}p1\"
        ROOT_DEV=\"/dev/mapper/\${LNAME}p2\"
        
        mkfs.vfat -n BOOT \"\$BOOT_DEV\" > /dev/null 2>&1
        mkfs.ext4 -Fq -L ROOT \"\$ROOT_DEV\" > /dev/null 2>&1
        
        mkdir -p /mnt/root && mount \"\$ROOT_DEV\" /mnt/root
        mkdir -p /mnt/root/boot && mount \"\$BOOT_DEV\" /mnt/root/boot
        
        bsdtar -xpf $ARCH_TARBALL -C /mnt/root
        
        sync
        umount -R /mnt/root
        kpartx -d \"\$LOOP_DEV\"
        losetup -d \"\$LOOP_DEV\"
    "
    echo -e "       ${B_GREEN}✔${NC} Base Image created."
else
    echo -e "       ${B_GREEN}✔${NC} Base Image found."
fi

# =========================================================
# PHASE 2: HARDWARE-SPECIFIC CUSTOMIZATION
# =========================================================
log_header "PHASE 2: CUSTOMIZING FOR $HOSTNAME (RPI $PI_VERSION)"

log_step "Cloning base image to target..."
cp "$BASE_IMG" "$TARGET_IMG"

log_step "Launching Docker Context for Hardware Surgery..."

docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" \
    -e WIFI_PASS="$WIFI_PASS" \
    -e REG_DOMAIN="$REG_DOMAIN" \
    -e STATIC_IP="$STATIC_IP" \
    -e GATEWAY="$GATEWAY" \
    -e HOSTNAME="$HOSTNAME" \
    -e TARGET_IMG="$TARGET_IMG" \
    -e PI_VERSION="$PI_VERSION" \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    task() { echo -ne \"\033[1;35m  [TASK]\033[0m \$1... \"; }
    succ() { echo -e \"\033[1;32m✔ DONE\033[0m\"; }

    apt-get update -qq > /dev/null
    apt-get install -y -qq apt-utils > /dev/null 2>&1
    apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod rsync dosfstools e2fsprogs parted > /dev/null 2>&1

    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    
    task 'Mapping target and Cleaning Boot'
    LOOP_DEV=\$(losetup -f --show \"\$TARGET_IMG\")
    kpartx -as \"\$LOOP_DEV\"
    LNAME=\$(basename \"\$LOOP_DEV\")
    MAP_BOOT=\"/dev/mapper/\${LNAME}p1\"
    MAP_ROOT=\"/dev/mapper/\${LNAME}p2\"
    
    mkdir -p /mnt/target_root && mount \"\$MAP_ROOT\" /mnt/target_root
    mkdir -p /mnt/target_root/boot && mount \"\$MAP_BOOT\" /mnt/target_root/boot
    rm -rf /mnt/target_root/boot/*
    succ

    task 'Injecting 128GB Auto-Expand & Power-Save Kill'
    cat <<'EOF_SH' > /mnt/target_root/usr/local/bin/rpi-expand-root.sh
#!/bin/bash
iw dev wlan0 set power_save off || true
sleep 5
ROOT_DEV=\$(findmnt / -o SOURCE -n)
DISK_DEV=\${ROOT_DEV%p*}
PART_NUM=\$(echo \$ROOT_DEV | grep -o '[0-9]\$')
echo -e \"d\n\$PART_NUM\nn\np\n\$PART_NUM\n\n\ny\nw\" | fdisk \$DISK_DEV > /dev/null 2>&1
partx -u \$DISK_DEV || true
resize2fs \$ROOT_DEV > /dev/null 2>&1
systemctl disable rpi-expand-root.service
rm /etc/systemd/system/rpi-expand-root.service
EOF_SH
    chmod +x /mnt/target_root/usr/local/bin/rpi-expand-root.sh
    cat <<EOF > /mnt/target_root/etc/systemd/system/rpi-expand-root.service
[Unit]
Description=Stabilize WiFi and Expand Root
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpi-expand-root.sh
[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/rpi-expand-root.service /mnt/target_root/etc/systemd/system/multi-user.target.wants/rpi-expand-root.service
    succ

    task \"Patching Kernel for RPi \$PI_VERSION (4k check)\"
    K_MIRROR=\"http://fl.us.mirror.archlinuxarm.org/aarch64\"
    K_RAW=\$(curl -sL \$K_MIRROR/core/)
    F_RAW=\$(curl -sL \$K_MIRROR/alarm/)
    
    if [ \"\$PI_VERSION\" == \"4\" ]; then
        KERNEL_PKG=\$(echo \"\$K_RAW\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v '16k' | grep -v 'headers' | sort -V | tail -n 1)
        DTB_FILE=\"bcm2711-rpi-4-b.dtb\"
    else
        KERNEL_PKG=\$(echo \"\$K_RAW\" | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
        DTB_FILE=\"bcm2712-rpi-5-b.dtb\"
    fi
    FIRM_RPI=\$(echo \"\$F_RAW\" | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    BOOT_PKG=\$(echo \"\$F_RAW\" | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
    REGDB_PKG=\$(echo \"\$K_RAW\" | grep -oE 'wireless-regdb-[^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)

    wget -q \"\$K_MIRROR/core/\$KERNEL_PKG\" \"\$K_MIRROR/alarm/\$FIRM_RPI\" \"\$K_MIRROR/alarm/\$BOOT_PKG\" \"\$K_MIRROR/core/\$REGDB_PKG\"
    
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/target_root
    tar -xpf \"\$FIRM_RPI\" -C /mnt/target_root
    tar -xpf \"\$BOOT_PKG\" -C /mnt/target_root
    tar -xpf \"\$REGDB_PKG\" -C /mnt/target_root
    
    [ -d /mnt/target_root/boot/boot ] && mv /mnt/target_root/boot/boot/* /mnt/target_root/boot/ && rmdir /mnt/target_root/boot/boot
    depmod -b /mnt/target_root \$(ls /mnt/target_root/usr/lib/modules | head -n 1)
    succ

    task 'Enforcing 5GHz & Hostname'
    echo \"\$HOSTNAME\" > /mnt/target_root/etc/hostname
    cat <<EOF > /mnt/target_root/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
Address=\$STATIC_IP
Gateway=\$GATEWAY
DNS=1.1.1.1
IPv6AcceptRA=no
EOF
    mkdir -p /mnt/target_root/etc/modprobe.d
    echo \"options brcmfmac roamoff=1 feature_disable=0x82000 ccode=\$REG_DOMAIN\" > /mnt/target_root/etc/modprobe.d/brcmfmac.conf
    echo \"options cfg80211 regdomain=\$REG_DOMAIN\" >> /mnt/target_root/etc/modprobe.d/brcmfmac.conf
    printf \"country=\$REG_DOMAIN\nctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\np2p_disabled=1\n\nnetwork={\n    ssid=\\\"\$WIFI_SSID\\\"\n    psk=\\\"\$WIFI_PASS\\\"\n    key_mgmt=WPA-PSK\n    ieee80211w=1\n}\n\" > /mnt/target_root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
    
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/target_root/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/target_root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    sed -i 's/^root:[^:]*:/root::/' /mnt/target_root/etc/shadow
    succ

    task 'Finalizing Boot Config'
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB_FILE\nenable_uart=1\nusb_max_current_enable=1\" > /mnt/target_root/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0 ipv6.disable=1 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 cfg80211.regdom=\$REG_DOMAIN\" > /mnt/target_root/boot/cmdline.txt
    succ

    task 'Finalizing Target Image'
    sync && umount -R /mnt/target_root && kpartx -d \"\$LOOP_DEV\" > /dev/null 2>&1 && losetup -d \"\$LOOP_DEV\"
    succ
"

log_header "SUCCESS: READY TO FLASH"
echo -e "Hostname: ${B_GREEN}$HOSTNAME${NC} (RPi $PI_VERSION)"
echo -e "Flash:    ${B_CYAN}sudo dd if=$TARGET_IMG of=/dev/diskX bs=4M status=progress${NC}"
log_header "========================================"
