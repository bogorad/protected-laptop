# hosts/owtest/microvm/default.nix

{
  # config,
  pkgs,
  upkgs,
  lib,
  xrayConfigFile,
  nftablesRulesFile,
  wifiDongleVendor,
  wifiDongleProduct,
  ...
}:
let
  # Define the path for the final, processed xray configuration file
  processedXrayConfigFile = "/run/xray/config.json";
in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # MICROVM CONFIGURATION - Fully Declarative NixOS Guest
  # ═══════════════════════════════════════════════════════════════════════════
  microvm.vms.xray-vm = {
    autostart = true;

    config = {
      # ═══════════════════════════════════════════════════════════════
      # MICROVM RESOURCES
      # ═══════════════════════════════════════════════════════════════
      microvm.hypervisor = "cloud-hypervisor";
      microvm.vcpu = 1;
      microvm.mem = 384;
      microvm.balloon = true;
      microvm.deflateOnOOM = true;

      # ═══════════════════════════════════════════════════════════════
      # NETWORKING & USB
      # ═══════════════════════════════════════════════════════════════
      microvm.interfaces = [
        {
          # type = "bridge";
          # bridge = "br0";
          type = "tap";
          id = "vm-xray";
          mac = "0e:00:00:00:ee:01";
        }
      ];

      # microvm.devices = [
      #   {
      #     bus = "usb";
      #     path = "vendorid=0x${wifiDongleVendor},productid=0x${wifiDongleProduct}";
      #   }
      # ];
      systemd.services.usbip-client = {
        description = "USB/IP Client - Attach WiFi Dongle";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = [
            "${pkgs.kmod}/bin/modprobe vhci-hcd"
            # Wait for network
            "${pkgs.coreutils}/bin/sleep 3"
          ];
          ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.linuxPackages.usbip}/bin/usbip attach --remote=10.77.77.2 --busid=$(${pkgs.linuxPackages.usbip}/bin/usbip list --remote=10.77.77.2 | ${pkgs.gnugrep}/bin/grep \"${wifiDongleVendor}:${wifiDongleProduct}\" | ${pkgs.gawk}/bin/awk \"{print \\$1}\" | ${pkgs.gnused}/bin/sed \"s/://\")'";
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };

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
      boot.kernelModules = [ "vhci-hcd" ];

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
              "1.0.0.1"
              "8.8.8.8"
            ];
          };
          # Don't use this as default route
          routes = [
            {
              Gateway = "10.77.77.2";
              # Only route 10.77.77.0/24 through eth0
              Destination = "10.77.77.0/24";
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
          SSID=$(cat /run/secrets-from-host/wifi_bruc/main/ssid)
          PSK=$(cat /run/secrets-from-host/wifi_bruc/main/pass)

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
      # SERVICES: XRAY, NFTABLES, AND NTP SERVER
      # ═══════════════════════════════════════════════════════════════

      # Enable the Chrony NTP server in the MicroVM.
      # This will sync the MicroVM's clock from the internet (via its WiFi connection)
      # and also act as a server for other machines on its local network.
      services.chrony = {
        enable = true;
        # 2. Allow the host (at 10.77.77.2) to connect to this NTP server.
        # This directive tells chrony to accept time sync requests from the host.
        extraConfig = ''
          allow 10.77.77.0/24
        '';
      };

      # This service prepares the xray config file before xray starts.
      systemd.services.xray-config-generator = {
        description = "Generate Xray config from template and secrets";
        wantedBy = [ "multi-user.target" ];
        before = [ "xray.service" ];
        after = [ "remote-fs.target" ];
        requires = [ "remote-fs.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          set -e
          echo "Waiting for xray secrets..."
          while [ ! -f /run/secrets-from-host/xray_uuid ] || [ ! -f /run/secrets-from-host/xray_endpoint ]; do
            sleep 1
          done
          echo "Secrets found. Generating config."

          mkdir -p /run/xray

          XRAY_UUID=$(cat /run/secrets-from-host/xray_uuid)
          XRAY_ENDPOINT=$(cat /run/secrets-from-host/xray_endpoint)

          # Use jq to replace both placeholders
          ${pkgs.jq}/bin/jq \
            --arg uuid "$XRAY_UUID" \
            --arg endpoint "$XRAY_ENDPOINT" \
            'walk(
              if . == "@@id@@" then $uuid
              elif . == "@@endpoint@@" then $endpoint
              else . end
            )' \
            ${xrayConfigFile} > ${processedXrayConfigFile}

          chmod 644 ${processedXrayConfigFile}
          echo "Xray config generated at ${processedXrayConfigFile}"
        '';
      };

      systemd.services.xray.requires = [ "xray-config-generator.service" ];
      systemd.services.xray.after = [ "xray-config-generator.service" ];

      services.xray = {
        enable = true;
        package = upkgs.xray;
        settingsFile = processedXrayConfigFile;
      };

      networking.nftables = {
        enable = true;
        ruleset = builtins.readFile nftablesRulesFile;
      };

      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
        "net.netfilter.nf_conntrack_max" = 262144;
      };

      # ═══════════════════════════════════════════════════════════════
      # PACKAGES & USERS
      # ═══════════════════════════════════════════════════════════════
      environment.systemPackages = with pkgs; [
        jq # needed for the config generator script
        chrony # time server for the host
        tcpdump
        iproute2
        usbutils # for lsusb
        pciutils # deal with pci wifi/lan potentially
        wirelesstools
        iw
        ripgrep
        wpa_supplicant
        yazi # yes
      ];

      # Save some space
      services.udisks2.enable = false;
      documentation.enable = false;
      documentation.nixos.enable = false;

      # debug user w/o password - only accessible via serial console
      # users.users.debug = {
      #   isNormalUser = true;
      #   extraGroups = [ "wheel" ];
      #   password = "";
      # };

      users.users.root.password = "";
      security.sudo.wheelNeedsPassword = false;
    };
  };
}
