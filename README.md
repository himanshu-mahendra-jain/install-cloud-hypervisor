# Cloud Hypervisor Unattended Installer

A secure, unattended installer for the latest stable [Cloud Hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) release on Debian 13 (Trixie) or newer, together with a small Alpine Linux VM demo.

The installer downloads the latest official Cloud Hypervisor static release, validates the downloaded ELF binary and host prerequisites, configures KVM access, prepares the system data directories, and installs Cloud Hypervisor system-wide.

The included demo script creates a persistent 100 MiB Alpine Linux root filesystem and boots it directly with Cloud Hypervisor using a custom Linux kernel built from the Cloud Hypervisor kernel configuration, together with a generated initramfs.

## Requirements

* Debian GNU/Linux 13 (Trixie) or newer
* Linux kernel 6.6 or newer
* x86_64 or aarch64
* Hardware virtualization enabled:
  * Intel VT-x
  * AMD-V
  * Nested KVM
* `/dev/kvm`
* `/dev/net/tun`
* Root privileges, or `sudo`

The installer checks the running kernel, CPU virtualization support on x86_64, `/dev/kvm`, and TUN/TAP availability before installation.

## What It Installs

The installer automatically installs missing Debian packages required by the installation process:

* `acl`
* `bc`
* `bison`
* `coreutils`
* `curl`
* `dwarves`
* `elfutils-dev`
* `file`
* `flex`
* `gcc`
* `git`
* `grep`
* `make`
* `nftables`
* `openssl-dev`
* `perl`
* `pkgconf`
* `tar`

It installs:

* Cloud Hypervisor

The official static release asset is selected according to the host architecture:

* `cloud-hypervisor` on x86_64
* `cloud-hypervisor-static-aarch64` on AArch64

## Installation

Make the installer executable and run it:

```bash
chmod +x install-cloud-hypervisor.sh
sudo ./install-cloud-hypervisor.sh
```

If executed as a non-root user and `sudo` is available, the installer automatically re-executes itself with root privileges.

Root privileges are required because the installer manages the system-wide Cloud Hypervisor binary, KVM permissions, udev rules, and system data directories.

## Installation Location

Cloud Hypervisor is installed system-wide under:

```text
/usr/local/bin/cloud-hypervisor
```

The binary is installed as:

```text
root:root
0755
```

It is therefore available through the normal system `PATH`.

Verify the installation with:

```bash
cloud-hypervisor --version
```

The installer also executes the installed binary as the detected target user when the installer was started from a non-root session.

## Cloud Hypervisor Data Directories

The installer creates the following hierarchy:

```text
/var/lib/cloud-hypervisor-data/
├── base/
├── instances/
└── snapshots/
```

The directories are:

```text
/var/lib/cloud-hypervisor-data
/var/lib/cloud-hypervisor-data/base
/var/lib/cloud-hypervisor-data/instances
/var/lib/cloud-hypervisor-data/snapshots
```

Permissions are:

```text
/var/lib/cloud-hypervisor-data             root:root  0755
/var/lib/cloud-hypervisor-data/base        root:root  0755
/var/lib/cloud-hypervisor-data/instances   root:root  0700
/var/lib/cloud-hypervisor-data/snapshots   root:root  0700
```

### Base Images

```text
/var/lib/cloud-hypervisor-data/base/
```

Intended for base VM images and other reusable VM assets.

### Instances

```text
/var/lib/cloud-hypervisor-data/instances/
```

Intended for VM-specific instance data.

### Snapshots

```text
/var/lib/cloud-hypervisor-data/snapshots/
```

Intended for VM snapshots.

## Target User

When run through `sudo`, the installer detects the initiating user using `SUDO_USER`.

The target user is used primarily for:

* KVM access configuration
* non-root Cloud Hypervisor execution testing

Cloud Hypervisor itself is installed system-wide and is not placed in the user's home directory.

## KVM Configuration

The installer verifies:

