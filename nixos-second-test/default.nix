{
  config,
  pkgs,
  upkgs,
  inputs,
  lib,
  ...
}:
let
  # Configuration files for the xray microvm
  xrayConfigFile = "${./microvm/xray.conf}";
  nftablesRulesFile = "${./microvm/nftables.nft}";

  # ═══════════════════════════════════════════════════════════════════════════
  # USB WiFi dongle identifiers
  #
  # 0e8d:7961 for mediatec usb wifi ax1800 dongle
  wifiDongleVendor = "0e8d";
  wifiDongleProduct = "7961";
  # ═══════════════════════════════════════════════════════════════════════════
  SOPS_FILE = {
    sopsFile = ./secrets.yaml;
  };
in
{
  networking.hostName = "owtest"; # always first
  networking.useDHCP = false;
  networking.nameservers = [
    "1.0.0.1"
    "8.8.8.8"
  ];
  networking.firewall.enable = false;
  networking.firewall.interfaces."br0".allowedTCPPorts = [ 3240 ];

  # ═══════════════════════════════════════════════════════════════════════════
  # Setup USBIP
  # ═══════════════════════════════════════════════════════════════════════════
  # Enable USB/IP server on host
  boot.kernelModules = [ "usbip_host" ];
  # USB/IP server service
  systemd.services.usbip-server = {
    description = "USB/IP Server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "forking";
      ExecStartPre = "${pkgs.kmod}/bin/modprobe usbip_host";
      ExecStart = "${pkgs.linuxPackages.usbip}/bin/usbipd -D";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  # Separate service to bind the device after usbipd is running
  systemd.services.usbip-bind-wifi = {
    description = "Bind WiFi dongle to USB/IP";
    after = [ "usbip-server.service" ];
    requires = [ "usbip-server.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Wait for device to appear
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      # Bind using the correct busid extraction
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.linuxPackages.usbip}/bin/usbip bind --busid=$(${pkgs.linuxPackages.usbip}/bin/usbip list -l | ${pkgs.gnugrep}/bin/grep \"${wifiDongleVendor}:${wifiDongleProduct}\" | ${pkgs.gnugrep}/bin/grep busid | ${pkgs.gawk}/bin/awk \"{print \\$3}\")'";
    };
  };

  hardware.enableRedistributableFirmware = true;
  hardware.firmware = with pkgs; [ linux-firmware ];

  # ═══════════════════════════════════════════════════════════════════════════

  imports = [
    inputs.disko.nixosModules.disko
    inputs.sops-nix.nixosModules.sops
    inputs.microvm.nixosModules.host
    ../nix.nix
    ../openssh.nix
    ../hardware-prox-vm.nix
    ../users.nix
    ./disko.nix
    # Import the microvm configuration as a function call
    (import ./microvm {
      inherit
        config
        pkgs
        upkgs
        lib
        xrayConfigFile
        nftablesRulesFile
        wifiDongleVendor
        wifiDongleProduct
        ;
    })
  ];

  sops.secrets = {
    "wifi_bruc/main/ssid" = SOPS_FILE;
    "wifi_bruc/main/pass" = SOPS_FILE;
    "xray_uuid" = SOPS_FILE;
    "xray_endpoint" = SOPS_FILE;
  };

  # Basic system configuration
  system.stateVersion = "25.05";
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
    linkConfig.ActivationPolicy = "always-up";

    routes = [
      {
        Destination = "192.168.0.0/16";
        Gateway = "192.168.11.1";
        Metric = 100;
      }
      {
        Destination = "0.0.0.0/0";
        Gateway = "10.77.77.1";
        Metric = 200;
      }
    ];
  };

  # Enslave the tap interface to the bridge (this is correct)
  systemd.network.networks."40-vm-xray-tap" = {
    matchConfig.Name = "vm-xray";
    networkConfig = {
      Bridge = "br0"; # ✅ This is correct - tap enslaves to bridge
      ConfigureWithoutCarrier = true;
    };
  };

  # 1. ESSENTIAL: Disable the "wait-online" service.
  # This service blocks the boot process until full network connectivity is established.
  # In your setup, this will always time out and cause the boot to fail because
  # the host is waiting for the MicroVM, which hasn't started yet.
  # Disabling this allows the host to continue booting successfully.
  systemd.services."systemd-networkd-wait-online".enable = lib.mkForce false;

  # 2. Point the host's time sync service to the MicroVM.
  # Once the MicroVM is up, it will provide time to the host.
  # timesyncd will initially fail to connect but will keep retrying in the background
  # and will succeed once the MicroVM's time server is running.
  services.timesyncd = {
    enable = true;
    servers = [ "10.77.77.1" ]; # The IP address of your MicroVM
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
    linuxPackages.usbip # USB/IP userspace tools
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
