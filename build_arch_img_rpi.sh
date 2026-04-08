#!/bin/bash

# Stop script on any error
set -e

# --- CONFIGURATION (UPDATE THESE FOR EACH NODE) ---
HOSTNAME="kube-worker-03"         # master-01, master-02, worker-01, worker-02, worker-03
PI_VERSION="4"                    # 4 for RPi4, 5 for RPi5
STATIC_IP="192.168.1.162/24"      # IPs: .150 (M1), .151 (M2), .160 (W1), .161 (W2), .162 (W3)
GATEWAY="192.168.1.1"
WIFI_SSID="YOUR_WIFI_NAME"
WIFI_PASS="YOUR_WIFI_PASSWORD"
REG_DOMAIN="PT"

# --- SYSTEM PATHS ---
WORKSPACE="$HOME/rpi_arch_build"
BASE_IMG="rpi_arch_base.img"
TARGET_IMG="${HOSTNAME}.img"
ARCH_TARBALL="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
LOG_FILE="$WORKSPACE/build.log"

# --- STYLING & HELPERS ---
B_MAGENTA='\033[1;35m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

START_TIME=$SECONDS

log_header() { echo -e "\n${B_MAGENTA}🚀 [$(date +%T)] ==================== $1 ====================${NC}"; }
log_step()   { echo -e "${B_CYAN}[⭐]${NC} $1"; }
log_info()   { echo -e "     ${B_YELLOW}i${NC} $1"; }
log_success(){ echo -e "     ${B_GREEN}✔${NC} $1"; }
log_error()  { echo -e "${B_RED}[💥 ERROR]${NC} $1\nCheck $LOG_FILE for details."; exit 1; }

mkdir -p "$WORKSPACE"
echo "--- Build Log Started $(date) ---" > "$LOG_FILE"
cd "$WORKSPACE"

# =========================================================
# PRE-FLIGHT CHECK
# =========================================================
log_header "PRE-FLIGHT CHECK"
echo -e "  Target Host: ${B_GREEN}$HOSTNAME${NC}"
echo -e "  Hardware:    ${B_GREEN}Raspberry Pi $PI_VERSION${NC}"
echo -e "  Network:     ${B_GREEN}$STATIC_IP${NC} via ${B_GREEN}$WIFI_SSID${NC}"
echo -e "  Log File:    ${B_CYAN}$LOG_FILE${NC}"

# =========================================================
# PHASE 1: BASE IMAGE GENERATION
# =========================================================
log_header "PHASE 1: BASE ARCHITECTURE"

if [ ! -f "$ARCH_TARBALL" ]; then
    log_step "Downloading Arch Linux ARM Tarball..."
    wget -c -O "$ARCH_TARBALL" "http://os.archlinuxarm.org/os/$ARCH_TARBALL" >> "$LOG_FILE" 2>&1 || log_error "Download failed."
else
    log_info "Tarball found ($ARCH_TARBALL)."
fi

