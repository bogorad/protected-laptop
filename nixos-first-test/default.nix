# hosts/owtest/default.nix

{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
let
  # Configuration files for the xray microvm
  xrayConfigFile = "${./xray.conf}";
  nftablesRulesFile = "${./nftables.nft}";

  # ═══════════════════════════════════════════════════════════════════════════
  # USB WiFi dongle identifiers
  #
  # 0e8d:7961 for mediatec usb wifi ax1800 dongle
  wifiDongleVendor = "0e8d";
  wifiDongleProduct = "7961";
  # ═══════════════════════════════════════════════════════════════════════════
  SOPS_DETAILS = {
    sopsFile = ../../secrets/wifi-bruc.yaml;
  };
in
{
  networking.hostName = "owtest"; # always first

  imports = [
    inputs.disko.nixosModules.disko
    inputs.sops-nix.nixosModules.sops
    inputs.microvm.nixosModules.host
    ../nix.nix
    ../openssh.nix
    ../hardware-prox-vm.nix
    ../users.nix
    ./disko.nix
  ];

  sops.secrets = {
    "wifi-bruc/main/ssid" = SOPS_DETAILS;
    "wifi-bruc/main/pass" = SOPS_DETAILS;
  };

  # Basic system configuration
  system.stateVersion = "25.05";
  networking.useDHCP = false;
  systemd.network.enable = true;

  # Network configuration for the host bridge
  systemd.network.netdevs."20-br0".netdevConfig = {
    Name = "br0";
    Kind = "bridge";
  };
  systemd.network.networks."30-uplink" = {
    matchConfig.Name = "ens18";
    networkConfig.DHCP = "ipv4";
    # This automatically creates route for 192.168.11.0/24 with metric 1024
  };

  systemd.network.networks."30-br0" = {
    matchConfig.Name = "br0";
    networkConfig.ConfigureWithoutCarrier = "yes";
    address = [ "10.77.77.2/24" ];

    routes = [
      # Explicit: Keep 192.168.0.0/16 on LAN (via ens18)
      {
        routeConfig = {
          Destination = "192.168.0.0/16";
          Gateway = "192.168.11.1"; # Your LAN gateway
          Metric = 100; # High priority
        };
      }
      # Everything else via MicroVM
      {
        routeConfig = {
          Destination = "0.0.0.0/0";
          Gateway = "10.77.77.1"; # MicroVM
          Metric = 200; # Lower priority (higher number)
        };
      }
    ];
  };

  # System packages
  environment.systemPackages = with pkgs; [
    bat
    eza
    fd
    git
    neovim
    ripgrep
    socat
    screen
    yazi
    usbutils # Added for lsusb debugging
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # ADDED: Host-side udev rules for USB device pass-through
  # ═══════════════════════════════════════════════════════════════════════════
  # USB devices need manual permission setup on the host
  # The device must be in the "kvm" group for QEMU to access it
  # This rule makes the WiFi dongle accessible to the microvm
  # ═══════════════════════════════════════════════════════════════════════════

  services.udev.extraRules = ''
    # WiFi USB Dongle pass-through to xray-vm
    # Replace xxx with vendor ID and yyy with product ID from lsusb output
    SUBSYSTEM=="usb", ATTR{idVendor}=="${wifiDongleVendor}", ATTR{idProduct}=="${wifiDongleProduct}", GROUP="kvm"
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # MICROVM CONFIGURATION - Fully Declarative NixOS Guest
  # ═══════════════════════════════════════════════════════════════════════════
  microvm.vms.xray-vm = {
    autostart = true;

    config = {
      # ═══════════════════════════════════════════════════════════════
      # MICROVM RESOURCES
      # ═══════════════════════════════════════════════════════════════
      microvm.hypervisor = "qemu";
      microvm.vcpu = 1;
      microvm.mem = 512;
      microvm.balloon = true;
      microvm.deflateOnOOM = true;

      # ═══════════════════════════════════════════════════════════════
      # NETWORKING & USB
      # ═══════════════════════════════════════════════════════════════
      microvm.interfaces = [
        {
          type = "bridge";
          bridge = "br0";
          id = "vm-xray";
          mac = "0e:00:00:00:ee:01";
        }
      ];

      microvm.devices = [
        {
          bus = "usb";
          path = "vendorid=0x${wifiDongleVendor},productid=0x${wifiDongleProduct}";
        }
      ];

      # ═══════════════════════════════════════════════════════════════
      # FIRMWARE & SHARES
      # ═══════════════════════════════════════════════════════════════
      hardware.enableRedistributableFirmware = true; # This is for the USB wifi dongle
      hardware.firmware = with pkgs; [ linux-firmware ];

      # Acess host's directories
      microvm.shares = [
        {
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }
        {
          source = "/run/secrets";
          mountPoint = "/run/secrets-from-host";
          tag = "host-secrets";
          proto = "virtiofs";
        }
      ];

      # ═══════════════════════════════════════════════════════════════
      # BASIC SYSTEM CONFIG
      # ═══════════════════════════════════════════════════════════════
      networking.firewall.enable = false;
      networking.hostName = "xray-vm";
      system.stateVersion = "25.05";

      boot.kernelParams = [
        "console=ttyS0,115200n8" # Create conrole so we can peek inside.
        "net.ifnames=0" # Disable predictable interface names
        "ipv6.disable=1" # ADDED: Disable IPv6 completely
      ];

      # Serial console
      microvm.qemu = {
        extraArgs = [
          "-serial"
          "unix:/var/lib/microvms/xray-vm/console.sock,server,nowait"
        ];
        serialConsole = false;
      };

      # ═══════════════════════════════════════════════════════════════
      # NETWORKING: ETHERNET (systemd-networkd)
      # ═══════════════════════════════════════════════════════════════
      networking.useDHCP = false;
      systemd.network.enable = true;
      systemd.network.networks = {
        "10-uplink" = {
          matchConfig.Name = "eth0";
          networkConfig = {
            Address = "10.77.77.1/24";
            DNS = [
              "1.1.1.1"
              "8.8.8.8"
            ];
          };
          # Don't use this as default route
          routes = [
            {
              routeConfig = {
                Gateway = "10.77.77.2";
                # Only route 10.77.77.0/24 through eth0
                Destination = "10.77.77.0/24";
              };
            }
          ];
        };
        # Configure WiFi interface with systemd-networkd
        "20-wifi" = {
          matchConfig.Name = "wlan0";
          networkConfig = {
            DHCP = "ipv4";
          };
        };
      };

      # ═══════════════════════════════════════════════════════════════
      # WIFI: MANUAL WPA_SUPPLICANT CONFIGURATION
      # ═══════════════════════════════════════════════════════════════
      # DISABLE NixOS's wpa_supplicant module
      networking.wireless.enable = lib.mkForce false;

      # Create wpa_supplicant config from SOPS secrets
      systemd.services.wpa-supplicant-setup = {
        description = "Generate wpa_supplicant.conf from secrets";
        wantedBy = [ "multi-user.target" ];
        before = [ "wpa-supplicant-manual.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          # Read secrets from host share
          SSID=$(cat /run/secrets-from-host/wifi-bruc/main/ssid)
          PSK=$(cat /run/secrets-from-host/wifi-bruc/main/pass)

          # Generate wpa_supplicant config
          cat > /etc/wpa_supplicant.conf <<EOF
          ctrl_interface=/run/wpa_supplicant
          update_config=1

          network={
            ssid="$SSID"
            psk="$PSK"
            key_mgmt=WPA-PSK
          }
          EOF

          chmod 600 /etc/wpa_supplicant.conf
        '';
      };

      # Manual wpa_supplicant service
      systemd.services.wpa-supplicant-manual = {
        description = "WPA Supplicant (manual configuration)";
        after = [
          "network-pre.target"
          "wpa-supplicant-setup.service"
        ];
        before = [ "network.target" ];
        wants = [ "network-pre.target" ];
        requires = [ "wpa-supplicant-setup.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -c /etc/wpa_supplicant.conf -i wlan0 -D nl80211,wext";
          Restart = "always";
          RestartSec = "5s";
        };
      };

      # ═══════════════════════════════════════════════════════════════
      # SERVICES: XRAY & NFTABLES
      # ═══════════════════════════════════════════════════════════════

      services.xray = {
        enable = true;
        settingsFile = xrayConfigFile;
      };

      networking.nftables = {
        enable = true;
        ruleset = builtins.readFile nftablesRulesFile;
      };

      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
        "net.netfilter.nf_conntrack_max" = 262144; # ADDED: Increase from default 65536
      };

      # ═══════════════════════════════════════════════════════════════
      # PACKAGES & USERS
      # ═══════════════════════════════════════════════════════════════
      environment.systemPackages = with pkgs; [
        tcpdump
        iproute2
        usbutils
        wirelesstools
        iw
        ripgrep
        wpa_supplicant
        yazi
      ];

      services.udisks2.enable = false;
      documentation.enable = false;
      documentation.nixos.enable = false;

      # debug user w/o password
      users.users.debug = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        password = "";
      };

      users.users.root.password = "";
      security.sudo.wheelNeedsPassword = false;
    };
  }; # end of microvm.vms

  # ═══════════════════════════════════════════════════════════════════════════
  # END OF MICROVM CONFIGURATION
  # ═══════════════════════════════════════════════════════════════════════════

  # User permissions for managing MicroVMs
  users.users = {
    chuck.extraGroups = [ "microvm" ];
    root.extraGroups = [ "microvm" ];
  };

  # Setup default system-wide git configuration
  environment.etc."gitconfig".text = ''
    [user]
      email = bogorad@gmail.com
      name = Eugene Bogorad
  '';

  # Services
  systemd.services = {
    # Clone nix-config repository
    clone-nix-config = {
      description = "Clone nix-config repo";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.git
        pkgs.openssh
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /persist/nix-config
        if [ ! -d /persist/nix-config/.git ]; then
          git clone git@github.com:bogorad/nix-config.git /persist/nix-config
          chown -R chuck:users /persist/nix-config
        fi
      '';
    };
  };
  programs.zsh = {
    enable = true;
    shellAliases = {
      "logintovm" = "sudo socat STDIO,cfmakeraw unix:/var/lib/microvms/xray-vm/console.sock";
    };
  };

}
