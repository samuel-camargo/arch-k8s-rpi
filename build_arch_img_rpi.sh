#!/bin/bash
# Kube-Arch Cluster Factory v47 - BASE64 EDITION
set -e

# --- CONFIGURATION (Update per node) ---
HOSTNAME="kube-master-01"         
PI_VERSION="5"                    
STATIC_IP="192.168.1.150/24"      
GATEWAY="192.168.1.1"
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="PT"
BUILD_VERSION="v47-Gold"

# --- SYSTEM PATHS ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
TARGET_IMG="${HOSTNAME}.img"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"

# --- STYLING ---
B_MAGENTA='\033[1;35m'; B_CYAN='\033[1;36m'; B_GREEN='\033[1;32m'; NC='\033[0m'

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo -e "\n${B_MAGENTA}🚀 PHASE 1: BASE ARCHITECTURE${NC}"
[ -f "$ARCH_TARBALL" ] && [ -f "$BASE_IMG" ] || (echo "Missing base files!" && exit 1)

echo -e "${B_MAGENTA}🚀 PHASE 2: CUSTOMIZATION (v47)${NC}"
cp "$BASE_IMG" "$TARGET_IMG"

# Generate the Banner in Base64 to avoid escaping hell
BANNER_B64=$(echo '#!/bin/bash
COL_M="\033[1;35m"; COL_C="\033[1;36m"; NC="\033[0m"
echo -e "${COL_M}=======================================================${NC}"
echo -e "  🚀 ${COL_C}NODE:${NC} $(hostname)"
echo -e "  ⭐ ${COL_C}OS:${NC}   $(grep PRETTY_NAME /etc/os-release | cut -d\"\\\"\" -f2)"
echo -e "  🧠 ${COL_C}KERN:${NC} $(uname -r)"
echo -e "  📦 ${COL_C}PKGS:${NC} $(pacman -Q | wc -l) installed"
echo -e "  🌐 ${COL_C}IP:${NC}   $(hostname -I | awk "{print \$1}")"
echo -e "  🛠️  ${COL_C}IMG:${NC}  '${BUILD_VERSION}'"
echo -e "${COL_M}=======================================================${NC}"' | base64)

docker run --rm --privileged --dns 8.8.8.8 -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" -e WIFI_PASS="$WIFI_PASS" -e REG_DOMAIN="$REG_DOMAIN" \
    -e STATIC_IP="$STATIC_IP" -e GATEWAY="$GATEWAY" -e HOSTNAME="$HOSTNAME" \
    -e BANNER_DATA="$BANNER_B64" -e TARGET_IMG="$TARGET_IMG" \
    -e PI_VER="$PI_VERSION" \
    ubuntu:22.04 bash -c "
    set -e
    apt-get update -qq && apt-get install -y -qq kpartx curl fdisk wget kmod rsync dosfstools e2fsprogs > /dev/null 2>&1
    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    
    LOOP_DEV=\$(losetup -f --show \"\$TARGET_IMG\"); kpartx -as \"\$LOOP_DEV\"; LNAME=\$(basename \"\$LOOP_DEV\")
    mkdir -p /mnt/target && mount \"/dev/mapper/\${LNAME}p2\" /mnt/target
    mkdir -p /mnt/target/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/target/boot

    # --- DECODE THE BANNER ---
    echo \"\$BANNER_DATA\" | base64 -d > /mnt/target/etc/profile.d/kube-banner.sh
    chmod +x /mnt/target/etc/profile.d/kube-banner.sh

    # Security & Quiet Console
    echo 'root:root' | chroot /mnt/target chpasswd
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /mnt/target/etc/ssh/sshd_config
    mkdir -p /mnt/target/etc/sysctl.d
    echo 'kernel.printk = 1 1 1 1' > /mnt/target/etc/sysctl.d/20-quiet.conf

    # Provisioner Logic
    cat <<'EOF_PROV' > /mnt/target/usr/local/bin/rpi-provision.sh
#!/bin/bash
set -e
echo \"1 1 1 1\" > /proc/sys/kernel/printk
exec > >(tee -a /var/log/provision.log) 2>&1
for i in {1..20}; do ping -c 1 -W 1 8.8.8.8 &>/dev/null && break || sleep 2; done
pacman-key --init && pacman-key --populate archlinuxarm
pacman -Sy --noconfirm archlinux-keyring && pacman -Syu --noconfirm
pacman -S --noconfirm containerd kubeadm kubelet kubectl runc open-iscsi nfs-utils
mkdir -p /etc/containerd && containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd kubelet iscsid
echo -e \"overlay\nbr_netfilter\" > /etc/modules-load.d/k8s.conf
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
EOF
sysctl --system
ROOT_DEV=\$(findmnt / -o SOURCE -n)
echo -e \"d\n2\nn\np\n2\n\n\ny\nw\" | fdisk \${ROOT_DEV%p*} > /dev/null 2>&1
partx -u \${ROOT_DEV%p*} || true && resize2fs \$ROOT_DEV > /dev/null 2>&1
systemctl disable rpi-provision.service
EOF_PROV
    chmod +x /mnt/target/usr/local/bin/rpi-provision.sh
    ln -sf /etc/systemd/system/rpi-provision.service /mnt/target/etc/systemd/system/multi-user.target.wants/rpi-provision.service

    # Fetching correct Kernel for the Pi
    K_MIRROR=\"http://fl.us.mirror.archlinuxarm.org/aarch64\"
    K_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    REG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'wireless-regdb-[^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    DTB=\"bcm2711-rpi-4-b.dtb\"; [ \"\$PI_VER\" == \"5\" ] && DTB=\"bcm2712-rpi-5-b.dtb\"
    BOOT=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    FIRM=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    wget -q \"\$K_MIRROR/core/\$K_PKG\" \"\$K_MIRROR/core/\$REG\" \"\$K_MIRROR/alarm/\$BOOT\" \"\$K_MIRROR/alarm/\$FIRM\"
    
    rm -rf /mnt/target/boot/*
    tar -xpf \"\$K_PKG\" -C /mnt/target && tar -xpf \"\$REG\" -C /mnt/target
    tar -xpf \"\$BOOT\" -C /mnt/target && tar -xpf \"\$FIRM\" -C /mnt/target
    [ -d /mnt/target/boot/boot ] && mv /mnt/target/boot/boot/* /mnt/target/boot/ && rmdir /mnt/target/boot/boot
    K_VER=\$(ls /mnt/target/usr/lib/modules | head -n 1)
    depmod -b /mnt/target \"\$K_VER\"
    
    echo \"\$HOSTNAME\" > /mnt/target/etc/hostname
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB\nusb_max_current_enable=1\" > /mnt/target/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty3 console=tty1 selinux=0 net.ifnames=0 cma=128M pcie_aspm=off usbcore.autosuspend=-1 loglevel=1 quiet systemd.show_status=false cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1\" > /mnt/target/boot/cmdline.txt
    
    sync && umount -R /mnt/target && kpartx -d \"\$LOOP_DEV\" && losetup -d \"\$LOOP_DEV\"
"

echo -e "\n${B_GREEN}✔ BUILD v47 COMPLETE!${NC}"
