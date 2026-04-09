#!/bin/bash
# ==============================================================================
# Kube-Arch Cluster Factory v55 - THE ULTIMA GOLD
# Optimized for: RPi 4/5, Arch Linux ARM, 1Gbps Internal LAN, Ansible & K8s
# ==============================================================================
set -e

# --- [1] NODE CONFIGURATION (EDIT THIS FOR EVERY NODE) ---
HOSTNAME="kube-master-01"         
PI_VERSION="5"                    # "4" or "5"

# Network - WiFi (Internet/Management)
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
WIFI_STATIC_IP="192.168.1.150/24"
WIFI_GATEWAY="192.168.1.1"

# Network - Ethernet (1Gbps Cluster Internal Traffic)
# No Gateway here to ensure cluster-to-cluster stays on the switch.
LAN_IP="10.0.0.150/24"

# --- [2] SYSTEM PATHS ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
TARGET_IMG="${HOSTNAME}.img"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
BUILD_VER="v55-Ultima-Gold"

# --- [3] LOGGING UI ---
B_MAGENTA='\033[1;35m'; B_CYAN='\033[1;36m'; B_GREEN='\033[1;32m'; B_RED='\033[1;31m'; NC='\033[0m'
log_header() { echo -e "\n${B_MAGENTA}🚀 [$(date +%T)] $1${NC}"; }
log_step()   { printf "  ${B_CYAN}[⏳] %-40s${NC} " "$1"; }
log_done()   { echo -e "${B_GREEN}DONE${NC}"; }

# --- [4] PRE-FLIGHT CHECKS ---
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"
log_header "PHASE 1: ENVIRONMENT VERIFICATION"

if [ ! -f "$ARCH_TARBALL" ]; then
    echo -e "${B_RED}❌ Missing Arch Tarball!${NC}" && exit 1
fi
if [ ! -f "$BASE_IMG" ]; then
    log_step "Base image missing. Creating 4GB base..."
    truncate -s 4G "$BASE_IMG"
    log_done
fi

log_step "Cloning base to $TARGET_IMG"
cp "$BASE_IMG" "$TARGET_IMG"
log_done

# --- [5] DOCKER CUSTOMIZATION ENGINE ---
log_header "PHASE 2: THE FORGE (DOCKER CUSTOMIZATION)"

