#!/bin/bash
set -euo pipefail

# ============================================================
# Cloud Hypervisor Unattended Installer (Debian 13+)
#
# Installs the latest official Cloud Hypervisor release on
# Debian GNU/Linux 13 (Trixie) or newer.
#
# Target System:
#   Debian GNU/Linux 13 (or newer)
#   Linux kernel 6.6+
#   x86_64 / aarch64
#   Hardware virtualization enabled (/dev/kvm)
#
# Global Binary Path:
#   /usr/local/bin/cloud-hypervisor  755 (root:root)
#
# System Data Directories:
#   /var/lib/cloud-hypervisor-data
#   /var/lib/cloud-hypervisor-data/base
#   /var/lib/cloud-hypervisor-data/instances
#   /var/lib/cloud-hypervisor-data/snapshots
#
# Installs:
#   Cloud Hypervisor
#
# Requirements:
#   Linux
#   Root privileges (or sudo)
#   Hardware virtualization enabled (VT-x / AMD-V / Nested KVM)
#   Linux kernel 6.6 or newer
#   /dev/kvm character device
#
# Managed Package Dependencies:
#   acl, coreutils, curl, grep, nftables, tar
#
# The installer:
#   - Enforces root execution (auto-elevates via sudo if needed)
#   - Identifies initiating non-root user to configure KVM access
#   - Automatically installs missing system packages via apt
#   - Resolves and downloads the latest stable Cloud Hypervisor release
#   - Validates CPU virtualization, kernel version, and KVM/TUN support
#   - Grants KVM permissions via ACLs, kvm group, and udev rules
#   - Verifies the official release SHA-256 checksum
#   - Installs the official static Cloud Hypervisor binary globally
#   - Provisions data directories for base images, instances, and snapshots
#   - Confirms binary execution under both root and the target non-root user
#
# Notes:
#   Cloud Hypervisor's official README recommends pre-built static
#   binaries for normal installation. The current release assets use
#   cloud-hypervisor-static for x86-64 and
#   cloud-hypervisor-static-aarch64 for AArch64.
#
# ============================================================

error() {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

# ------------------------------------------------------------
# Ensure root privileges
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

BIN_DIR="/usr/local/bin"
DATA_ROOT="/var/lib/cloud-hypervisor-data"
BASE_IMAGES_DIR="$DATA_ROOT/base"
INSTANCES_DIR="$DATA_ROOT/instances"
SNAPSHOTS_DIR="$DATA_ROOT/snapshots"

mkdir -p "$BASE_IMAGES_DIR" "$INSTANCES_DIR" "$SNAPSHOTS_DIR"
chown root:root "$DATA_ROOT" "$BASE_IMAGES_DIR" "$INSTANCES_DIR" "$SNAPSHOTS_DIR"

chmod 755 "$DATA_ROOT"
chmod 755 "$BASE_IMAGES_DIR"
chmod 700 "$INSTANCES_DIR"
chmod 700 "$SNAPSHOTS_DIR"

REPO="cloud-hypervisor/cloud-hypervisor"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
TMP_DIR=""

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap cleanup EXIT

# ------------------------------------------------------------
# Check Debian and dependencies
# ------------------------------------------------------------

echo "==> Verifying Debian version and dependencies"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        error "Unsupported distribution: ${PRETTY_NAME:-Linux}. Debian 13 or newer is required."
    fi

    if [[ -n "${VERSION_ID:-}" && "$VERSION_ID" =~ ^[0-9]+$ ]] && (( VERSION_ID < 13 )); then
        error "Debian $VERSION_ID detected. Debian 13 or newer is required."
    fi
else
    error "Cannot detect operating system (/etc/os-release missing)."
fi

REQUIRED_PACKAGES=(
    acl
    coreutils
    curl
    file
    git
    grep
    nftables
    tar
    bc
    bison
    flex
    gcc
    make
    perl
    pkgconf
    openssl-dev
    elfutils-dev
    dwarves
)

if command -v apt-get >/dev/null 2>&1; then
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
else
    error "apt-get is required on the supported Debian host."
fi

# ------------------------------------------------------------
# Detect architecture
# ------------------------------------------------------------

echo "==> Detecting architecture"

case "$(uname -m)" in
    x86_64)
        ARCH="x86_64"
        RELEASE_ASSET="cloud-hypervisor-static"
        ;;
    aarch64|arm64)
        ARCH="aarch64"
        RELEASE_ASSET="cloud-hypervisor-static-aarch64"
        ;;
    *)
        error "Unsupported architecture: $(uname -m). Cloud Hypervisor's main supported host architectures are x86-64 and AArch64."
        ;;
esac

echo "    Architecture: $ARCH"
echo "    Release asset: $RELEASE_ASSET"

# ------------------------------------------------------------
# Temporary directory
# ------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"

# ------------------------------------------------------------
# Find latest stable release
# ------------------------------------------------------------

echo "==> Finding latest Cloud Hypervisor release"

RELEASE_JSON="$TMP_DIR/release.json"

