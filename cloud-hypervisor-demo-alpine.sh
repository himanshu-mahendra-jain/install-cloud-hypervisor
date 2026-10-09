#!/bin/bash
set -euo pipefail

# ============================================================
# Cloud Hypervisor - Alpine Linux VM
#
# Persistent Alpine root filesystem (latest stable release)
# 100 MiB total disk
# Direct kernel boot (latest Cloud Hypervisor Linux kernel)
# Network
# No firmware
# ============================================================

# ------------------------------------------------------------
# Error handling
# ------------------------------------------------------------

error() {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

# Ensure root privileges
if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "Root privileges required. Re-running with sudo..."
        SCRIPT_PATH="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"
        exec sudo -- bash "$SCRIPT_PATH" "$@"
    else
        error "This script requires root privileges. Please execute using sudo."
    fi
fi

# Detect actual target user (allows environment/CLI override, falls back safely)
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"

TARGET_GROUP="$(id -gn "$TARGET_USER")"

run_as_target() {
    if [[ "$TARGET_USER" == "root" ]]; then
        "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- "$@"
    else
        sudo -u "$TARGET_USER" -- "$@"
    fi
}

CH="/usr/local/bin/cloud-hypervisor"

VM_ROOT="/var/lib/cloud-hypervisor-data"
VM_DIR="$VM_ROOT/test-alpine"

ARCH="x86_64"

ALPINE_CDN="https://dl-cdn.alpinelinux.org/alpine"

CH_KERNEL_REPO="https://github.com/cloud-hypervisor/linux.git"
KERNEL_SRC="$VM_DIR/linux-cloud-hypervisor"
KERNEL="$VM_DIR/vmlinux"
KERNEL_REF_FILE="$VM_DIR/vmlinux.ref"

DISK="$VM_DIR/alpine-100m.raw"
ROOTFS_MOUNT="$VM_DIR/rootfs"
CH_SOCK="$VM_DIR/ch-alpine.sock"

TAP_IF="tap0"
NFT_TABLE="ch_nat"

CURL=(curl -fL --retry 5 --retry-delay 2 --retry-all-errors)

# ------------------------------------------------------------
# Cleanup (unmount, temporary files, host networking)
# ------------------------------------------------------------

MOUNTED=0
TMP_DIR=""
NET_CONFIGURED=0
declare -A SAVED_SYSCTL=()

cleanup() {
    local key

    if [[ "$MOUNTED" -eq 1 ]]; then
        umount "$ROOTFS_MOUNT" || true
        MOUNTED=0
    fi

    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi

    if [[ "$NET_CONFIGURED" -eq 1 ]]; then
        echo
        echo "==> Restoring host networking"
        nft delete table ip "$NFT_TABLE" 2>/dev/null || true
        ip link delete "$TAP_IF" 2>/dev/null || true
        for key in "${!SAVED_SYSCTL[@]}"; do
            sysctl -q -w "$key=${SAVED_SYSCTL[$key]}" 2>/dev/null || true
        done
        NET_CONFIGURED=0
    fi

    # Cloud Hypervisor puts the terminal in raw mode for the serial console
    if [[ -t 0 ]]; then
        stty sane 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

[[ "$(uname -m)" == "$ARCH" ]] \
    || error "This demo supports $ARCH hosts only (detected: $(uname -m))."

[[ -x "$CH" ]] || error "Cloud Hypervisor not found: $CH. Run install-cloud-hypervisor.sh first."

# Only one demo instance may own the disk, TAP interface, and API socket
exec 9>/run/cloud-hypervisor-demo-alpine.lock
flock -n 9 || error "Another instance of this demo is already running."

echo "==> Cloud Hypervisor"
"$CH" --version

# ------------------------------------------------------------
# Demo dependencies
# ------------------------------------------------------------

echo
echo "==> Checking demo dependencies"

REQUIRED_PACKAGES=(
    ca-certificates
    curl
    tar
    coreutils
    e2fsprogs
    iproute2
    nftables
    acl
    git
    make
    gcc
    libc6-dev
    bc
    bison
    flex
    perl
    pkgconf
    libssl-dev
    libelf-dev
    dwarves
)

command -v apt-get >/dev/null 2>&1 \
    || error "apt-get is required on the supported Debian-based host."

MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [[ "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then
    echo "    Installing missing packages: ${MISSING_PACKAGES[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${MISSING_PACKAGES[@]}"
else
    echo "    All required packages are already installed"
fi

MKFS_BIN="$(command -v mkfs.ext4 || echo "/sbin/mkfs.ext4")"
[[ -x "$MKFS_BIN" ]] || error "mkfs.ext4 not found."

# ------------------------------------------------------------
# VM directory
# ------------------------------------------------------------

echo
echo "==> Preparing VM directory"

mkdir -p "$VM_DIR"

if [[ "$TARGET_USER" != "root" ]]; then
    chown "$TARGET_USER:$TARGET_GROUP" "$VM_DIR"
fi

chmod 700 "$VM_DIR"

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"

# ------------------------------------------------------------
# Create 100 MiB disk
# ------------------------------------------------------------

echo
echo "==> Creating 100 MiB Alpine disk"

if [[ ! -f "$DISK" ]]; then

    truncate -s 100M "$DISK"

    "$MKFS_BIN" \
        -F \
        -O ^metadata_csum,^64bit \
        -L alpine-root \
        "$DISK"

else

    echo "    Existing disk found."

fi

chown "$TARGET_USER:$TARGET_GROUP" "$DISK"
chmod 600 "$DISK"

# ------------------------------------------------------------
# Mount disk
# ------------------------------------------------------------

mkdir -p "$ROOTFS_MOUNT"

if mountpoint -q "$ROOTFS_MOUNT"; then
    echo "    Existing rootfs mount found; unmounting stale mount."
    umount "$ROOTFS_MOUNT" || error "Could not unmount stale rootfs mount: $ROOTFS_MOUNT"
fi

if command -v losetup >/dev/null 2>&1; then
    while read -r LOOPDEV; do
        [[ -n "$LOOPDEV" ]] || continue
        echo "    Detaching stale loop device: $LOOPDEV"
        losetup -d "$LOOPDEV" || error "Could not detach stale loop device: $LOOPDEV"
    done < <(losetup -j "$DISK" | awk -F: 'NF {print $1}')
fi

mount -o loop "$DISK" "$ROOTFS_MOUNT"
MOUNTED=1

# ------------------------------------------------------------
# Download and install Alpine minirootfs (first run only)
# ------------------------------------------------------------

if [[ ! -f "$ROOTFS_MOUNT/etc/alpine-release" ]]; then

    echo
    echo "==> Resolving Alpine release"

    RELEASES_YAML="$TMP_DIR/latest-releases.yaml"

    "${CURL[@]}" -sS \
        -o "$RELEASES_YAML" \
        "$ALPINE_CDN/latest-stable/releases/$ARCH/latest-releases.yaml"

    # Each release flavor is a YAML list entry; pick the minirootfs one.
    ALPINE_VERSION="$(
        awk '
            /^-/                           { version = "" }
            /^[[:space:]]+version:/        { version = $2 }
            /^[[:space:]]+flavor: alpine-minirootfs$/ { print version; exit }
        ' "$RELEASES_YAML"
    )"

    [[ "$ALPINE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || error "Could not determine the latest Alpine minirootfs version."

    echo "    Latest stable Alpine: $ALPINE_VERSION"

    MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
    MINIROOTFS_URL="$ALPINE_CDN/v${ALPINE_VERSION%.*}/releases/$ARCH/$MINIROOTFS"
    MINIROOTFS_FILE="$TMP_DIR/$MINIROOTFS"

    echo
    echo "==> Downloading Alpine minirootfs"

    "${CURL[@]}" --progress-bar -o "$MINIROOTFS_FILE" "$MINIROOTFS_URL"
    "${CURL[@]}" -sS -o "$MINIROOTFS_FILE.sha256" "$MINIROOTFS_URL.sha256"

    echo
    echo "==> Verifying Alpine minirootfs"

    (
        cd "$TMP_DIR"
        sha256sum -c "$MINIROOTFS.sha256"
    ) || error "Alpine minirootfs checksum verification failed."

    echo
    echo "==> Installing Alpine root filesystem"

    tar \
        -xzf "$MINIROOTFS_FILE" \
        -C "$ROOTFS_MOUNT"

else

    echo
    echo "==> Installing Alpine root filesystem"
    echo "    Alpine $(cat "$ROOTFS_MOUNT/etc/alpine-release") already installed."

fi

# Package repositories must match the installed release, not the latest one
ALPINE_BRANCH="v$(cut -d. -f1,2 "$ROOTFS_MOUNT/etc/alpine-release")"

# ------------------------------------------------------------
# Configure Alpine
# ------------------------------------------------------------

echo "==> Configuring Alpine"

mkdir -p \
    "$ROOTFS_MOUNT/proc" \
    "$ROOTFS_MOUNT/sys" \
    "$ROOTFS_MOUNT/dev" \
    "$ROOTFS_MOUNT/run"

tee "$ROOTFS_MOUNT/etc/fstab" >/dev/null <<'EOF'
LABEL=alpine-root / ext4 defaults 0 1
EOF

tee "$ROOTFS_MOUNT/etc/hostname" >/dev/null <<'EOF'
alpine-ch
EOF

tee "$ROOTFS_MOUNT/etc/hosts" >/dev/null <<'EOF'
127.0.0.1 localhost
127.0.1.1 alpine-ch
::1       localhost
EOF

tee "$ROOTFS_MOUNT/etc/apk/repositories" >/dev/null <<EOF
$ALPINE_CDN/$ALPINE_BRANCH/main
$ALPINE_CDN/$ALPINE_BRANCH/community
EOF

sed -i \
    's/^root:[^:]*:/root::/' \
    "$ROOTFS_MOUNT/etc/shadow"

echo "    Configuring BusyBox init, inittab, and network"

# Use relative symlink so the link is valid both inside chroot/VM and from the mount point
ln -sf ../bin/busybox "$ROOTFS_MOUNT/sbin/init"
chmod +x "$ROOTFS_MOUNT/bin/busybox"

# Configure inittab for remount, network, and shell
tee "$ROOTFS_MOUNT/etc/inittab" >/dev/null <<'EOF'
::sysinit:/bin/mount -t proc proc /proc 2>/dev/null || true
::sysinit:/bin/mount -t sysfs sysfs /sys 2>/dev/null || true
::sysinit:/bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
::sysinit:/bin/mount -t tmpfs tmpfs /run 2>/dev/null || true
::sysinit:/bin/mount -o remount,rw /
::sysinit:/bin/hostname -F /etc/hostname 2>/dev/null || hostname alpine-ch
::sysinit:/sbin/ip link set eth0 up
::sysinit:/sbin/ip addr add 192.168.100.2/24 dev eth0
::sysinit:/sbin/ip route add default via 192.168.100.1
ttyS0::respawn:-/bin/sh
tty1::respawn:-/bin/sh
EOF

# Configure DNS
tee "$ROOTFS_MOUNT/etc/resolv.conf" >/dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Unmount the disk image before running Cloud Hypervisor
umount "$ROOTFS_MOUNT"
MOUNTED=0

# ------------------------------------------------------------
# Build Cloud Hypervisor Linux kernel
# ------------------------------------------------------------
echo
echo "==> Preparing Cloud Hypervisor Linux kernel"

LATEST_REF="$(
    git ls-remote --tags --refs "$CH_KERNEL_REPO" 'ch-release-v*' \
        | awk '{sub("refs/tags/", "", $2); print $2}' \
        | sort -V \
        | tail -n1
)"

[[ -n "$LATEST_REF" ]] \
    || error "Could not determine the latest Cloud Hypervisor Linux release tag."

echo "    Latest release: $LATEST_REF"

if [[ -s "$KERNEL" && "$(cat "$KERNEL_REF_FILE" 2>/dev/null || true)" == "$LATEST_REF" ]]; then

    echo "    Kernel already built from the latest release; skipping build."

else

    if [[ -d "$KERNEL_SRC/.git" ]]; then
        echo "    Updating Cloud Hypervisor Linux source to $LATEST_REF"

        git -C "$KERNEL_SRC" fetch --depth 1 origin tag "$LATEST_REF"
        git -C "$KERNEL_SRC" checkout -q --force "$LATEST_REF"
    else
        echo "    Cloning Cloud Hypervisor Linux: $LATEST_REF"

        git clone \
            --depth 1 \
            --branch "$LATEST_REF" \
            "$CH_KERNEL_REPO" \
            "$KERNEL_SRC"
    fi

    (
        cd "$KERNEL_SRC"

        echo "    Configuring kernel"
        make ch_defconfig

        echo "    Checking required VM features"

        for opt in VIRTIO_PCI VIRTIO_BLK VIRTIO_NET EXT4_FS; do
            grep -q "^CONFIG_${opt}=y" .config \
                || error "Cloud Hypervisor kernel lacks CONFIG_${opt}=y"
        done

        echo "    Building x86-64 kernel"

        make -j"$(nproc)" bzImage
    )

    KERNEL_BUILD="$KERNEL_SRC/arch/x86/boot/compressed/vmlinux.bin"

    [[ -s "$KERNEL_BUILD" ]] \
        || error "Cloud Hypervisor kernel build failed."

    cp "$KERNEL_BUILD" "$KERNEL"
    echo "$LATEST_REF" > "$KERNEL_REF_FILE"

fi

echo "    Kernel: $LATEST_REF ($(du -h "$KERNEL" | awk '{print $1}'))"

chown "$TARGET_USER:$TARGET_GROUP" "$KERNEL"
chmod 600 "$KERNEL"

# ------------------------------------------------------------
# KVM
# ------------------------------------------------------------

echo
echo "==> Checking KVM"

[[ -c /dev/kvm ]] \
    || error "/dev/kvm is not available."

KVM_TEST_CMD="exec 3<>/dev/kvm"

if ! run_as_target bash -c "$KVM_TEST_CMD" 2>/dev/null; then
    # Grant session access without a re-login, as the installer does
    setfacl -m "u:$TARGET_USER:rw" /dev/kvm 2>/dev/null || true

    run_as_target bash -c "$KVM_TEST_CMD" 2>/dev/null \
        || error "$TARGET_USER cannot access /dev/kvm. Run install-cloud-hypervisor.sh first."
fi

echo "    /dev/kvm: accessible by $TARGET_USER"

# ------------------------------------------------------------
# Host Networking (TAP + NAT via nftables)
# ------------------------------------------------------------

echo
echo "==> Configuring host networking (nftables)"

HOST_IF="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
[[ -n "$HOST_IF" ]] || HOST_IF="$(ip route show default | awk '/default/ {print $5}' | head -n1)"

# Remember host settings so they can be restored when the VM exits
SYSCTL_KEYS=(
    net.ipv4.ip_forward
    net.ipv4.conf.all.rp_filter
    net.ipv4.conf.default.rp_filter
)
[[ -n "$HOST_IF" ]] && SYSCTL_KEYS+=("net.ipv4.conf.$HOST_IF.rp_filter")

for key in "${SYSCTL_KEYS[@]}"; do
    SAVED_SYSCTL[$key]="$(sysctl -n "$key" 2>/dev/null)" || unset 'SAVED_SYSCTL[$key]'
done

NET_CONFIGURED=1

# Recreate tap0 with static IP assigned to target user
ip link delete "$TAP_IF" 2>/dev/null || true
ip tuntap add dev "$TAP_IF" mode tap user "$TARGET_USER"
ip addr replace 192.168.100.1/24 dev "$TAP_IF"
ip link set "$TAP_IF" up

# Disable TX checksum offload on tap0 to prevent dropped packets
if command -v ethtool >/dev/null 2>&1; then
    ethtool -K "$TAP_IF" tx off 2>/dev/null || true
fi

# Enable IPv4 routing and disable strict reverse-path filtering
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf.default.rp_filter=0
sysctl -q -w net.ipv4.conf."$TAP_IF".rp_filter=0
if [[ -n "$HOST_IF" ]]; then
    sysctl -q -w net.ipv4.conf."$HOST_IF".rp_filter=0 2>/dev/null || true
fi

# Configure nftables table, chains, and routing rules
nft delete table ip "$NFT_TABLE" 2>/dev/null || true

if [[ -n "$HOST_IF" ]]; then
    nft -f - <<EOF
table ip $NFT_TABLE {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$HOST_IF" masquerade
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "$TAP_IF" oifname "$HOST_IF" accept
        iifname "$HOST_IF" oifname "$TAP_IF" ct state established,related accept
    }
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "$TAP_IF" accept
    }
}
EOF
    echo "    NAT: $TAP_IF -> $HOST_IF"
else
    echo "    WARNING: No default route found; the VM will have no outbound network access."
fi

# ------------------------------------------------------------
# Start VM
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Starting real Alpine Linux VM"
echo " Run 'poweroff' inside the VM to stop it."
echo "============================================================"
echo

rm -f "$CH_SOCK"

# Not exec'd, so the EXIT trap can restore host networking afterwards
run_as_target "$CH" \
    --kernel "$KERNEL" \
    --disk "path=$DISK,image_type=raw" \
    --net "tap=$TAP_IF" \
    --cpus "boot=1,max=4" \
    --api-socket "$CH_SOCK" \
    --memory "size=256M,hotplug_method=acpi,hotplug_size=2G" \
    --serial tty \
    --console off \
    --cmdline "console=ttyS0,115200 root=/dev/vda rootfstype=ext4 rw init=/sbin/init"
