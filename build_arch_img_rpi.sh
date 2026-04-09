#!/bin/bash
# ==============================================================================
# Kube-Arch Cluster Factory v60 - THE DEFINITIVE GOLD
# ==============================================================================
set -e

# --- NODE CONFIGURATION ---
HOSTNAME="kube-master-02"         
PI_VERSION="5"                    
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
WIFI_STATIC_IP="192.168.1.151/24"
WIFI_GATEWAY="192.168.1.1"
LAN_IP="10.0.0.151/24"

# --- SYSTEM PATHS ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
TARGET_IMG="${HOSTNAME}.img"
BUILD_VER="v60-Definitive-Gold"

# --- LOGGING ---
B_MAGENTA='\033[1;35m'; B_CYAN='\033[1;36m'; B_GREEN='\033[1;32m'; NC='\033[0m'
log_header() { echo -e "\n${B_MAGENTA}🚀 [$(date +%T)] $1${NC}"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log_header "PHASE 1: CLONING BASE IMAGE"
cp "$BASE_IMG" "$TARGET_IMG"

log_header "PHASE 2: THE FORGE (v60)"

docker run --rm --privileged --dns 8.8.8.8 -v "$WORKSPACE":/work \
    -e HOSTNAME="$HOSTNAME" -e PI_VER="$PI_VERSION" \
    -e W_SSID="$WIFI_SSID" -e W_PASS="$WIFI_PASS" -e W_IP="$WIFI_STATIC_IP" -e W_GW="$WIFI_GATEWAY" \
    -e LAN_IP="$LAN_IP" -e BUILD_VER="$BUILD_VER" -e TARGET_IMG="$TARGET_IMG" \
    ubuntu:22.04 bash -c "
    set -e
    apt-get update -qq && apt-get install -y -qq kpartx curl fdisk wget kmod rsync dosfstools e2fsprogs xz-utils > /dev/null 2>&1
    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done

    LOOP_DEV=\$(losetup -f --show \"\$TARGET_IMG\"); kpartx -as \"\$LOOP_DEV\"; LNAME=\$(basename \"\$LOOP_DEV\")
    mkdir -p /mnt/target && mount \"/dev/mapper/\${LNAME}p2\" /mnt/target
    mkdir -p /mnt/target/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/target/boot

    # CLEAN BOOT (The Anti-Cgroup-Disable Strike)
    rm -rf /mnt/target/boot/*

    # WIFI & LAN
    cat <<EOF > /mnt/target/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel
update_config=1
network={
    ssid=\"\$W_SSID\"
    psk=\"\$W_PASS\"
}
EOF
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/target/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    
    cat <<EOF > /mnt/target/etc/systemd/network/25-wlan0.network
[Match]
Name=wlan0
[Network]
Address=\$W_IP
Gateway=\$W_GW
DNS=8.8.8.8
EOF
    cat <<EOF > /mnt/target/etc/systemd/network/20-eth0.network
[Match]
Name=eth0
[Network]
Address=\$LAN_IP
EOF

    # THE PROVISIONER (Now with extra Keyring safety)
    cat <<'EOF_PROV' > /mnt/target/usr/local/bin/rpi-provision.sh
#!/bin/bash
# 1. Critical Keyring Setup
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy --noconfirm archlinux-keyring

# 2. Complete Sync
pacman -Syu --noconfirm

# 3. K8s & Ansible Essentials
pacman -S --noconfirm containerd kubeadm kubelet kubectl open-iscsi nfs-utils inetutils python raspberrypi-utils

# 4. Storage & Kernel Configs
systemctl enable --now containerd kubelet iscsid
echo -e "overlay\nbr_netfilter" > /etc/modules-load.d/k8s.conf
cat <<EOF_K > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
EOF_K
sysctl --system
systemctl disable rpi-provision.service
EOF_PROV
    chmod +x /mnt/target/usr/local/bin/rpi-provision.sh
    ln -sf /etc/systemd/system/rpi-provision.service /mnt/target/etc/systemd/system/multi-user.target.wants/rpi-provision.service

    # KERNEL FETCH (The Grep-v 16k is back!)
    K_MIRROR=\"http://fl.us.mirror.archlinuxarm.org/aarch64\"
    K_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v '16k' | head -n 1)
    BOOT=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    FIRM=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    wget -q \"\$K_MIRROR/core/\$K_PKG\" \"\$K_MIRROR/alarm/\$BOOT\" \"\$K_MIRROR/alarm/\$FIRM\"
    
    tar -xpf \"\$K_PKG\" -C /mnt/target && tar -xpf \"\$BOOT\" -C /mnt/target && tar -xpf \"\$FIRM\" -C /mnt/target
    [ -d /mnt/target/boot/boot ] && mv /mnt/target/boot/boot/* /mnt/target/boot/ && rmdir /mnt/target/boot/boot

    K_VER=\$(ls /mnt/target/usr/lib/modules | grep rpi | grep -v 16k | head -n 1)
    depmod -b /mnt/target \"\$K_VER\"

    # FINAL BOOT FILES (Clean Cgroups)
    echo \"\$HOSTNAME\" > /mnt/target/etc/hostname
    echo 'root:root' | chroot /mnt/target chpasswd
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /mnt/target/etc/ssh/sshd_config
    
    DTB=\"bcm2712-rpi-5-b.dtb\"
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB\nusb_max_current_enable=1\" > /mnt/target/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty3 console=tty1 selinux=0 net.ifnames=0 cma=128M pcie_aspm=off usbcore.autosuspend=-1 loglevel=1 quiet systemd.show_status=false cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1\" > /mnt/target/boot/cmdline.txt
    
    sync && umount -R /mnt/target && kpartx -d \"\$LOOP_DEV\" && losetup -d \"\$LOOP_DEV\"
"
log_header "v60 BUILD COMPLETE!"
