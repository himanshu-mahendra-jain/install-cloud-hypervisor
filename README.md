# Cloud Hypervisor Unattended Installer

A secure, unattended installer for the latest stable [Cloud Hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) release on the latest Debian and Debian derivatives such as Ubuntu, together with a small Alpine Linux VM demo.

The installer downloads the latest official Cloud Hypervisor static release, validates the ELF binary and host prerequisites, configures KVM access, prepares system data directories, and installs Cloud Hypervisor system-wide. The demo script creates a persistent 100 MiB Alpine Linux root filesystem and boots it directly with Cloud Hypervisor, using a kernel built from the Cloud Hypervisor Linux tree.

## Requirements

* The latest Debian or a Debian derivative (e.g. Ubuntu) with `apt-get`, x86_64 or aarch64
* Hardware virtualization enabled (Intel VT-x, AMD-V, or nested KVM)
* `/dev/kvm`, `/dev/net/tun`, and root privileges or `sudo`

The installer accepts any distribution whose `/etc/os-release` has `ID=debian` or `debian` in `ID_LIKE`. It checks CPU virtualization support on x86_64, `/dev/kvm`, and TUN/TAP availability before installation.

## What It Installs

The installer installs only the packages it needs, when missing: `acl`, `ca-certificates`, `curl`, `file`. The demo installs its own kernel build and networking dependencies (see below).

Cloud Hypervisor itself is installed from the official static release asset for the host architecture: `cloud-hypervisor-static` on x86_64 (requires `vmx` or `svm` in `/proc/cpuinfo` and `/dev/kvm`) or `cloud-hypervisor-static-aarch64` on AArch64 (no separate host-page-size check).

## Installation

```bash
chmod +x install-cloud-hypervisor.sh
sudo ./install-cloud-hypervisor.sh
```

If run as a non-root user with `sudo` available, the installer re-executes itself as root. Root is required to manage the system-wide binary, KVM permissions, udev rules, and data directories.

The binary is installed to `/usr/local/bin/cloud-hypervisor` (`root:root`, `0755`), so it is on the normal `PATH`. Verify with `cloud-hypervisor --version`. When started from a non-root session, the installer also runs the installed binary as the detected target user.

The installer is safe to re-run. Each run verifies the Debian-based host, installs missing dependencies, detects the architecture, looks up the latest stable release, configures KVM permissions, ensures the data directories exist, and tests execution. The binary is downloaded and replaced only when a newer release exists (`FORCE=1` reinstalls anyway); the new binary is swapped in atomically. Set `GITHUB_TOKEN` to avoid GitHub API rate limits.

## Data Directories

```text
/var/lib/cloud-hypervisor-data/   root:root 0755
├── base/                         root:root 0755   base VM images and reusable assets
├── instances/                    root:root 0700   VM-specific instance data
└── snapshots/                    root:root 0700   VM snapshots
```

## Target User and KVM

When run through `sudo`, the target user is detected from `SUDO_USER`. It is used for KVM access configuration and non-root execution testing; Cloud Hypervisor is never placed in the user's home directory.

The installer verifies CPU virtualization (x86_64), that `/dev/kvm` exists, is a character device, and is accessible to the target user. It creates the `kvm` group if needed, adds the target user to it, and writes `/etc/udev/rules.d/99-kvm.rules`:

```text
KERNEL=="kvm", GROUP="kvm", MODE="0660"
```

It also attempts to grant the user immediate read/write access to `/dev/kvm` via an ACL, avoiding the need for a new login session.

## TUN/TAP

If `/dev/net/tun` is missing, the installer tries to load the `tun` module and stops if TUN/TAP remains unavailable. It is required by the demo, which attaches a host TAP interface to the VM.

## Release Download and Validation

The installer fetches the latest stable release metadata from the official GitHub repository, determines the release tag and host architecture, selects the matching static asset, and downloads it over HTTPS. It then verifies the file is an ELF executable for the host architecture, checks static linking with `ldd` when available, installs it, and runs it to report the version.

No SHA-256 check is performed because Cloud Hypervisor's GitHub releases do not publish a checksum asset for the selected binary. Integrity therefore relies on the official asset URL, ELF/architecture validation, static-binary validation, and successful version execution.

## Alpine Linux Demo

`cloud-hypervisor-demo-alpine.sh` creates and boots a real Alpine Linux VM (x86_64 hosts only) using the latest stable Alpine release. It demonstrates direct kernel boot without firmware, a persistent ext4 root filesystem, virtio block and network devices, TAP networking with IPv4 NAT through the host, the API socket, serial-console access, and CPU and memory hotplug configuration.

```bash
chmod +x cloud-hypervisor-demo-alpine.sh
sudo ./cloud-hypervisor-demo-alpine.sh
```

