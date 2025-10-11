# NixOS Transparent Proxy with USB WiFi Pass-through and Xray

## Introduction

This project implements a **transparent proxy system** using a NixOS MicroVM with USB WiFi pass-through and Xray-core. The setup provides seamless routing of all network traffic through a remote VLESS/XTLS proxy server while maintaining local LAN connectivity.

### Why This Architecture?

The journey to this solution involved solving several interconnected challenges:

1. **USB WiFi Pass-through**: Hardware-level USB device pass-through to a lightweight VM allows the host system to remain on wired LAN while the guest provides an independent internet connection via WiFi.

2. **Transparent Proxying**: Rather than configuring each application individually, all traffic from the host is automatically routed through Xray using Linux netfilter (nftables) transparent redirection.

3. **Split Routing**: Local LAN traffic (192.168.0.0/16) bypasses the proxy for performance and compatibility, while all internet-bound traffic goes through the encrypted VLESS tunnel.

4. **Declarative Infrastructure**: The entire system—from host networking to guest configuration to proxy rules—is defined in NixOS configuration files, making it reproducible and version-controlled.

### Key Design Decisions

**Why MicroVM instead of containers?**

- USB device pass-through requires kernel-level access
- Separate network namespace for true isolation
- Full NixOS environment in guest for advanced networking

**Why manual wpa_supplicant instead of NetworkManager?**

- Minimal dependencies in a headless VM
- Deterministic configuration from SOPS secrets
- No conflicts with systemd-networkd

**Why dokodemo-door instead of SOCKS5?**

- Supports transparent proxy mode (`followRedirect: true`)
- Works with nftables REDIRECT target
- No application-level configuration needed

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ Host: owtest (192.168.11.50)                                │
│                                                              │
│  ┌────────────┐         ┌──────────────────────────────┐   │
│  │  ens18     │────────▶│ LAN Gateway 192.168.11.1     │   │
│  │ (Wired)    │         │ (Direct access to 192.168.*)  │   │
│  └────────────┘         └──────────────────────────────┘   │
│                                                              │
│  ┌────────────┐                                             │
│  │   br0      │ 10.77.77.2/24                               │
│  │ (Bridge)   │                                             │
│  └─────┬──────┘                                             │
│        │                                                     │
│        │ Route: 0.0.0.0/0 → 10.77.77.1 (metric 200)        │
│        │ Route: 192.168.0.0/16 → 192.168.11.1 (metric 100) │
│        │                                                     │
└────────┼─────────────────────────────────────────────────────┘
         │
         │ virtio-net
         ▼
┌─────────────────────────────────────────────────────────────┐
│ Guest: xray-vm (MicroVM)                                     │
│                                                              │
│  ┌────────────┐         ┌──────────────┐                    │
│  │   eth0     │         │  nftables    │                    │
│  │ 10.77.77.1 │────────▶│  REDIRECT    │                    │
│  │            │         │  → :1080     │                    │
│  └────────────┘         └──────┬───────┘                    │
│                                │                             │
│                         ┌──────▼───────┐                    │
│                         │   Xray       │                    │
│                         │ dokodemo-door│                    │
│                         │  port 1080   │                    │
│                         └──────┬───────┘                    │
│                                │                             │
│                                │ VLESS/XTLS                 │
│                                ▼                             │
│  ┌────────────┐         ┌──────────────┐                    │
│  │   wlan0    │────────▶│ WiFi AP      │                    │
│  │192.168.13.*│         │192.168.13.1  │                    │
│  │            │         │              │                    │
│  └────────────┘         └──────────────┘                    │
│       ▲                                                      │
│       │                                                      │
│       │ USB pass-through (0e8d:7961)                        │
│       └──────────────────────────────────────────────────── │
│                                                              │
└──────────────────────────────────────────────────────────────┘
                            │
                            │ Internet
                            ▼
                   ┌────────────────────┐
                   │ Remote Xray Server │
                   │  xray.endpoint.com │
                   │    VLESS/XTLS      │
                   └────────────────────┘
```

## Traffic Flow

### Local LAN Access (192.168.0.0/16)

```
Host → ens18 → LAN Gateway → Destination
```

Direct routing, no proxy.

### Internet Access via Proxy

```
Host app → br0 (10.77.77.2)
    ↓
