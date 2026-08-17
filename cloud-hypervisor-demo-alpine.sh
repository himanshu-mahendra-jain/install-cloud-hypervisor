#!/bin/bash
set -euo pipefail

# ============================================================
# Cloud Hypervisor - Alpine Linux VM
#
# Persistent Alpine root filesystem
# 100 MiB total disk
# Direct kernel boot
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
        exec sudo -- "$SCRIPT_PATH" "$@"
    else
        error "This script requires root privileges. Please execute using sudo."
    fi
fi

# Detect actual target user (allows environment/CLI override, falls back safely)
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || TARGET_HOME="$HOME"

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

ALPINE_VERSION="3.24.1"
ARCH="x86_64"

ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/$ARCH"

MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"

MINIROOTFS_URL="$ALPINE_BASE/$MINIROOTFS"
MINIROOTFS_SHA_URL="$MINIROOTFS_URL.sha256"

KERNEL_URL="$ALPINE_BASE/netboot/vmlinuz-virt"
INITRD_URL="$ALPINE_BASE/netboot/initramfs-virt"

KERNEL="$VM_DIR/vmlinuz-virt"
INITRD="$VM_DIR/initramfs-virt"

DISK="$VM_DIR/alpine-100m.raw"
ROOTFS_MOUNT="$VM_DIR/rootfs"

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

[[ -x "$CH" ]] || error "Cloud Hypervisor not found: $CH"

echo "==> Cloud Hypervisor"
"$CH" --version

for cmd in curl tar sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 \
        || error "Required command not found: $cmd"
done

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

# ------------------------------------------------------------
# Download minirootfs
# ------------------------------------------------------------

MINIROOTFS_FILE="$VM_DIR/$MINIROOTFS"
MINIROOTFS_SHA="$MINIROOTFS_FILE.sha256"

echo
echo "==> Downloading Alpine minirootfs"

if [[ ! -s "$MINIROOTFS_FILE" ]]; then
    curl -fL \
        --retry 5 \
        --retry-delay 2 \
        --retry-all-errors \
        --progress-bar \
        -o "$MINIROOTFS_FILE.tmp" \
        "$MINIROOTFS_URL"

    [[ -s "$MINIROOTFS_FILE.tmp" ]] \
        || error "Minirootfs download failed."

    mv "$MINIROOTFS_FILE.tmp" "$MINIROOTFS_FILE"
fi

echo
echo "==> Verifying Alpine minirootfs"

curl -fL \
    --retry 5 \
    --retry-delay 2 \
    --retry-all-errors \
    -sS \
    -o "$MINIROOTFS_SHA" \
    "$MINIROOTFS_SHA_URL"

(
    cd "$VM_DIR"
    sha256sum -c "$(basename "$MINIROOTFS_SHA")"
)

# ------------------------------------------------------------
# Download kernel
# ------------------------------------------------------------

echo
echo "==> Downloading Alpine kernel"

if [[ ! -s "$KERNEL" ]]; then
    curl -fL \
        --retry 5 \
        --retry-delay 2 \
        --retry-all-errors \
        --progress-bar \
        -o "$KERNEL.tmp" \
        "$KERNEL_URL"

    [[ -s "$KERNEL.tmp" ]] \
        || error "Kernel download failed."

    mv "$KERNEL.tmp" "$KERNEL"
fi

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
# Mount disk and install Alpine minirootfs
# ------------------------------------------------------------

echo
echo "==> Installing Alpine root filesystem"

mkdir -p "$ROOTFS_MOUNT"

MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        umount "$ROOTFS_MOUNT" || true
        MOUNTED=0
    fi
}

trap cleanup EXIT

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

if [[ ! -f "$ROOTFS_MOUNT/etc/alpine-release" ]]; then

    echo "    Extracting Alpine minirootfs"

    tar \
        -xzf "$MINIROOTFS_FILE" \
        -C "$ROOTFS_MOUNT"

else

    echo "    Alpine filesystem already installed."

fi

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
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
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
::sysinit:/bin/mount -o remount,rw /
::sysinit:/bin/mount -t proc proc /proc 2>/dev/null || true
::sysinit:/bin/mount -t sysfs sysfs /sys 2>/dev/null || true
::sysinit:/bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
::sysinit:/bin/mount -t tmpfs tmpfs /run 2>/dev/null || true
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
# Build ext4-capable kernel + initramfs outside the 100 MiB VM disk
# ------------------------------------------------------------

echo
echo "==> Building Alpine kernel and initramfs"

BUILD_ROOT="$VM_DIR/alpine-initramfs-build"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

echo "    Extracting Alpine minirootfs into build environment"
tar -xzf "$MINIROOTFS_FILE" -C "$BUILD_ROOT"

tee "$BUILD_ROOT/etc/apk/repositories" >/dev/null <<EOF
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
EOF

cp -L /etc/resolv.conf "$BUILD_ROOT/etc/resolv.conf"

chroot "$BUILD_ROOT" /bin/sh -c \
    'getent hosts dl-cdn.alpinelinux.org >/dev/null 2>&1' \
    || error "DNS resolution failed inside Alpine build chroot."

