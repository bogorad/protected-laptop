## owtest: NixOS VLAN Testing Environment with OpenWrt VM

This document explains the architecture, files, build/deploy steps, and troubleshooting for the "owtest" VLAN testing environment. It is intended for humans and LLMs to quickly get the full context.

### High-level overview

- **Proxmox** (spino.bruc) hosts VM 204 named "owtest" running NixOS
- **NixOS host** runs libvirt/qemu with an OpenWrt guest named "owtest-openwrt"
- **Single bridge** (br0) at 10.77.0.2/24 connects host and OpenWrt VM
- **VLAN trunking** on single interface provides 6 isolated networks (VLANs 1, 10, 11, 12, 13, 99)
- **External UCI configuration** approach for flexible VLAN management
- **Immutable base image** with ephemeral qcow2 overlay for clean testing iterations

ASCII diagram:

Proxmox (spino.bruc)
└─ VM 204: NixOS (host "owtest")
├─ ens18 (DHCP on upstream, 192.168.11.50)
└─ br0 (10.77.0.2/24) ── vnet0 ──────────────┐
│
OpenWrt VM (owtest-openwrt) │
└─ eth0 (MAC 0e:00:00:00:ee:00) → br0 ───────┘
├─ VLAN 1 (untagged): 10.77.0.1/24
├─ VLAN 10: 10.77.10.1/24
├─ VLAN 11: 10.77.11.1/24
├─ VLAN 12: 10.77.12.1/24
├─ VLAN 13: 10.77.13.1/24
└─ VLAN 99: 10.77.99.1/24

### Key properties

- No libvirt default network (virbr0) is used; the single NIC is attached to host bridge br0.
- OpenWrt uses VLAN trunking on a single interface to provide multiple isolated networks.
- Each VLAN has its own subnet (10.77.x.0/24) with OpenWrt as the gateway (.1).
- Host has static IP on br0, so you can reach OpenWrt's default VLAN at 10.77.0.1 from the host.

---

## Code layout

- **Host module and assets**
  - `default.nix` — Streamlined NixOS config
  - `disk-config-owtest.nix` — Disk partitioning configuration for disko
  - `owtest-openwrt.xml` — libvirt domain XML template with overlay path substitution
  - `rebuild-owtest-enhanced.sh` — Complete Proxmox VM creation and deployment script
  - `ow-config.uci` — External OpenWrt UCI configuration for setup (VLAN & more)
- **OpenWrt image definition**
  - `../images/openwrt-vm/my-x86-ow.nix` — ImageBuilder parameters and base configuration

Small excerpts (see files for full content):

- Domain XML with single NIC and MAC
  <augment_code_snippet path="nx-ago-testing/hosts/owtest/owtest-openwrt.xml" mode="EXCERPT">

```xml
<interface type='bridge'>
  <mac address='0e:00:00:00:ee:00'/>
  <source bridge='br0'/>
</interface>
```

</augment_code_snippet>

- Host installs XML and defines/starts the domain
  <augment_code_snippet path="nx-ago-testing/hosts/owtest/default.nix" mode="EXCERPT">

```nix
environment.etc."libvirt/qemu/owtest-openwrt.xml".text =
  builtins.replaceStrings [ "@OVERLAY@" ] [ overlayPath ]
    (builtins.readFile ./owtest-openwrt.xml);
```

</augment_code_snippet>

- **External UCI configuration approach**
  <augment_code_snippet path="hosts/owtest/ow-config.uci" mode="EXCERPT">

```uci
# Bridge device with VLAN filtering
set network.br_lan=device
set network.br_lan.name='br-lan'
set network.br_lan.type='bridge'
add_list network.br_lan.ports='eth0'

# VLAN 1 (untagged default)
set network.vlan1_bv=bridge-vlan
set network.vlan1_bv.device='br-lan'
set network.vlan1_bv.vlan='1'
add_list network.vlan1_bv.ports='eth0:u*'

# Tagged VLANs (10, 11, 12, 13, 99)
set network.vlan10_bv=bridge-vlan
set network.vlan10_bv.device='br-lan'
set network.vlan10_bv.vlan='10'
add_list network.vlan10_bv.ports='eth0:t'
# ... complete configuration in ow-config.uci
```

</augment_code_snippet>

---

## Networking design

- Host bridge (systemd-networkd):
  - br0: 10.77.0.2/24 (single bridge for all VLANs)