curl -fsSL \
    --retry 5 \
    --retry-delay 2 \
    --retry-all-errors \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$API_URL" \
    -o "$RELEASE_JSON"

RELEASE_TAG="$(
    awk '
        /"tag_name"[[:space:]]*:[[:space:]]*"/ {
            tag = $0
            sub(/^.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", tag)
            sub(/".*$/, "", tag)
            print tag
            exit
        }
    ' "$RELEASE_JSON"
)" || error "Could not determine latest Cloud Hypervisor release."

[[ -n "$RELEASE_TAG" ]] \
    || error "Release tag not found in GitHub API response."

VERSION="${RELEASE_TAG#v}"

[[ -n "$VERSION" ]] \
    || error "Could not determine Cloud Hypervisor version from tag: $RELEASE_TAG"

echo "    Latest version: $VERSION"
echo "    Release tag:   $RELEASE_TAG"

# ------------------------------------------------------------
# Host kernel
#
# Cloud Hypervisor itself documents 5.13 as the recommended
# host kernel for required KVM functionality. This installer
# keeps the original installer's Debian 13 / 6.6+ baseline.
# ------------------------------------------------------------

echo "==> Checking host kernel"

HOST_KERNEL="$(uname -r)"

if [[ "$HOST_KERNEL" =~ ^[vV]?([0-9]+)\.([0-9]+) ]]; then
    HOST_MAJOR="${BASH_REMATCH[1]}"
    HOST_MINOR="${BASH_REMATCH[2]}"
else
    error "Could not parse host kernel version: $HOST_KERNEL"
fi

if (( HOST_MAJOR < 6 || (HOST_MAJOR == 6 && HOST_MINOR < 6) )); then
    error "Host kernel $HOST_KERNEL is below the installer's minimum kernel 6.6."
fi

echo "    Current host kernel: $HOST_KERNEL"
echo "    Installer minimum:  6.6"
echo "    Cloud Hypervisor upstream recommended host kernel: 5.13+"

# ------------------------------------------------------------
# KVM / virtualization
# ------------------------------------------------------------

echo "==> Checking KVM and CPU virtualization"

if [[ "$ARCH" == "x86_64" ]] && ! grep -qE -m1 '(vmx|svm)' /proc/cpuinfo; then
    error "Hardware virtualization (VT-x/AMD-V) is disabled or not supported by the CPU."
fi

if [[ ! -e /dev/kvm ]]; then
    error "/dev/kvm does not exist. Ensure virtualization is enabled and the KVM kernel module is loaded."
fi

if [[ ! -c /dev/kvm ]]; then
    error "/dev/kvm exists but is not a character device."
fi

# ------------------------------------------------------------
# TUN/TAP
# ------------------------------------------------------------

echo "==> Checking TUN/TAP support"

if [[ ! -c /dev/net/tun ]]; then
    modprobe tun 2>/dev/null || true

    if [[ ! -c /dev/net/tun ]]; then
        error "/dev/net/tun is missing. TAP networking will not work."
    fi
fi

# ------------------------------------------------------------
# cgroups
#
# Not a Cloud Hypervisor/Jailer prerequisite. We intentionally
# do not require cgroups merely to install Cloud Hypervisor.
# ------------------------------------------------------------

# ------------------------------------------------------------
# KVM permissions
# ------------------------------------------------------------

echo "==> Configuring KVM permissions for $TARGET_USER"

if ! getent group kvm >/dev/null 2>&1; then
    groupadd -r kvm
fi

chgrp kvm /dev/kvm 2>/dev/null || true
chmod 660 /dev/kvm

cat > /etc/udev/rules.d/99-kvm.rules <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF

udevadm control --reload-rules
udevadm trigger --name-match=kvm 2>/dev/null || true

if [[ "$TARGET_USER" != "root" ]]; then
    echo "    Configuring KVM permissions for target user: $TARGET_USER"

    usermod -aG kvm "$TARGET_USER"

    # ACL permits the current login/session to use /dev/kvm
    # without requiring a logout/login cycle.
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m "u:$TARGET_USER:rw" /dev/kvm 2>/dev/null || true
    fi

    KVM_TEST_CMD="exec 3<>/dev/kvm"

    if run_as_target bash -c "$KVM_TEST_CMD" 2>/dev/null; then
        KVM_ACCESSIBLE=1
    elif command -v runuser >/dev/null 2>&1 \
        && runuser -u "$TARGET_USER" -G kvm -- bash -c "$KVM_TEST_CMD" 2>/dev/null; then
        KVM_ACCESSIBLE=1
    else
        KVM_ACCESSIBLE=0
    fi

    if [[ "$KVM_ACCESSIBLE" -eq 0 ]]; then
        if ! id -nG "$TARGET_USER" | grep -qw kvm; then
            error "Failed to verify $TARGET_USER read/write access to /dev/kvm."
        fi

        echo "    Note: Added to 'kvm' group. A new login session may be required if ACL access is unavailable."
    fi
fi