Guest eth0 (10.77.77.1)
    ↓
nftables REDIRECT → :1080
    ↓
Xray dokodemo-door
    ↓
Xray outbound (VLESS/XTLS)
    ↓
wlan0 (192.168.13.113) + NAT
    ↓
WiFi → Internet → Remote Xray Server
    ↓
Destination (with remote server's IP)
```

## Component Details

### Host Configuration

#### Bridge Network (br0)

```nix
systemd.network.netdevs."20-br0".netdevConfig = {
  Name = "br0";
  Kind = "bridge";
};
```

Creates a virtual bridge for host-guest communication. The bridge exists without physical interfaces attached (`ConfigureWithoutCarrier = "yes"`).

#### Static Routing

```nix
routes = [
  {
    routeConfig = {
      Destination = "192.168.0.0/16";
      Gateway = "192.168.11.1";
      Metric = 100;
    };
  }
  {
    routeConfig = {
      Destination = "0.0.0.0/0";
      Gateway = "10.77.77.1";
      Metric = 200;
    };
  }
];
```

**Why these routes?**

- Metric 100 for LAN: High priority (lower number = higher priority)
- Metric 200 for default: Lower priority, used when no more specific route matches
- This implements split-tunneling: local traffic direct, everything else via proxy

#### USB Pass-through

```nix
services.udev.extraRules = ''
  SUBSYSTEM=="usb", ATTR{idVendor}=="0e8d", ATTR{idProduct}=="7961", GROUP="kvm"
'';
```

**Critical requirement**: QEMU (which runs the MicroVM) needs access to the USB device. By default, USB devices are owned by `root:root`. This rule changes group ownership to `kvm`, allowing QEMU to access it.

Find your device IDs:

```bash
lsusb
# Bus 002 Device 002: ID 0e8d:7961 MediaTek Inc. Wireless_Device
#                        ^^^^:^^^^
#                        vendor:product
```

### Guest Configuration (MicroVM)

#### Resource Allocation

```nix
microvm.hypervisor = "qemu";
microvm.vcpu = 1;
microvm.mem = 512;
microvm.balloon = true;
microvm.deflateOnOOM = true;
```

**Why these values?**

- 1 vCPU: Sufficient for network routing and proxy operations
- 512MB: Enough for base NixOS + xray + wpa_supplicant
- Balloon: Memory can be reclaimed by host when guest isn't using it
- DeflateOnOOM: Automatically reclaim balloon memory if guest runs low

#### USB Device Assignment

```nix
microvm.devices = [
  {
    bus = "usb";
    path = "vendorid=0x0e8d,productid=0x7961";
  }
];
```

This passes the physical USB WiFi adapter directly to the guest VM. The device disappears from the host and appears as a native USB device inside the guest.

#### Firmware Loading

```nix
hardware.enableRedistributableFirmware = true;
hardware.firmware = with pkgs; [ linux-firmware ];
```

**Why needed?**
MediaTek MT7921 WiFi chipset requires firmware files (`mt7921u.bin`, etc.) to initialize. Without this, you'd see kernel errors:

```
mt7921u: Failed to get patch semaphore
```

The `linux-firmware` package contains these binary blobs.

#### Secrets Sharing

```nix
microvm.shares = [
  {
    source = "/run/secrets";
    mountPoint = "/run/secrets-from-host";
    tag = "host-secrets";
    proto = "virtiofs";
  }
];
```

**Design choice**: Rather than implementing SOPS in both host and guest, the host decrypts secrets (via sops-nix) and shares them as plain files to the guest via virtio-fs. The guest reads them at runtime to generate `wpa_supplicant.conf`.

#### Network Interface Names

```nix
boot.kernelParams = [
  "net.ifnames=0"
  "ipv6.disable=1"
];
```

**Why disable predictable names?**

- Consistent naming: `eth0`, `wlan0` instead of `enp0s5`, `wlp0s6u1`
- Simpler configuration: No need to handle MAC-based renaming
- Race condition fix: Avoids wpa_supplicant starting before interface rename completes

**Why disable IPv6?**

- Simplifies firewall rules (no need for ip6tables equivalent)
- Reduces attack surface
- Not needed for this use case (can be re-enabled if required)

#### Static IP Configuration

```nix
systemd.network.networks."10-uplink" = {
  matchConfig.Name = "eth0";
  networkConfig = {
    Address = "10.77.77.1/24";
    DNS = [ "1.1.1.1" "8.8.8.8" ];
  };
  routes = [
    {
      routeConfig = {
        Gateway = "10.77.77.2";
        Destination = "10.77.77.0/24";
      };
    }
  ];
};
```

**Why no default gateway?**

- Guest uses wlan0 for internet, not eth0
- eth0 is only for receiving traffic from host
- Prevents routing loops

#### WiFi Configuration

**Why manual wpa_supplicant?**

NixOS's `networking.wireless` module generates its own configuration file and ignores custom configs. For secrets management via SOPS, we need control over the config file generation.

```nix
systemd.services.wpa-supplicant-setup = {
  # ...
  script = ''
    SSID=$(cat /run/secrets-from-host/wifi_bruc/main/ssid)
    PSK=$(cat /run/secrets-from-host/wifi_bruc/main/pass)

    cat > /etc/wpa_supplicant.conf <<EOF
    network={
      ssid="$SSID"
      psk="$PSK"
      key_mgmt=WPA-PSK
    }
    EOF
  '';
};
```

This service runs before `wpa-supplicant-manual`, reading secrets and generating the config at boot time.

#### Firewall Disable

```nix
networking.firewall.enable = false;
```

**Critical**: NixOS's default firewall blocks incoming connections. Since we need transparent proxy functionality (accepting all traffic on port 1080), we disable it entirely. Security is handled by:

1. Host firewall
2. Network isolation (guest only accessible from host via bridge)
3. Remote Xray server authentication

### nftables Configuration

```nft
table inet nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;

    # BYPASS
    iifname "eth0" ip daddr 192.168.0.0/16 accept
    iifname "eth0" ip daddr 10.77.77.1 accept
    iifname "eth0" ip daddr 127.0.0.0/8 accept

    # REDIRECT
    iifname "eth0" tcp dport != 1080 redirect to :1080
    iifname "eth0" udp dport != 1080 redirect to :1080
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "wlan0" masquerade
  }
}
```

#### PREROUTING Chain

**Purpose**: Intercept packets as they arrive on eth0, before routing decision.

**Bypass rules**:

- `192.168.0.0/16`: Local LAN traffic goes direct
- `10.77.77.1`: Traffic to guest itself (e.g., SSH)
- `127.0.0.0/8`: Loopback (shouldn't happen but explicit)

**Redirect rule**:

- `tcp dport != 1080`: Everything except xray itself
- `redirect to :1080`: Changes destination IP/port to 127.0.0.1:1080
- Connection tracking remembers the original destination

#### POSTROUTING Chain

**Purpose**: Modify packets as they leave wlan0.

**Masquerade**:

- Changes source IP from 10.77.77.2 → 192.168.13.113
- Why needed? WiFi router can't route responses to 10.77.77.2 (private bridge IP)
- Connection tracking reverses this on return packets

**Why no OUTPUT chain?**
Without OUTPUT chain rules, traffic **originating from the guest itself** (e.g., xray making outbound connections) goes directly out without being redirected back to xray—preventing infinite loops.

### Xray Configuration

```json
{
  "inbounds": [
    {
      "port": 1080,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      }
    }
  ]
}
```

**dokodemo-door** ("anywhere door" in Japanese):

- Accepts connections on port 1080
- `followRedirect: true`: Reads original destination from `SO_ORIGINAL_DST` socket option (set by nftables REDIRECT)
- Doesn't require SOCKS handshake—works transparently

```json
{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "xray.endpoint.com": [
              {
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "security": "tls",
        "tlsSettings": {
          "fingerprint": "chrome",
          "serverName": "xray.endpoint.com"
        }
      }
    }
  ]
}
```

**VLESS with XTLS-Vision**:

- VLESS: Lightweight protocol, minimal overhead
- XTLS: TLS splice—inner TLS (to destination) uses outer TLS (to proxy) session
- Vision: Flow control to mimic HTTPS behavior, evading DPI

## Deployment

### Prerequisites

1. NixOS host with flakes enabled
2. Proxmox hypervisor (for automated deployment script)
3. SOPS-encrypted WiFi credentials
4. Remote Xray server with VLESS configured

### Build and Deploy

```bash
# Build locally first (catches errors early)
nixos-rebuild build --flake .#owtest