- OpenWrt guest:
  - eth0 (virtio on br0) → VLAN trunk with multiple networks:
    - VLAN 1 (untagged): 10.77.0.1/24 (default LAN)
    - VLAN 10: 10.77.10.1/24
    - VLAN 11: 10.77.11.1/24
    - VLAN 12: 10.77.12.1/24
    - VLAN 13: 10.77.13.1/24
    - VLAN 99: 10.77.99.1/24
- DHCP: enabled by OpenWrt for all VLAN networks
- MAC convention:
  - eth0: 0e:00:00:00:ee:00 (single interface for all VLANs)
  - This locally administered MAC must be consistent between the libvirt XML and the OpenWrt image UCI defaults.

Why VLAN trunking instead of multiple bridges?

- Simplifies host configuration while providing network isolation
- Single NIC handles multiple networks through VLAN tagging
- More realistic simulation of enterprise network setups

Why not virbr0?

- libvirt's default NAT network (virbr0) doesn't exist or isn't desired here; we want the guest NIC on a real host bridge with explicit addressing for predictable routing and testing.

---

## Storage model for the OpenWrt guest

- Base immutable raw image derived from the built OpenWrt artifact (gz or raw) is produced into the Nix store (openwrt-base.img).
- At runtime, an ephemeral qcow2 overlay is created in /run/openwrt/owtest-openwrt.qcow2 referencing the store base (copy-on-write).
- On boot, a oneshot service ensures the overlay exists before defining the domain.

Pros:

- No mutation of the base image; clean reboots; fast rebuilds.
- Overlay lives under /run (tmpfs) → ephemeral by design.

---

## Host services and libvirt management

**Service Architecture:**

- **Direct libvirt management**
- **Streamlined service chain** with proper dependencies
- **External UCI configuration** for flexible VLAN management

**Key Services:**

1. **prepare-owtest-overlay** — Creates qcow2 overlay referencing immutable base image
2. **owtest-define-openwrt** — Manages libvirt domain (undefine/define/autostart/start)
3. **ow-config-deploy** — Deploys external UCI configuration via SSH/SCP
4. **clone-nix-config** — Clones repository for system management (runs as root)

**Configuration:**

- Bridge whitelist: `virtualisation.libvirtd.allowedBridges = [ "br0" ]`
- XML template with overlay path substitution at activation
- External UCI file approach eliminates embedded configuration complexity

---

## OpenWrt image build (Nix)

- Defined in nx-ago-testing/images/openwrt-vm/my-x86-ow.nix using a "build" function that wraps OpenWrt ImageBuilder.
- Important details:
  - release = "24.10.3"; target = x86_64 generic
  - SSH authorized_keys preloaded to /etc/dropbear/authorized_keys from GitHub user keys
  - UCI defaults create basic network configuration; VLAN setup is applied post-boot via ow-mini-deploy service

The flake exports a package used by the host module to locate the combined image artifacts (gz or raw) and derive the base raw.

---

## Build and deploy workflow

### Method 1: Complete VM Rebuild (Full Deployment)

**Script:** `rebuild-owtest-enhanced.sh`

```bash
./hosts/owtest/rebuild-owtest-enhanced.sh
```

**What it does:**

- Destroys and recreates VM 204 on Proxmox with fresh disk
- Installs NixOS using nixos-anywhere with flake `#owtest`
- Waits for services to complete with enhanced diagnostics
- Verifies VLAN interfaces and connectivity
- Provides comprehensive status reporting

**Requirements:**

- `just`, `ssh`, `nc`, `nix` with flakes
- Justfile target `ssr` for remote command execution
- Access to Proxmox host (spino.bruc)

### Method 2: Configuration Updates (Recommended for Development)

**Remote rebuild from local machine:**

```bash
nixos-rebuild switch --flake .#owtest --target-host root@192.168.11.50
```

**Benefits:**

- ✅ Fast iteration (builds locally, deploys remotely)
- ✅ Uses current local changes (even uncommitted)
- ✅ No dependency on remote git repository
- ✅ Standard NixOS deployment mechanism

### Automatic OpenWrt Setup

**On system activation:**

1. **prepare-owtest-overlay** → Creates `/run/openwrt/owtest-openwrt.qcow2`
2. **owtest-define-openwrt** → Defines and starts libvirt domain
3. **ow-config-deploy** → Applies external UCI configuration via SSH/SCP
4. **Enhanced diagnostics** → Verifies VLAN interfaces and connectivity

**Verification:**

