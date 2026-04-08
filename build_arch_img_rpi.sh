#!/bin/bash

# Stop script on any error
set -e

# --- CONFIGURATION ---
HOSTNAME="kube-worker-01"         
PI_VERSION="4"                    
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

# Colors
B_MAGENTA='\033[1;35m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
NC='\033[0m' 

log_header() { echo -e "\n${B_MAGENTA}==================== $1 ====================${NC}"; }
log_step()   { echo -e "${B_CYAN}[🚀 STEP]${NC} $1"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# PHASE 1: IDEMPOTENT BASE (10GB) - Kept same as v13
if [ ! -f "$BASE_IMG" ]; then
    log_header "PHASE 1: BUILDING 10GB BASE"
    # ... (Base image build logic from v13 remains the same) ...
    truncate -s 10G "$BASE_IMG"
    docker run --rm --privileged -v "$WORKSPACE":/work ubuntu:22.04 bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq > /dev/null && apt-get install -y -qq fdisk e2fsprogs dosfstools libarchive-tools kpartx kmod > /dev/null 2>&1
        cd /work
        for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
        printf 'o\nn\np\n1\n\n+2G\nt\nc\nn\np\n2\n\n\nw\n' | fdisk $BASE_IMG > /dev/null 2>&1
        LOOP=\$(losetup -f --show $BASE_IMG)
        kpartx -as \"\$LOOP\"
        LNAME=\$(basename \"\$LOOP\")
        mkfs.vfat -n BOOT \"/dev/mapper/\${LNAME}p1\" > /dev/null 2>&1
        mkfs.ext4 -Fq -L ROOT \"/dev/mapper/\${LNAME}p2\" > /dev/null 2>&1
        mkdir -p /mnt/root && mount \"/dev/mapper/\${LNAME}p2\" /mnt/root
        mkdir -p /mnt/root/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/root/boot
        bsdtar -xpf $ARCH_TARBALL -C /mnt/root
        sync && umount -R /mnt/root && kpartx -d \"\$LOOP\" && losetup -d \"\$LOOP\"
    "
fi

log_header "PHASE 2: KUBE-NODE CUSTOMIZATION ($HOSTNAME)"
cp "$BASE_IMG" "$TARGET_IMG"

docker run --rm --privileged \
    --dns 8.8.8.8 \
    -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" \
    -e WIFI_PASS="$WIFI_PASS" \
    -e REG_DOMAIN="$REG_DOMAIN" \
    -e STATIC_IP="$STATIC_IP" \
    -e GATEWAY="$GATEWAY" \
    -e HOSTNAME="$HOSTNAME" \
    -e PI_VERSION="$PI_VERSION" \
    -e TARGET_IMG="$TARGET_IMG" \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    task() { echo -ne \"\033[1;35m  [TASK]\033[0m \$1... \"; }
    succ() { echo -e \"\033[1;32m✔ DONE\033[0m\n\"; }

    apt-get update -qq > /dev/null && apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod rsync dosfstools e2fsprogs parted > /dev/null 2>&1
    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    
    LOOP=\$(losetup -f --show \"\$TARGET_IMG\")
    kpartx -as \"\$LOOP\"
    LNAME=\$(basename \"\$LOOP\")
    mkdir -p /mnt/target && mount \"/dev/mapper/\${LNAME}p2\" /mnt/target
    mkdir -p /mnt/target/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/target/boot
    rm -rf /mnt/target/boot/*

    task 'Injecting Total Provisioning Script'
    cat <<'EOF_PROVISION' > /mnt/target/usr/local/bin/rpi-provision.sh
#!/bin/bash
# 1. WiFi & Power Prep
iw dev wlan0 set power_save off || true

# 2. Wait for Internet
while ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; do sleep 3; done

# 3. Pacman & Keys
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy archlinux-keyring --noconfirm

# 4. Speed up Pacman & Full Update
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
pacman -Syu --noconfirm

# 5. Clock Sync (Vital for K8s)
timedatectl set-ntp true

# 6. Disable SWAP (Vital for K8s)
swapoff -a
sed -i '/swap/d' /etc/fstab

# 7. Install & Configure K8s Stack
pacman -S --noconfirm containerd kubeadm kubelet kubectl runc
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd kubelet

# 8. Partition Expansion
ROOT_DEV=\$(findmnt / -o SOURCE -n)
DISK_DEV=\${ROOT_DEV%p*}
PART_NUM=\$(echo \$ROOT_DEV | grep -o '[0-9]\$')
echo -e \"d\n\$PART_NUM\nn\np\n\$PART_NUM\n\n\ny\nw\" | fdisk \$DISK_DEV > /dev/null 2>&1
partx -u \$DISK_DEV || true
resize2fs \$ROOT_DEV > /dev/null 2>&1

# 9. Finished
systemctl disable rpi-provision.service
rm /etc/systemd/system/rpi-provision.service
EOF_PROVISION
    chmod +x /mnt/target/usr/local/bin/rpi-provision.sh

    cat <<EOF > /mnt/target/etc/systemd/system/rpi-provision.service
[Unit]
Description=Full K8s Node Provisioning
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpi-provision.sh
[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/rpi-provision.service /mnt/target/etc/systemd/system/multi-user.target.wants/rpi-provision.service
    succ

    task 'Applying Kernel & Drivers'
    K_MIRROR=\"http://fl.us.mirror.archlinuxarm.org/aarch64\"
    if [ \"\$PI_VERSION\" == \"4\" ]; then
        KERNEL_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v '16k' | grep -v 'headers' | sort -V | tail -n 1)
        DTB=\"bcm2711-rpi-4-b.dtb\"
    else
        KERNEL_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | sort -V | tail -n 1)
        DTB=\"bcm2712-rpi-5-b.dtb\"
    fi
    wget -q \"\$K_MIRROR/core/\$KERNEL_PKG\" \"\$K_MIRROR/core/wireless-regdb-2026.02.04-1-any.pkg.tar.xz\"
    wget -q \"\$K_MIRROR/alarm/raspberrypi-bootloader-2026.03.25-1-any.pkg.tar.xz\"
    wget -q \"\$K_MIRROR/alarm/firmware-raspberrypi-2026.03.09-1-any.pkg.tar.xz\"
    
    tar -xpf \"\$KERNEL_PKG\" -C /mnt/target
    tar -xpf \"wireless-regdb\"* -C /mnt/target
    tar -xpf \"raspberrypi-bootloader\"* -C /mnt/target
    tar -xpf \"firmware-raspberrypi\"* -C /mnt/target
    [ -d /mnt/target/boot/boot ] && mv /mnt/target/boot/boot/* /mnt/target/boot/ && rmdir /mnt/target/boot/boot
    depmod -b /mnt/target \$(ls /mnt/target/usr/lib/modules | head -n 1)
    succ

    task 'Finalizing Network & Boot'
    echo \"\$HOSTNAME\" > /mnt/target/etc/hostname
    cat <<EOF > /mnt/target/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
Address=\$STATIC_IP
Gateway=\$GATEWAY
DNS=1.1.1.1
EOF
    mkdir -p /mnt/target/etc/modprobe.d
    echo \"options brcmfmac roamoff=1 ccode=\$REG_DOMAIN\" > /mnt/target/etc/modprobe.d/brcmfmac.conf
    printf \"country=\$REG_DOMAIN\nctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\np2p_disabled=1\n\nnetwork={\n    ssid=\\\"\$WIFI_SSID\\\"\n    psk=\\\"\$WIFI_PASS\\\"\n    key_mgmt=WPA-PSK\n    ieee80211w=1\n}\n\" > /mnt/target/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
    
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/target/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/target/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB\nusb_max_current_enable=1\" > /mnt/target/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0 ipv6.disable=1 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 cfg80211.regdom=\$REG_DOMAIN\" > /mnt/target/boot/cmdline.txt
    
    sync && umount -R /mnt/target && kpartx -d \"\$LOOP\" && losetup -d \"\$LOOP\"
    succ
"

echo -e "${B_GREEN}Node $HOSTNAME is ready to flash!${NC}"
