#!/bin/bash
set -e

# --- CONFIGURATION ---
HOSTNAME="kube-master-01"         
PI_VERSION="5"                    
STATIC_IP="192.168.1.150/24"      
GATEWAY="192.168.1.1"
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="PT"

WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
TARGET_IMG="${HOSTNAME}.img"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
LOG_FILE="$WORKSPACE/build.log"

# --- STYLING ---
B_MAGENTA='\033[1;35m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
NC='\033[0m'

log_header() { echo -e "\n${B_MAGENTA}🚀 [$(date +%T)] ==================== $1 ====================${NC}"; }
log_success(){ echo -e "     ${B_GREEN}✔${NC} $1"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# PHASE 1: BASE IMAGE (Silent if exists)
if [ ! -f "$BASE_IMG" ]; then
    log_header "PHASE 1: BUILDING BASE"
    truncate -s 10G "$BASE_IMG"
    docker run --rm --privileged -v "$WORKSPACE":/work ubuntu:22.04 bash -c "
        apt-get update -qq && apt-get install -y -qq fdisk e2fsprogs dosfstools libarchive-tools kpartx kmod > /dev/null 2>&1
        printf 'o\nn\np\n1\n\n+2G\nt\nc\nn\np\n2\n\n\nw\n' | fdisk $BASE_IMG > /dev/null 2>&1
        LOOP=\$(losetup -f --show $BASE_IMG); kpartx -as \"\$LOOP\"; LNAME=\$(basename \"\$LOOP\")
        mkfs.vfat -n BOOT \"/dev/mapper/\${LNAME}p1\" > /dev/null 2>&1
        mkfs.ext4 -Fq -L ROOT \"/dev/mapper/\${LNAME}p2\" > /dev/null 2>&1
        mkdir -p /mnt/root && mount \"/dev/mapper/\${LNAME}p2\" /mnt/root
        mkdir -p /mnt/root/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/root/boot
        bsdtar -xpf $ARCH_TARBALL -C /mnt/root
        sync && umount -R /mnt/root && kpartx -d \"\$LOOP\" && losetup -d \"\$LOOP\"
    "
fi

# PHASE 2: CUSTOMIZATION
log_header "PHASE 2: FIXING HANGS & KEYBOARD"
cp "$BASE_IMG" "$TARGET_IMG"

docker run --rm --privileged \
    --dns 8.8.8.8 -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" -e WIFI_PASS="$WIFI_PASS" -e REG_DOMAIN="$REG_DOMAIN" \
    -e STATIC_IP="$STATIC_IP" -e GATEWAY="$GATEWAY" -e HOSTNAME="$HOSTNAME" \
    -e PI_VERSION="$PI_VERSION" -e TARGET_IMG="$TARGET_IMG" \
    ubuntu:22.04 bash -c "
    set -e
    apt-get update -qq && apt-get install -y -qq kpartx curl xz-utils fdisk wget kmod rsync dosfstools e2fsprogs parted > /dev/null 2>&1
    cd /work
    LOOP_DEV=\$(losetup -f --show \"\$TARGET_IMG\"); kpartx -as \"\$LOOP_DEV\"; LNAME=\$(basename \"\$LOOP_DEV\")
    mkdir -p /mnt/target && mount \"/dev/mapper/\${LNAME}p2\" /mnt/target
    mkdir -p /mnt/target/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/target/boot
    rm -rf /mnt/target/boot/*

    # Fix Root Access
    echo 'root:root' | chroot /mnt/target chpasswd
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /mnt/target/etc/ssh/sshd_config
    
    # NEW: Disable the Network Wait Job that causes the 90s hang
    chroot /mnt/target systemctl mask systemd-networkd-wait-online.service

    # Provisioning script
    cat <<'EOF_PROV' > /mnt/target/usr/local/bin/rpi-provision.sh
#!/bin/bash
exec > >(tee -a /var/log/provision.log) 2>&1
log() { echo -e \"\033[1;32m[\$(date +%T)] \$1\033[0m\" > /dev/tty1; }

log \"🚀 STARTING PROVISIONING\"
# Try to get internet but don't hang boot if it fails
for i in {1..10}; do ping -c 1 -W 1 8.8.8.8 &>/dev/null && break || sleep 2; done

pacman-key --init && pacman-key --populate archlinuxarm
pacman -Sy --noconfirm archlinux-keyring
pacman -Syu --noconfirm
pacman -S --noconfirm containerd kubeadm kubelet kubectl runc open-iscsi nfs-utils
mkdir -p /etc/containerd && containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd kubelet iscsid

# Modules
echo -e \"overlay\nbr_netfilter\" > /etc/modules-load.d/k8s.conf
modprobe overlay && modprobe br_netfilter
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
EOF
sysctl --system

# Resize
ROOT_DEV=\$(findmnt / -o SOURCE -n)
echo -e \"d\n2\nn\np\n2\n\n\ny\nw\" | fdisk \${ROOT_DEV%p*} > /dev/null 2>&1
partx -u \${ROOT_DEV%p*} || true && resize2fs \$ROOT_DEV

log \"✅ DONE!\"
systemctl disable rpi-provision.service
EOF_PROV
    chmod +x /mnt/target/usr/local/bin/rpi-provision.sh

    # Service setup (no network dependency)
    cat <<EOF > /mnt/target/etc/systemd/system/rpi-provision.service
[Unit]
Description=Provision
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpi-provision.sh
StandardOutput=tty
TTYPath=/dev/tty1
[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/rpi-provision.service /mnt/target/etc/systemd/system/multi-user.target.wants/rpi-provision.service

    # Fetch Drivers
    K_MIRROR=\"http://fl.us.mirror.archlinuxarm.org/aarch64\"
    K_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v '16k' | grep -v 'headers' | sort -V | tail -n 1)
    DTB=\"bcm2711-rpi-4-b.dtb\"; [ \"\$PI_VERSION\" == \"5\" ] && DTB=\"bcm2712-rpi-5-b.dtb\"
    BOOT=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    FIRM=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    wget -q \"\$K_MIRROR/core/\$K_PKG\" \"\$K_MIRROR/alarm/\$BOOT\" \"\$K_MIRROR/alarm/\$FIRM\"
    
    tar -xpf \"\$K_PKG\" -C /mnt/target
    tar -xpf \"\$BOOT\" -C /mnt/target
    tar -xpf \"\$FIRM\" -C /mnt/target
    [ -d /mnt/target/boot/boot ] && mv /mnt/target/boot/boot/* /mnt/target/boot/ && rmdir /mnt/target/boot/boot
    
    echo \"\$HOSTNAME\" > /mnt/target/etc/hostname
    cat <<EOF > /mnt/target/etc/systemd/network/25-wireless.network
[Match]
Name=wlan0
[Network]
Address=\$STATIC_IP
Gateway=\$GATEWAY
DNS=1.1.1.1
EOF
    printf \"country=\$REG_DOMAIN\nctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\nnetwork={\n ssid=\\\"\$WIFI_SSID\\\"\n psk=\\\"\$WIFI_PASS\\\"\n}\n\" > /mnt/target/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/target/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/target/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB\nusb_max_current_enable=1\" > /mnt/target/boot/config.txt
    
    # FORCE USB ALIVE: Added 'usbcore.autosuspend=-1' and 'pcie_aspm=off'
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0 pcie_aspm=off usbcore.autosuspend=-1\" > /mnt/target/boot/cmdline.txt
    
    sync && umount -R /mnt/target && kpartx -d \"\$LOOP_DEV\" && losetup -d \"\$LOOP_DEV\"
"

DURATION=$((SECONDS - START_TIME))
echo -e "\n${B_MAGENTA}BUILD COMPLETE - Use /dev/rdisk for flashing!${NC}"