- All 6 VLAN interfaces should be UP with correct IP addresses
- Default VLAN (10.77.0.1) should be reachable from host
- Other VLANs properly isolated (10.77.10.1, 10.77.11.1, etc.)

---

## Customization guide

### VLAN Configuration (Most Common)

```bash
# Edit external UCI configuration
vim hosts/owtest/ow-config.uci

# Deploy changes
nixos-rebuild switch --flake .#owtest --target-host root@192.168.11.50
```

### Other Customizations

- **OpenWrt packages/base config:** Edit `../images/openwrt-vm/my-x86-ow.nix`
- **Host bridge addressing:** Modify `systemd.network.networks` in `default.nix`
- **VM hardware/MAC:** Update `owtest-openwrt.xml` (ensure MAC consistency)
- **Service behavior:** Adjust systemd services in `default.nix`

### Development Workflow

1. Make changes to configuration files
2. Test with `nixos-rebuild switch --flake .#owtest --target-host root@192.168.11.50`
3. Verify VLAN interfaces with enhanced diagnostics
4. Iterate quickly without full VM rebuilds

---

## Troubleshooting

### Service Issues

```bash
# Check service status
ssh root@192.168.11.50 'systemctl --failed'

# Check specific service logs
ssh root@192.168.11.50 'journalctl -u ow-config-deploy.service -n 50'
ssh root@192.168.11.50 'journalctl -u owtest-define-openwrt.service -n 50'
```

### VLAN Configuration Issues

```bash
# Verify VLAN interfaces on OpenWrt
ssh root@192.168.11.50 'ssh root@10.77.0.1 "ip a | grep br-lan"'

# Check UCI configuration
ssh root@192.168.11.50 'ssh root@10.77.0.1 "uci show network | grep -E \"(vlan|bridge)\""'

# Manual UCI deployment
scp hosts/owtest/ow-config.uci root@192.168.11.50:/tmp/
ssh root@192.168.11.50 'scp /tmp/ow-config.uci root@10.77.0.1:/tmp/ && ssh root@10.77.0.1 "uci batch < /tmp/ow-config.uci && /etc/init.d/network restart"'
```

### Network Connectivity

```bash
# Test VLAN connectivity
ssh root@192.168.11.50 'ping -c 2 10.77.0.1'   # Default VLAN
ssh root@192.168.11.50 'ping -c 2 10.77.10.1'  # VLAN 10 (should timeout - isolated)

# Check bridge and interfaces
ssh root@192.168.11.50 'ip link show master br0'
ssh root@192.168.11.50 'virsh domiflist owtest-openwrt'
```

---

## Quick verification commands

### Enhanced Diagnostics (Built-in)

The rebuild script includes comprehensive diagnostics that automatically verify:

- All 6 VLAN interfaces are UP with correct IP addresses
- UCI configuration is properly applied
- Network connectivity tests for each VLAN
- Service status and system health

### Manual Verification

```bash
# System status
ssh root@192.168.11.50 'hostnamectl && ip -o addr show'

# OpenWrt VM status
ssh root@192.168.11.50 'virsh dominfo owtest-openwrt && virsh domiflist owtest-openwrt'

# VLAN interface verification
ssh root@192.168.11.50 'ssh root@10.77.0.1 "ip a | grep br-lan"'

# Connectivity tests
ssh root@192.168.11.50 'ping -c 2 10.77.0.1'    # Default VLAN (should work)
ssh root@192.168.11.50 'ping -c 2 10.77.10.1'   # VLAN 10 (should timeout - isolated)

# OpenWrt system info
ssh root@192.168.11.50 'ssh root@10.77.0.1 "ubus call system board"'
```

---

## Maintenance & Updates

### VLAN Configuration Updates

```bash
# Edit UCI configuration
vim hosts/owtest/ow-config.uci

# Deploy changes (fast)
nixos-rebuild switch --flake .#owtest --target-host root@192.168.11.50
```

### System Updates

- **OpenWrt release:** Update `../images/openwrt-vm/my-x86-ow.nix`
- **Host services:** Modify `default.nix` systemd services
- **Network addressing:** Adjust bridge configuration in `default.nix`

### Development Cycle

1. **Edit** configuration files locally
2. **Deploy** with `nixos-rebuild --target-host`
3. **Verify** with built-in diagnostics
4. **Iterate** quickly without full VM rebuilds

This environment provides a robust, maintainable platform for VLAN testing and network configuration development.
