#!/bin/bash
# Kube-Arch Cluster Factory v45 - SAMUEL EDITION
set -e

# --- CONFIGURATION ---
HOSTNAME="kube-master-01"         
PI_VERSION="5"                    
STATIC_IP="192.168.1.150/24"      
GATEWAY="192.168.1.1"
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="PT"
BUILD_VERSION="v45"

# --- SYSTEM PATHS ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
TARGET_IMG="${HOSTNAME}.img"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"

# --- STYLING ---
B_MAGENTA='\033[1;35m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
NC='\033[0m'

START_TIME=$SECONDS
log_header() { echo -e "\n${B_MAGENTA}🚀 [$(date +%T)] ==================== $1 ====================${NC}"; }
log_step()   { printf "  \033[1;36m[⏳]\033[0m %-30s " "$1"; }
log_done()   { echo -e "\033[1;32mDONE\033[0m"; }

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

log_header "PHASE 1: BASE ARCHITECTURE"
[ -f "$ARCH_TARBALL" ] && [ -f "$BASE_IMG" ] || (echo "Missing base files!" && exit 1)

log_header "PHASE 2: CUSTOMIZATION & BANNER (v45)"
cp "$BASE_IMG" "$TARGET_IMG"

if docker run --rm --privileged --dns 8.8.8.8 -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" -e WIFI_PASS="$WIFI_PASS" -e REG_DOMAIN="$REG_DOMAIN" \
    -e STATIC_IP="$STATIC_IP" -e GATEWAY="$GATEWAY" -e HOSTNAME="$HOSTNAME" \
    -e BUILD_VER="$BUILD_VERSION" -e TARGET_IMG="$TARGET_IMG" \
    ubuntu:22.04 bash -c "
    set -e
    apt-get update -qq && apt-get install -y -qq kpartx curl fdisk wget kmod rsync dosfstools e2fsprogs > /dev/null 2>&1
    cd /work
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    
    task() { printf \"  \033[1;36m[⏳]\033[0m %-30s \" \"\$1\"; }
    done_task() { echo -e \"\033[1;32mDONE\033[0m\"; }

    task 'Mounting'
    LOOP_DEV=\$(losetup -f --show \"\$TARGET_IMG\"); kpartx -as \"\$LOOP_DEV\"; LNAME=\$(basename \"\$LOOP_DEV\")
    mkdir -p /mnt/target && mount \"/dev/mapper/\${LNAME}p2\" /mnt/target
    mkdir -p /mnt/target/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/target/boot
    done_task

    task 'Injecting Login Banner'
    # Create the static build info file
    echo \"\$BUILD_VER\" > /mnt/target/etc/rpi-build-version
    date +'%Y-%m-%d %H:%M' > /mnt/target/etc/rpi-build-date

    # Create the dynamic banner script
    cat <<'EOF_MOTD' > /mnt/target/etc/profile.d/kube-banner.sh
#!/bin/bash
# Kube-Node Login Banner
COL_M='\033[1;35m'
COL_C='\033[1;36m'
COL_G='\033[1;32m'
COL_Y='\033[1;33m'
NC='\033[0m'

echo -e \"\${COL_M}=======================================================\${NC}\"
echo -e \"  🚀 \${COL_C}NODE:\${NC} \$(hostname)\"
echo -e \"  ⭐ \${COL_C}OS:\${NC}   \$(grep PRETTY_NAME /etc/os-release | cut -d'\\\"' -f2)\"
echo -e \"  🧠 \${COL_C}KERN:\${NC} \$(uname -r)\"
echo -e \"  📦 \${COL_C}PKGS:\${NC} \$(pacman -Q | wc -l) installed\"
echo -e \"  🌐 \${COL_C}IP:\${NC}   \$(hostname -I | awk '{print \$1}') (wlan0)\"
echo -e \"  🛠️  \${COL_C}IMG:\${NC}  \$(cat /etc/rpi-build-version) (Built: \$(cat /etc/rpi-build-date))\"
echo -e \"\${COL_M}=======================================================\${NC}\"
EOF_MOTD
    chmod +x /mnt/target/etc/profile.d/kube-banner.sh
    done_task

    task 'Cluster Hardening'
    echo 'root:root' | chroot /mnt/target chpasswd
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /mnt/target/etc/ssh/sshd_config
    echo 'kernel.printk = 1 1 1 1' > /mnt/target/etc/sysctl.d/20-quiet.conf
    chroot /mnt/target systemctl mask systemd-networkd-wait-online.service > /dev/null 2>&1
    done_task

    task 'Fetching Drivers'
    K_MIRROR=\"http://fl.us.mirror.archlinuxarm.org/aarch64\"
    K_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    REG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'wireless-regdb-[^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    DTB=\"bcm2712-rpi-5-b.dtb\"
    BOOT=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    FIRM=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    wget -q \"\$K_MIRROR/core/\$K_PKG\" \"\$K_MIRROR/core/\$REG\" \"\$K_MIRROR/alarm/\$BOOT\" \"\$K_MIRROR/alarm/\$FIRM\"
    done_task

    task 'Finalizing'
    rm -rf /mnt/target/boot/*
    tar -xpf \"\$K_PKG\" -C /mnt/target && tar -xpf \"\$REG\" -C /mnt/target
    tar -xpf \"\$BOOT\" -C /mnt/target && tar -xpf \"\$FIRM\" -C /mnt/target
    [ -d /mnt/target/boot/boot ] && mv /mnt/target/boot/boot/* /mnt/target/boot/ && rmdir /mnt/target/boot/boot
    K_VER=\$(ls /mnt/target/usr/lib/modules | head -n 1)
    depmod -b /mnt/target \"\$K_VER\"
    
    echo \"\$HOSTNAME\" > /mnt/target/etc/hostname
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB\nusb_max_current_enable=1\ndtparam=act_led_trigger=none\" > /mnt/target/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty3 console=tty1 selinux=0 net.ifnames=0 cma=128M pcie_aspm=off usbcore.autosuspend=-1 loglevel=1 quiet systemd.show_status=false cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1\" > /mnt/target/boot/cmdline.txt
    
    sync && umount -R /mnt/target && kpartx -d \"\$LOOP_DEV\" && losetup -d \"\$LOOP_DEV\"
    done_task
"; then
    DURATION=$((SECONDS - START_TIME))
    log_header "BUILD v45 COMPLETE"
    log_done
fi
