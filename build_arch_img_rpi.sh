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
B_GREEN='\033[1;32m'
NC='\033[0m'

log_header() { echo -e "\n${B_MAGENTA}🚀 [$(date +%T)] ==================== $1 ====================${NC}"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# PHASE 2: CUSTOMIZATION
log_header "PHASE 2: NUCLEAR FIX FOR RPi 5 HANGS"
cp "$BASE_IMG" "$TARGET_IMG"

docker run --rm --privileged \
    --dns 8.8.8.8 -v "$WORKSPACE":/work \
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

    # 1. FORCE ROOT PASSWORD
    echo 'root:root' | chroot /mnt/target chpasswd
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /mnt/target/etc/ssh/sshd_config

    # 2. GLOBAL SYSTEMD TIMEOUTS (No more 90s waits!)
    sed -i 's/#DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=10s/' /mnt/target/etc/systemd/system.conf
    chroot /mnt/target systemctl mask systemd-networkd-wait-online.service

    # 3. PROVISIONING (No network dependency)
    cat <<'EOF_PROV' > /mnt/target/usr/local/bin/rpi-provision.sh
#!/bin/bash
exec > >(tee -a /var/log/provision.log) 2>&1
log() { echo -e \"\033[1;32m[\$(date +%T)] \$1\033[0m\" > /dev/tty1; }
log \"🚀 PROVISION START\"
# Attempt internet but proceed if failed
for i in {1..10}; do ping -c 1 -W 1 8.8.8.8 &>/dev/null && break || sleep 2; done
pacman-key --init && pacman-key --populate archlinuxarm
pacman -Sy --noconfirm archlinux-keyring
pacman -Syu --noconfirm
pacman -S --noconfirm containerd kubeadm kubelet kubectl runc open-iscsi nfs-utils
systemctl enable --now containerd kubelet iscsid
log \"✅ PROVISION COMPLETE\"
systemctl disable rpi-provision.service
EOF_PROV
    chmod +x /mnt/target/usr/local/bin/rpi-provision.sh

    cat <<EOF > /mnt/target/etc/systemd/system/rpi-provision.service
[Unit]
Description=Provision
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpi-provision.sh
StandardOutput=tty
TTYPath=/dev/tty1
[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/rpi-provision.service /mnt/target/etc/systemd/system/multi-user.target.wants/rpi-provision.service

    # 4. FETCH DRIVERS
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
    # Link drivers
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/target/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    
    # 5. HARDENED BOOT FLAGS
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB\nusb_max_current_enable=1\ndtparam=pciex1_gen=3\" > /mnt/target/boot/config.txt
    
    # KILL HANGS: DefaultTimeoutStartSec should prevent the 90s hang at a kernel level
    # pcie_port_pm=off stops the RP1 chip from glitching on power-save
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0 pcie_aspm=off pcie_port_pm=off usbcore.autosuspend=-1\" > /mnt/target/boot/cmdline.txt
    
    sync && umount -R /mnt/target && kpartx -d \"\$LOOP_DEV\" && losetup -d \"\$LOOP_DEV\"
"

DURATION=$((SECONDS - START_TIME))
echo -e "\n${B_MAGENTA}BUILD COMPLETE - FLASHING READY!${NC}"