The script re-executes itself with `sudo` when necessary and installs missing packages (`e2fsprogs`, `iproute2`, `nftables`, `git`, `gcc`, `make`, `libc6-dev`, `bc`, `bison`, `flex`, `perl`, `pkgconf`, `libssl-dev`, `libelf-dev`, `dwarves`, and others). Only one instance can run at a time. The VM runs in the foreground with its serial console attached to the terminal; run `poweroff` inside the VM to stop it. Files live under a `0700` directory:

```text
/var/lib/cloud-hypervisor-data/test-alpine/
├── alpine-100m.raw              persistent 100 MiB ext4 root disk (label alpine-root)
├── vmlinux                      guest kernel
├── vmlinux.ref                  kernel release tag the guest kernel was built from
├── linux-cloud-hypervisor/      retained kernel source/build tree
└── ch-alpine.sock               API socket (passed via --api-socket)
```

**Root filesystem.** On first run the demo reads the Alpine CDN's `latest-stable` release index to find the newest minirootfs, downloads it and its `.sha256` to a temporary directory, verifies it with `sha256sum -c`, and extracts it into the ext4 image, mounted via `LABEL=alpine-root / ext4 defaults 0 1`. An existing disk is detected and reused without downloading anything, so filesystem state persists across runs while the VM process is recreated each time. The `apk` repositories always match the installed Alpine release.

**Kernel.** Instead of Alpine's `linux-virt`, the demo builds a kernel from the newest `ch-release-v*` tag of the [Cloud Hypervisor Linux tree](https://github.com/cloud-hypervisor/linux) using `ch_defconfig`, and checks that virtio PCI, block, net, and ext4 are built in, so no initramfs is needed. Each run checks for a newer tag: the kernel is rebuilt only when one exists, reusing the retained source tree for incremental builds.

**VM configuration.** CPU boot=1, max=4; memory 256 MiB initial with 2 GiB hotplug; the 100 MiB disk; a TAP interface on 192.168.100.0/24; serial on tty; console disabled; no firmware. Kernel command line:

```text
console=ttyS0,115200 root=/dev/vda rootfstype=ext4 rw init=/sbin/init
```

**Networking.** The host creates `tap0` at `192.168.100.1/24`; the VM uses `192.168.100.2/24` with gateway `192.168.100.1` and DNS `1.1.1.1` and `8.8.8.8`. The host enables IPv4 forwarding and replaces an nftables table `ch_nat` that masquerades VM traffic through the normal outbound interface. It also disables strict reverse-path filtering on the relevant interfaces and tries to disable TAP TX checksum offload when `ethtool` is available. When the VM exits (or the script is interrupted), `tap0` and `ch_nat` are removed and the forwarding and reverse-path-filter settings are restored to their previous values. While the VM runs, inspect them with `ip addr show tap0` and `sudo nft list table ip ch_nat`.

**Init and console.** BusyBox is the init (`/sbin/init -> /bin/busybox`). A minimal `/etc/inittab` remounts root read/write, mounts `/proc`, `/sys`, `/dev`, and `/run`, sets hostname `alpine-ch`, configures `eth0`, and starts shells on `ttyS0` (the primary console) and `tty1`.

**Root account.** The demo intentionally clears the root password (`root::`). This suits a disposable local demo but **is not appropriate for a production VM**. Do not expose the VM to an untrusted network without proper authentication and access controls.

## Useful Verification Commands

```bash
cloud-hypervisor --version                               # Cloud Hypervisor
ls -l /dev/kvm                                           # KVM
ls -l /dev/net/tun                                       # TUN/TAP
ip addr show tap0                                        # demo TAP interface
sudo nft list table ip ch_nat                            # NAT rules
sudo ls -la /var/lib/cloud-hypervisor-data/test-alpine/  # demo directory
```

## Safety and Failure Handling

Both scripts use `set -euo pipefail`. The installer aborts on an unsupported distribution or architecture, missing hardware virtualization, missing or inaccessible `/dev/kvm`, missing `/dev/net/tun`, a missing required package, invalid GitHub release metadata, a missing release asset, an invalid ELF binary, an architecture mismatch, or failed Cloud Hypervisor execution.

The demo stops on a non-x86_64 host, another running instance, failed downloads or release lookups, checksum verification, disk creation, filesystem setup, package installation, or kernel build, and on KVM being inaccessible to the target user or failed network setup.

## Project Files

```text
.
├── README.md
├── install-cloud-hypervisor.sh
└── cloud-hypervisor-demo-alpine.sh
```

## Result

A successful installation reports something like:

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

This installer is separate from the Cloud Hypervisor project, an independent open-source project; refer to upstream for its licensing terms.

This project is licensed under the [MIT License](LICENSE).