if [ ! -f "$BASE_IMG" ]; then
    log_step "Building 10GB Base Image (First time only)..."
    truncate -s 10G "$BASE_IMG"
    docker run --rm --privileged -v "$WORKSPACE":/work ubuntu:22.04 bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq apt-utils fdisk e2fsprogs dosfstools libarchive-tools kpartx kmod >> /work/build.log 2>&1
        cd /work
        for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
        wipefs -af $BASE_IMG >> /work/build.log 2>&1
        printf 'o\nn\np\n1\n\n+2G\nt\nc\nn\np\n2\n\n\nw\n' | fdisk $BASE_IMG >> /work/build.log 2>&1
        LOOP=\$(losetup -f --show $BASE_IMG)
        kpartx -as \"\$LOOP\"
        LNAME=\$(basename \"\$LOOP\")
        mkfs.vfat -n BOOT \"/dev/mapper/\${LNAME}p1\" >> /work/build.log 2>&1
        mkfs.ext4 -Fq -L ROOT \"/dev/mapper/\${LNAME}p2\" >> /work/build.log 2>&1
        mkdir -p /mnt/root && mount \"/dev/mapper/\${LNAME}p2\" /mnt/root
        mkdir -p /mnt/root/boot && mount \"/dev/mapper/\${LNAME}p1\" /mnt/root/boot
        bsdtar -xpf $ARCH_TARBALL -C /mnt/root
        sync && umount -R /mnt/root && kpartx -d \"\$LOOP\" && losetup -d \"\$LOOP\"
    " || log_error "Base build failed."
    log_success "Base image ready (10GB)."
else
    log_info "Reusing existing base image ($BASE_IMG)."
fi

# =========================================================
# PHASE 2: CUSTOMIZATION
# =========================================================
log_header "PHASE 2: KUBE-NODE HARDENING"

log_step "Cloning and Mapping Target Image..."
cp "$BASE_IMG" "$TARGET_IMG"

docker run --rm --privileged \
    --dns 8.8.8.8 -v "$WORKSPACE":/work \
    -e WIFI_SSID="$WIFI_SSID" -e WIFI_PASS="$WIFI_PASS" -e REG_DOMAIN="$REG_DOMAIN" \
    -e STATIC_IP="$STATIC_IP" -e GATEWAY="$GATEWAY" -e HOSTNAME="$HOSTNAME" \
    -e PI_VERSION="$PI_VERSION" -e TARGET_IMG="$TARGET_IMG" \
    ubuntu:22.04 bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    
    task() { echo -ne \"\033[1;36m  [⏳]\033[0m \$1... \"; }
    done_task() { echo -e \"\033[1;32mDONE\033[0m\"; }

    # Squelch noisy setup
    apt-get update -qq >> /work/build.log 2>&1 && apt-get install -y -qq apt-utils kpartx curl xz-utils fdisk wget kmod rsync dosfstools e2fsprogs parted >> /work/build.log 2>&1
    cd /work
    rm -f *.pkg.tar.xz*
    for i in {0..63}; do [ ! -b /dev/loop\$i ] && mknod -m 0660 /dev/loop\$i b 7 \$i || true; done
    losetup -D
    
    task 'Mounting Filesystems'
    LOOP_DEV=\$(losetup -f --show \"\$TARGET_IMG\")
    kpartx -as \"\$LOOP_DEV\"
    LNAME=\$(basename \"\$LOOP_DEV\")
    
    # BREADCRUMB: Export mapper paths for visibility
    MAP_BOOT=\"/dev/mapper/\${LNAME}p1\"
    MAP_ROOT=\"/dev/mapper/\${LNAME}p2\"
    echo \"[DEBUG] Mapper Boot: \$MAP_BOOT\" >> /work/build.log
    
    # CRITICAL: Settle time for Docker-on-Mac storage sync
    sleep 3
    
    mkdir -p /mnt/target && mount \"\$MAP_ROOT\" /mnt/target
    mkdir -p /mnt/target/boot && mount \"\$MAP_BOOT\" /mnt/target/boot
    rm -rf /mnt/target/boot/*
    done_task

    task 'Injecting Provisioning Script'
    cat <<'EOF_PROV' > /mnt/target/usr/local/bin/rpi-provision.sh
#!/bin/bash
iw dev wlan0 set power_save off || true
while ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; do sleep 3; done
pacman-key --init && pacman-key --populate archlinuxarm
pacman -Sy archlinux-keyring --noconfirm
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
pacman -Syu --noconfirm
timedatectl set-ntp true
swapoff -a && sed -i '/swap/d' /etc/fstab
mkdir -p /etc/modules-load.d && echo -e \"overlay\nbr_netfilter\" > /etc/modules-load.d/k8s.conf
modprobe overlay || true && modprobe br_netfilter || true
cat <<EOF_SYS > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF_SYS
sysctl --system
pacman -S --noconfirm containerd kubeadm kubelet kubectl runc
mkdir -p /etc/containerd && containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd kubelet
ROOT_DEV=\$(findmnt / -o SOURCE -n)
echo -e \"d\n2\nn\np\n2\n\n\ny\nw\" | fdisk \${ROOT_DEV%p*} > /dev/null 2>&1
partx -u \${ROOT_DEV%p*} || true && resize2fs \$ROOT_DEV > /dev/null 2>&1
systemctl disable rpi-provision.service && rm /etc/systemd/system/rpi-provision.service
EOF_PROV
    chmod +x /mnt/target/usr/local/bin/rpi-provision.sh
    
    cat <<EOF > /mnt/target/etc/systemd/system/rpi-provision.service
[Unit]
Description=K8s Provision
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rpi-provision.sh
[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/rpi-provision.service /mnt/target/etc/systemd/system/multi-user.target.wants/rpi-provision.service
    done_task

    task 'Fetching Drivers'
    K_MIRROR=\"http://fl.us.mirror.archlinuxarm.org/aarch64\"
    if [ \"\$PI_VERSION\" == \"4\" ]; then
        K_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v '16k' | grep -v 'headers' | sort -V | tail -n 1)
        DTB=\"bcm2711-rpi-4-b.dtb\"
    else
        K_PKG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'linux-rpi-[0-9][^[:space:]\"]+\.pkg\.tar\.xz' | grep -v 'headers' | sort -V | tail -n 1)
        DTB=\"bcm2712-rpi-5-b.dtb\"
    fi
    REG=\$(curl -sL \$K_MIRROR/core/ | grep -oE 'wireless-regdb-[^[:space:]\"]+\.pkg\.tar\.xz' | head -n 1)
    BOOT=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'raspberrypi-bootloader-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    FIRM=\$(curl -sL \$K_MIRROR/alarm/ | grep -oE 'firmware-raspberrypi-[^[:space:]\"]+\.pkg\.tar\.xz' | tail -n 1)
    wget -q \"\$K_MIRROR/core/\$K_PKG\" \"\$K_MIRROR/core/\$REG\" \"\$K_MIRROR/alarm/\$BOOT\" \"\$K_MIRROR/alarm/\$FIRM\"
    echo \"[INFO] Package: \$K_PKG\" >> /work/build.log
    done_task

    task 'Extracting & Finalizing'
    tar -xpf \"\$K_PKG\" -C /mnt/target >> /work/build.log 2>&1
    tar -xpf \"\$REG\" -C /mnt/target >> /work/build.log 2>&1
    tar -xpf \"\$BOOT\" -C /mnt/target >> /work/build.log 2>&1
    tar -xpf \"\$FIRM\" -C /mnt/target >> /work/build.log 2>&1
    [ -d /mnt/target/boot/boot ] && mv /mnt/target/boot/boot/* /mnt/target/boot/ && rmdir /mnt/target/boot/boot
    depmod -b /mnt/target \$(ls /mnt/target/usr/lib/modules | head -n 1)
    
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
    echo \"options brcmfmac roamoff=1 feature_disable=0x82000 ccode=\$REG_DOMAIN\" > /mnt/target/etc/modprobe.d/brcmfmac.conf
    printf \"country=\$REG_DOMAIN\nctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\np2p_disabled=1\n\nnetwork={\n    ssid=\\\"\$WIFI_SSID\\\"\n    psk=\\\"\$WIFI_PASS\\\"\n    key_mgmt=WPA-PSK\n    ieee80211w=1\n}\n\" > /mnt/target/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service /mnt/target/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/target/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    sed -i 's/^root:[^:]*:/root::/' /mnt/target/etc/shadow
    echo -e \"arm_64bit=1\nkernel=Image\ndevice_tree=\$DTB\nusb_max_current_enable=1\" > /mnt/target/boot/config.txt
    echo \"root=/dev/mmcblk0p2 rw rootwait console=tty1 selinux=0 net.ifnames=0 ipv6.disable=1 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 cfg80211.regdom=\$REG_DOMAIN\" > /mnt/target/boot/cmdline.txt
    
    sync && umount -R /mnt/target && kpartx -d \"\$LOOP_DEV\" >> /work/build.log 2>&1 && losetup -d \"\$LOOP_DEV\"
    done_task
" || log_error "Build failed."

# =========================================================
# FINAL SUMMARY
# =========================================================
DURATION=$((SECONDS - START_TIME))
log_header "BUILD COMPLETE"
log_success "Target:    ${B_GREEN}$TARGET_IMG${NC}"
log_success "Time:      ${B_YELLOW}$((DURATION / 60))m $((DURATION % 60))s${NC}"
log_success "Command:   ${B_CYAN}sudo dd if=$TARGET_IMG of=/dev/diskX bs=4M status=progress${NC}"
echo -e "\n${B_MAGENTA}=======================================================${NC}"