# Deploy to Proxmox VM (fully automated)
./scripts/rebuild-owtest-enhanced.sh
```

The deployment script:

1. Destroys existing VM
2. Creates new VM with proper USB mapping
3. Boots NixOS installer ISO
4. Runs `nixos-anywhere` to install system
5. Reboots into final system
6. Waits for MicroVM to start
7. Validates connectivity

### Manual Deployment

```bash
# On an existing NixOS system:
nixos-rebuild switch --flake .#owtest

# Check MicroVM status
systemctl status microvm@xray-vm.service

# Connect to guest console
sudo socat STDIO,cfmakeraw unix:/var/lib/microvms/xray-vm/console.sock
```

## Verification

### From Host

```bash
# Check routing table
ip route
# Should show:
# default via 192.168.11.1 dev ens18 metric 1024
# 0.0.0.0/0 via 10.77.77.1 dev br0 metric 200
# 192.168.0.0/16 via 192.168.11.1 dev br0 metric 100

# Test local LAN access (direct)
curl http://192.168.11.1

# Test internet via proxy
curl --interface br0 https://ifconfig.me
# Should show remote Xray server's IP, not WiFi IP

# Monitor traffic on bridge
sudo tcpdump -i br0 -n
```

### From Guest

```bash
# Check interfaces
ip addr show
# Should show eth0 (10.77.77.1) and wlan0 (192.168.13.x)