* CPU hardware virtualization on x86_64
* `/dev/kvm` exists
* `/dev/kvm` is a character device
* The target user can access `/dev/kvm`

It creates the `kvm` group if necessary and configures:

```text
/etc/udev/rules.d/99-kvm.rules
```

with:

```text
KERNEL=="kvm", GROUP="kvm", MODE="0660"
```

The target user is added to the `kvm` group.

The installer also attempts to grant the target user immediate read/write access to `/dev/kvm` with an ACL, avoiding the need for a new login session when the ACL is available.

## TUN/TAP Networking

The installer verifies:

```text
/dev/net/tun
```

If the device is missing, it attempts to load the `tun` kernel module.

Installation stops if TUN/TAP remains unavailable.

TUN/TAP support is required by the included Alpine demo because the demo creates a host TAP interface and attaches it to the VM.

## Release Download and Validation

The installer retrieves the latest stable Cloud Hypervisor release metadata from the official Cloud Hypervisor GitHub repository.

It then:

1. Determines the latest release tag.
2. Determines the host architecture.
3. Selects the architecture-specific official static release asset.
4. Downloads the release binary over HTTPS.
5. Verifies that the downloaded file is an ELF executable.
6. Verifies that its architecture matches the host.
7. Checks static linking with `ldd` when available.
8. Installs the validated binary system-wide.
9. Executes the installed binary and reports its version.

The installer does **not** use a SHA-256 checksum file because the installer source explicitly notes that Cloud Hypervisor's GitHub releases do not publish a SHA-256 checksum asset for the selected binary.

Therefore, the integrity checks performed by this installer are based on the official release asset URL, ELF/architecture validation, static-binary validation, and successful version execution.

## Supported Architectures

### x86_64

The installer checks `/proc/cpuinfo` for:

```text
vmx
svm
```

and requires:

```text
/dev/kvm
```

### aarch64

The installer supports the AArch64 Cloud Hypervisor static release asset:

```text
cloud-hypervisor-static-aarch64
```

The installer does not add a separate host-page-size check.

## Kernel Requirement

The installer requires Linux kernel 6.6 or newer.

The running kernel version is parsed and installation is aborted when it is below 6.6.

The installer also reports the Cloud Hypervisor upstream recommended host-kernel baseline of 5.13+, while retaining its own Debian 13 / kernel 6.6+ installation requirement.

## Re-running the Installer

The installer is designed to be re-run.

Each run:

1. Verifies the Debian host.
2. Installs missing dependencies.
3. Detects the host architecture.
4. Retrieves the latest stable Cloud Hypervisor release.
5. Validates the release binary.
6. Configures KVM permissions.
7. Installs the Cloud Hypervisor binary.
8. Ensures the system data directories exist.
9. Tests Cloud Hypervisor execution.

The installed binary remains:

```text
/usr/local/bin/cloud-hypervisor
```

## Alpine Linux Demo

The repository also includes:

```text
cloud-hypervisor-demo-alpine.sh
```

The demo creates and boots a real Alpine Linux VM using Cloud Hypervisor.

The demo is intentionally small and demonstrates:

* Direct kernel boot
* Initramfs boot
* A persistent ext4 root filesystem
* Virtio block storage
* Virtio networking
* TAP networking
* IPv4 NAT through the host
* Cloud Hypervisor's API socket
* Serial-console access
* No firmware
* CPU hotplug configuration
* Memory hotplug configuration

The demo uses Alpine Linux:

```text
Alpine 3.24.1
Architecture: x86_64
```

## Running the Demo

After Cloud Hypervisor has been installed:

```bash
chmod +x cloud-hypervisor-demo-alpine.sh
sudo ./cloud-hypervisor-demo-alpine.sh
```

The script automatically re-executes itself with `sudo` when necessary.

The VM runs in the foreground. Its serial console is attached to the terminal, so the terminal becomes the VM console while Cloud Hypervisor is running.

## Demo VM Layout

The demo stores its files under:

```text
/var/lib/cloud-hypervisor-data/test-alpine/
```

The important files are:

```text
/var/lib/cloud-hypervisor-data/test-alpine/
├── alpine-100m.raw
├── vmlinuz-cloud-hypervisor
├── initramfs-cloud-hypervisor
├── linux-cloud-hypervisor/
└── ch-alpine.sock
```

A temporary build directory is also used while generating the kernel/initramfs and is removed after the build completes.

The VM directory is restricted to mode `0700`.

## Alpine Root Filesystem

The demo downloads:

```text
alpine-minirootfs-3.24.1-x86_64.tar.gz
```

from the Alpine Linux CDN.

It downloads the corresponding `.sha256` file and verifies the minirootfs with:

```bash
sha256sum -c
```

The minirootfs is then extracted into a 100 MiB ext4 disk image.

The disk image is:

```text
/var/lib/cloud-hypervisor-data/test-alpine/alpine-100m.raw
```

It is created with:

```text
100 MiB
ext4
label: alpine-root
```

The filesystem is configured to mount itself as:

```text
LABEL=alpine-root / ext4 defaults 0 1
```

## Alpine Kernel and Initramfs

The demo no longer uses the Alpine `linux-virt` kernel. Instead, it builds a Linux kernel from the Cloud Hypervisor kernel configuration and uses that kernel for direct VM boot. This keeps the guest kernel configuration focused on the hardware and features required by the Cloud Hypervisor VM environment.

The Cloud Hypervisor kernel source is kept locally so subsequent builds can reuse the existing source tree and `.config` rather than cloning the kernel again.

The kernel build requires the host Linux build toolchain and kernel build dependencies. The resulting kernel is copied into the VM directory and used directly by Cloud Hypervisor.

The demo also generates an initramfs containing the required guest functionality, including virtio and ext4 support. This is important because the VM boots from an ext4 root filesystem using virtio storage.

The generated runtime files are:

```text
vmlinuz-cloud-hypervisor
initramfs-cloud-hypervisor
```

The kernel source/build tree is retained under the VM directory for incremental rebuilds. It can be removed manually after kernel development is complete, but doing so causes the next build to clone the source again.

The demo verifies that the generated initramfs contains `ext4.ko` when `lsinitramfs` is available.

## VM Configuration

Cloud Hypervisor is started with:

```text
CPU:
  boot=1
  max=4

Memory:
  initial=256 MiB
  hotplug=2 GiB

Disk:
  persistent 100 MiB ext4 image

Network:
  TAP interface
  192.168.100.0/24

Serial:
  tty

Console:
  disabled

Firmware:
  none
```

The kernel command line includes:

```text
console=ttyS0,115200
modules=virtio_pci,virtio_blk,ext4
root=LABEL=alpine-root
rootfstype=ext4
rw
init=/sbin/init
```

This is a direct kernel boot rather than a firmware-based boot.

## Demo Networking

The demo creates:

```text
tap0
```

with the host-side address:

```text
192.168.100.1/24
```

The Alpine VM configures:

```text
192.168.100.2/24
```

and uses:

```text
192.168.100.1
```

as its default gateway.

DNS is configured inside the VM as:

```text
1.1.1.1
8.8.8.8
```

The host enables IPv4 forwarding and configures an nftables NAT table named:

```text
ch_nat
```

The VM's traffic is masqueraded through the host's normal outbound interface.

The demo also disables strict reverse-path filtering for the relevant interfaces and attempts to disable TAP TX checksum offload when `ethtool` is available.

## Demo Root Account

The demo intentionally clears the Alpine root password:

```text
root::
```

This is suitable for a disposable local demonstration but **is not an appropriate configuration for a production VM**.

Do not expose the demo VM directly to an untrusted network without replacing this configuration with proper authentication and access controls.

## Demo Init and Console

The demo configures BusyBox as the VM init process:

```text
/sbin/init -> /bin/busybox
```

It creates a minimal `/etc/inittab` that:

* Remounts the root filesystem read/write
* Mounts `/proc`
* Mounts `/sys`
* Mounts `/dev`
* Mounts `/run`
* Sets the hostname
* Configures `eth0`
* Starts a shell on `ttyS0`
* Starts a shell on `tty1`

The VM hostname is:

```text
alpine-ch
```

The serial console is therefore the primary interactive console when the demo is running.

## Cloud Hypervisor API Socket

The demo creates its API socket at:

```text
/var/lib/cloud-hypervisor-data/test-alpine/ch-alpine.sock
```

The socket is passed to Cloud Hypervisor with:

```text
--api-socket
```

This makes the Cloud Hypervisor API available for VM management while the VM is running.

## Demo Persistence

The Alpine root filesystem is persistent.

The demo does not recreate the 100 MiB disk if it already exists. On subsequent runs, it detects the existing Alpine filesystem and reuses it.

The Cloud Hypervisor kernel and initramfs are regenerated by the demo when the build step runs. The kernel source tree is retained so subsequent builds can be incremental.

The VM therefore has persistent filesystem state across demo runs, while the Cloud Hypervisor VM process itself is recreated each time.

## Network and Host State

The demo creates or recreates:

```text
tap0
```

and replaces the nftables table:

```text
ch_nat
```

The TAP interface and nftables configuration are host networking state, not files stored inside the VM.

If the demo is stopped, inspect the host networking state with:

```bash
ip addr show tap0
sudo nft list table ip ch_nat
```

The demo script itself does not implement a final cleanup routine for the TAP interface or the `ch_nat` nftables table.

## Useful Verification Commands

Check Cloud Hypervisor:

```bash
cloud-hypervisor --version
```

Check KVM:

```bash
ls -l /dev/kvm
```

Check TUN/TAP:

```bash
ls -l /dev/net/tun
```

Check the demo TAP interface:

```bash
ip addr show tap0
```

Check the NAT rules:

```bash
sudo nft list table ip ch_nat
```

Check the demo directory:

```bash
sudo ls -la /var/lib/cloud-hypervisor-data/test-alpine/
```

## Safety and Failure Handling

Both scripts use:

```bash
set -euo pipefail
```

The installer aborts when required host validation or installation steps fail.

Examples include:

* Unsupported Debian version
* Unsupported architecture
* Kernel below 6.6
* Missing hardware virtualization
* Missing `/dev/kvm`
* Inaccessible `/dev/kvm`
* Missing `/dev/net/tun`
* Missing required package
* Invalid GitHub release metadata
* Missing official release asset
* Invalid downloaded ELF binary
* Architecture mismatch
* Failed Cloud Hypervisor execution

The Alpine demo also stops on failed downloads, failed checksum verification, invalid disk creation, failed filesystem setup, failed Alpine package installation, failed initramfs generation, missing KVM, or failed network setup.

## Project Files

The intended project layout is:

```text
.
├── README.md
├── install-cloud-hypervisor.sh
└── cloud-hypervisor-demo-alpine.sh
```

## Result

A successful installer reports information similar to:

```text
============================================================
 Cloud Hypervisor installed successfully
============================================================

Architecture     : x86_64
Version          : <version>
Kernel           : <kernel>
KVM Status       : verified (read/write access configured)
TUN/TAP          : verified
Binary           : /usr/local/bin/cloud-hypervisor
Data Directory   : /var/lib/cloud-hypervisor-data
Base Images      : /var/lib/cloud-hypervisor-data/base
Instances        : /var/lib/cloud-hypervisor-data/instances
Snapshots        : /var/lib/cloud-hypervisor-data/snapshots
```

## License

This installer is separate from the Cloud Hypervisor project.

Cloud Hypervisor is an independent open-source project. Refer to the upstream project for its licensing terms.

The source code for this project is licensed under the GNU General Public License v3.0 (GPLv3). See the LICENSE file for the full license terms.

If you fork or build upon this project, attribution to the original project is appreciated.