docker run --rm --privileged --dns 8.8.8.8 -v "$WORKSPACE":/work \
    -e HOSTNAME="$HOSTNAME" -e PI_VER="$PI_VERSION" \
    -e W_SSID="$WIFI_SSID" -e W_PASS="$WIFI_PASS" -e W_IP="$WIFI_STATIC_IP" -e W_GW="$WIFI_GATEWAY" \
    -e LAN_IP="$LAN_IP" -e BUILD_VER="$BUILD_VER" -e TARGET_IMG="$TARGET_IMG" \
    ubuntu:22.04 bash -c "
    set -e
    apt-get update -qq && apt-get install -y -qq kpartx curl fdisk wget kmod rsync dosfstools e2fsprogs > /dev/null 2>&1
    
    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done

    # Helper for inner logging
    itask() { printf \"  \033[1;36m[Forge]\033[0m %-38s \" \"\$1\"; }
    idone() { echo -e \"\033[1;32mOK\033[0m\"; }

    itask 'Mounting Image'
    LOOP_DEV=\$(losetup -f --show \"\$TARGET_IMG\"); kpartx -as \"\$LOOP_DEV\"; LNAME=\$(basename \"\$LOOP_DEV\")
    mkdir -p /mnt/target && mount \"/dev/mapper/\${LNAME}p2\" /mnt/target
    mkdir -p /mnt/target/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/target/boot
    idone

    itask 'Configuring Dual-Home Network (WiFi+LAN)'
    # WiFi Config
    cat <<EOF > /mnt/target/etc/systemd/network/25-wlan0.network
[Match]
Name=wlan0
[Network]
Address=\$W_IP
Gateway=\$W_GW
DNS=8.8.8.8
EOF
    # LAN Config (Internal Cluster Traffic)
    cat <<EOF > /mnt/target/etc/systemd/network/20-eth0.network
[Match]
Name=eth0
[Network]
Address=\$LAN_IP
IPv6PrivacyExtensions=no
EOF
    idone

    itask 'Injecting Versioning & Universal Banner'
    echo \"\$BUILD_VER\" > /mnt/target/etc/rpi-build-version
    cat <<'EOF_B' > /mnt/target/etc/profile.d/kube-banner.sh
#!/bin/bash
[ -f /etc/os-release ] && . /etc/os-release
C_M='\033[1;35m'; C_C='\033[1;36m'; NC='\033[0m'
IP_W=\$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1)
IP_E=\$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1)
echo -e \"\${C_M}=======================================================\${NC}\"
echo -e \"  🚀 \${C_C}NODE:\${NC} \$(cat /etc/hostname)\"
echo -e \"  ⭐ \${C_C}OS:\${NC}   \${PRETTY_NAME:-Arch Linux}\"
echo -e \"  🧠 \${C_C}KERN:\${NC} \$(uname -r)\"
echo -e \"  🌐 \${C_C}WIFI:\${NC} \${IP_W:-Disconnected}\"
echo -e \"  🔌 \${C_C}LAN:\${NC}  \${IP_E:-Disconnected}\"
echo -e \"  🛠️  \${C_C}IMG:\${NC}  \$(cat /etc/rpi-build-version 2>/dev/null)\"
echo -e \"\${C_M}=======================================================\${NC}\"
EOF_B
    chmod +x /mnt/target/etc/profile.d/kube-banner.sh
    idone

    itask 'Preparing Kubernetes & Ansible Provisioner'
    cat <<'EOF_PROV' > /mnt/target/usr/local/bin/rpi-provision.sh
#!/bin/bash
# Muzzle kernel noise during init
echo \"1 1 1 1\" > /proc/sys/kernel/printk
pacman-key --init && pacman-key --populate archlinuxarm
pacman -Sy --noconfirm archlinux-keyring && pacman -Syu --noconfirm
# Added python for Ansible and inetutils for hostname
pacman -S --noconfirm containerd kubeadm kubelet kubectl runc open-iscsi nfs-utils inetutils python raspberrypi-utils
mkdir -p /etc/containerd && containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd kubelet iscsid
echo -e \"overlay\nbr_netfilter\" > /etc/modules-load.d/k8s.conf
cat <<EOF_K > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
EOF_K
sysctl --system
systemctl disable rpi-provision.service
EOF_PROV
    chmod +x /mnt/target/usr/local/bin/rpi-provision.sh
    ln -sf /etc/systemd/system/rpi-provision.service /mnt/target/etc/systemd/system/multi-user.target.wants/rpi-provision.service
    idone

    itask 'Finalizing Bootloader & Cgroups'
    # Setup Hostname & Root Pass
    echo \"\$HOSTNAME\" > /mnt/target/etc/hostname
    echo 'root:root' | chroot /mnt/target chpasswd
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /mnt/target/etc/ssh/sshd_config

    # Fetch correct Firmware/Kernel for RPi
    K_MIRROR=\"http://fl.us.mirror.archlinuxarm.org/aarch64\"
    K_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    BOOT=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    FIRM=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    wget -q \"\$K_MIRROR/core/\$K_PKG\" \"\$K_MIRROR/alarm/\$BOOT\" \"\$K_MIRROR/alarm/\$FIRM\"
    
    rm -rf /mnt/target/boot/*
    tar -xpf \"\$K_PKG\" -C /mnt/target && tar -xpf \"\$BOOT\" -C /mnt/target && tar -xpf \"\$FIRM\" -C /mnt/target
    [ -d /mnt/target/boot/boot ] && mv /mnt/target/boot/boot/* /mnt/target/boot/ && rmdir /mnt/target/boot/boot
    
    DTB=\"bcm2711-rpi-4-b.dtb\"; [ \"\$PI_VER\" == \"5\" ] && DTB=\"bcm2712-rpi-5-b.dtb\"
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB\nusb_max_current_enable=1\" > /mnt/target/boot/config.txt
    # CRITICAL: Added cgroup_memory=1 and memory limit fixes
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty3 console=tty1 selinux=0 net.ifnames=0 cma=128M pcie_aspm=off usbcore.autosuspend=-1 loglevel=1 quiet systemd.show_status=false cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1\" > /mnt/target/boot/cmdline.txt
    
    sync && umount -R /mnt/target && kpartx -d \"\$LOOP_DEV\" && losetup -d \"\$LOOP_DEV\"
    idone
"

log_header "BUILD COMPLETE: $TARGET_IMG"
echo -e "Next Steps:"
echo -e "1. Flash image: ${B_CYAN}sudo dd if=$TARGET_IMG of=/dev/sdX bs=4M status=progress${NC}"
echo -e "2. Boot and wait 2 mins for auto-provisioning."
echo -e "3. Use Ansible from your Mac to manage all nodes!"