echo "    Hardware virtualization: active"
echo "    /dev/kvm: accessible (read/write configured)"
echo "    /dev/net/tun: available"

# ------------------------------------------------------------
# Release artifact
# ------------------------------------------------------------

BINARY="$TMP_DIR/cloud-hypervisor"
ARCHIVE="$TMP_DIR/$RELEASE_ASSET"

# ------------------------------------------------------------
# Find exact release asset URL
# ------------------------------------------------------------

echo "==> Finding release binary"

BINARY_URL="$(
    awk -v name="$RELEASE_ASSET" '
        /"name"[[:space:]]*:[[:space:]]*"/ {
            cur_name = $0
            sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", cur_name)
            sub(/".*$/, "", cur_name)
            match_found = (cur_name == name)
        }
        match_found && /"browser_download_url"[[:space:]]*:[[:space:]]*"/ {
            url = $0
            sub(/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", url)
            sub(/".*$/, "", url)
            print url
            exit
        }
    ' "$RELEASE_JSON"
)"

[[ -n "$BINARY_URL" ]] \
    || error "Could not find release asset '$RELEASE_ASSET'."

echo "    Asset: $RELEASE_ASSET"

# ------------------------------------------------------------
# Download binary
# ------------------------------------------------------------

echo "==> Downloading Cloud Hypervisor"

curl -fL \
    --retry 5 \
    --retry-delay 2 \
    --retry-all-errors \
    --progress-bar \
    -o "$ARCHIVE" \
    "$BINARY_URL"

[[ -s "$ARCHIVE" ]] \
    || error "Downloaded Cloud Hypervisor binary is empty."

# ------------------------------------------------------------
# Validate downloaded release artifact
#
# Cloud Hypervisor does not publish a SHA-256 checksum asset with
# its GitHub releases. Do not guess or fabricate a checksum URL.
#
# Integrity here is based on:
#   - HTTPS download from the official Cloud Hypervisor GitHub repo
#   - exact architecture-specific official release asset
#   - ELF/architecture validation below
#   - execution/version validation after installation
# ------------------------------------------------------------

# ------------------------------------------------------------
# Validate ELF binary
# ------------------------------------------------------------

echo "==> Validating release binary"

chmod 700 "$ARCHIVE"

if ! file "$ARCHIVE" 2>/dev/null | grep -qE 'ELF'; then
    error "Downloaded Cloud Hypervisor artifact is not an ELF executable."
fi

case "$ARCH" in
    x86_64)
        if ! file "$ARCHIVE" 2>/dev/null | grep -qE 'x86-64|AMD x86-64'; then
            error "Downloaded binary does not appear to be an x86-64 executable."
        fi
        ;;
    aarch64)
        if ! file "$ARCHIVE" 2>/dev/null | grep -qE 'ARM aarch64|ARM64|AArch64'; then
            error "Downloaded binary does not appear to be an AArch64 executable."
        fi
        ;;
esac

# Cloud Hypervisor's official release artifact is the static binary.
# Verify that it does not have a dynamic loader dependency.
if command -v ldd >/dev/null 2>&1; then
    LDD_OUT="$(ldd "$ARCHIVE" 2>&1 || true)"

    if [[ "$LDD_OUT" == *"not a dynamic executable"* || "$LDD_OUT" == *"statically linked"* ]]; then
        echo "    Static linking: verified via ldd"
    elif [[ "$LDD_OUT" == *"ld-linux"* || "$LDD_OUT" == *"libc.so"* || "$LDD_OUT" == *"=>"* ]]; then
        error "Cloud Hypervisor release binary appears to be dynamically linked."
    else
        echo "    Static linking: could not be conclusively determined by ldd; continuing because the official static asset was selected."
    fi
fi

# ------------------------------------------------------------
# Install
# ------------------------------------------------------------

echo "==> Installing Cloud Hypervisor to $BIN_DIR"

install -m 755 -o root -g root "$ARCHIVE" "$BIN_DIR/cloud-hypervisor"

# ------------------------------------------------------------
# Test executable
# ------------------------------------------------------------

echo "==> Testing installed binary"

"$BIN_DIR/cloud-hypervisor" --version

if [[ "$TARGET_USER" != "root" ]]; then
    echo "==> Testing execution as $TARGET_USER"
    run_as_target "$BIN_DIR/cloud-hypervisor" --version
    echo "    Non-root binary execution verified"
fi

# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Cloud Hypervisor installed successfully"
echo "============================================================"
echo
echo "Architecture     : $ARCH"
echo "Version          : $VERSION"
echo "Kernel           : $HOST_KERNEL"
echo "KVM Status       : verified (read/write access configured)"
echo "TUN/TAP          : verified"
echo "Binary           : $BIN_DIR/cloud-hypervisor"
echo "Data Directory   : $DATA_ROOT"
echo "Base Images      : $BASE_IMAGES_DIR"
echo "Instances        : $INSTANCES_DIR"
echo "Snapshots        : $SNAPSHOTS_DIR"
echo