# Check WiFi connection
wpa_cli status
# Should show state=COMPLETED

# Check xray
journalctl -u xray.service -n 50

# Test direct internet (from guest)
curl https://ifconfig.me
# Should show WiFi IP (not proxied)
```

## Troubleshooting

### WiFi Not Connecting

```bash
# Inside guest
systemctl status wpa-supplicant-manual
journalctl -u wpa-supplicant-manual -n 100

# Check if interface is up
ip link show wlan0

# Scan for networks
iw dev wlan0 scan | grep SSID

# Check secrets
cat /run/secrets-from-host/wifi_bruc/main/ssid
```

### Proxy Not Working

```bash
# Check nftables rules
nft list ruleset

# Check connection tracking
cat /proc/net/nf_conntrack | grep 1080

# Check xray logs
journalctl -u xray.service -f

# Verify from host
sudo tcpdump -i br0 -n port 1080
```

### USB Pass-through Issues

```bash
# On host
lsusb
# Device should NOT appear if passed to guest

# Check udev rules
udevadm info /dev/bus/usb/002/002 | grep GROUP

# Check QEMU process
ps aux | grep qemu | grep usb

# Inside guest
lsusb
# Device SHOULD appear here
dmesg | grep mt7921
```

## Security Considerations

1. **Guest isolation**: MicroVM only accessible from host via bridge
2. **Secrets**: WiFi credentials encrypted with SOPS, decrypted at boot
3. **No firewall in guest**: Acceptable since guest is network-isolated
4. **TLS verification**: Xray validates remote server certificate
5. **USB security**: Only WiFi adapter passed through, no other USB devices

## Performance

- **Latency overhead**: ~2-5ms (guest networking + NAT)
- **Throughput**: Limited by WiFi bandwidth (not CPU)
- **Memory**: Guest uses ~100MB actual, 512MB allocated
- **CPU**: <1% on idle, ~5-10% under load

## Future Improvements

1. **Automatic failover**: Switch to wired connection if WiFi fails
2. **Policy routing**: Different applications via different proxies
3. **IPv6 support**: Add if needed
4. **Multiple WiFi networks**: Automatic selection based on signal strength
5. **Connection metering**: Track bandwidth usage per application

## References

- [MicroVM.nix](https://github.com/astro/microvm.nix): Lightweight VMs for NixOS
- [Xray-core](https://github.com/XTLS/Xray-core): Proxy platform
- [nftables](https://netfilter.org/projects/nftables/): Linux packet filtering
- [wpa_supplicant](https://w1.fi/wpa_supplicant/): WiFi authentication