chroot "$BUILD_ROOT" /sbin/apk update
chroot "$BUILD_ROOT" /sbin/apk add --no-cache linux-virt mkinitfs

KERNEL_VERSION="$(chroot "$BUILD_ROOT" /bin/sh -c \
    'for f in /lib/modules/*/kernel-suffix; do
        [ -f "$f" ] || continue
        d="${f%/kernel-suffix}"
        basename "$d"
        break
    done')"

[[ -n "$KERNEL_VERSION" ]] \
    || error "Could not determine installed Alpine kernel version."

echo "    Kernel version: $KERNEL_VERSION"

tee "$BUILD_ROOT/etc/mkinitfs/mkinitfs.conf" >/dev/null <<'EOF'
features="base virtio ext4 kms"
EOF

chroot "$BUILD_ROOT" \
    /sbin/mkinitfs \
    -c /etc/mkinitfs/mkinitfs.conf \
    -o /tmp/initramfs-virt-ext4 \
    "$KERNEL_VERSION"

cp "$BUILD_ROOT/boot/vmlinuz-virt" "$KERNEL"
cp "$BUILD_ROOT/tmp/initramfs-virt-ext4" "$INITRD"

[[ -s "$KERNEL" ]] || error "Generated Alpine kernel is empty."
[[ -s "$INITRD" ]] || error "Generated Alpine initramfs is empty."

if command -v lsinitramfs >/dev/null 2>&1; then
    lsinitramfs "$INITRD" | grep -qE '(^|/)ext4\.ko' \
        || error "Generated initramfs does not contain ext4.ko."
fi

echo "    Kernel: $(du -h "$KERNEL" | awk '{print $1}')"
echo "    Initramfs: $(du -h "$INITRD" | awk '{print $1}')"

rm -rf "$BUILD_ROOT"

chown "$TARGET_USER:$TARGET_GROUP" "$KERNEL" "$INITRD"
chmod 600 "$KERNEL" "$INITRD"

# ------------------------------------------------------------
# KVM
# ------------------------------------------------------------

echo
echo "==> Checking KVM"

[[ -c /dev/kvm ]] \
    || error "/dev/kvm is not available."

if ! (exec 3<>/dev/kvm) 2>/dev/null; then
    error "Cannot access /dev/kvm."
fi

# Ensure unprivileged target user has read/write access to /dev/kvm
if [[ "$TARGET_USER" != "root" ]]; then
    setfacl -m "u:$TARGET_USER:rw" /dev/kvm 2>/dev/null || chmod 666 /dev/kvm
fi

echo "    /dev/kvm: available"

# ------------------------------------------------------------
# Host Networking (TAP + NAT via nftables)
# ------------------------------------------------------------

echo
echo "==> Configuring host networking (nftables)"

HOST_IF="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')"
[[ -n "$HOST_IF" ]] || HOST_IF="$(ip route show default | awk '/default/ {print $5}' | head -n1)"

# Recreate persistent tap0 with static IP assigned to target user
ip link delete tap0 2>/dev/null || true
ip tuntap add dev tap0 mode tap user "$TARGET_USER"
ip addr replace 192.168.100.1/24 dev tap0
ip link set tap0 up

# Disable TX checksum offload on tap0 to prevent dropped packets
if command -v ethtool >/dev/null 2>&1; then
    ethtool -K tap0 tx off 2>/dev/null || true
fi

# Enable IPv4 routing and disable strict reverse-path filtering
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf.default.rp_filter=0
sysctl -q -w net.ipv4.conf.tap0.rp_filter=0
if [[ -n "$HOST_IF" ]]; then
    sysctl -q -w net.ipv4.conf."$HOST_IF".rp_filter=0 2>/dev/null || true
fi

# Configure nftables table, chains, and routing rules
nft delete table ip ch_nat 2>/dev/null || true

if [[ -n "$HOST_IF" ]]; then
    nft -f - <<EOF
table ip ch_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$HOST_IF" masquerade
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "tap0" oifname "$HOST_IF" accept
        iifname "$HOST_IF" oifname "tap0" ct state established,related accept
    }
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "tap0" accept
    }
}
EOF
fi

# ------------------------------------------------------------
# Start VM
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Starting real Alpine Linux VM"
echo "============================================================"
echo

CH_SOCK="$VM_DIR/ch-alpine.sock"
rm -f "$CH_SOCK"

run_as_target "$CH" \
    --kernel "$KERNEL" \
    --initramfs "$INITRD" \
    --disk "path=$DISK" \
    --net "tap=tap0,ip=192.168.100.1,mask=255.255.255.0" \
    --cpus "boot=1,max=4" \
    --api-socket "$CH_SOCK" \
    --memory "size=256M,hotplug_method=acpi,hotplug_size=2G" \
    --serial tty \
    --console off \
    --cmdline "console=ttyS0,115200 modules=virtio_pci,virtio_blk,ext4 root=LABEL=alpine-root rootfstype=ext4 rw init=/sbin/init"
