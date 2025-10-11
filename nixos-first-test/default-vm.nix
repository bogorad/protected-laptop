# hosts/owtest/default.nix

{
  pkgs,
  inputs,
  lib,
  ...
}:
let
  # OpenWrt image from our flake
  owImageDrv = inputs.self.packages.${pkgs.system}.ow-vm-image;

  # Find the `squashfs combined` image
  findImage =
    dir:
    let
      entries = builtins.attrNames (builtins.readDir dir);
      matches = builtins.filter (n: lib.hasSuffix "squashfs-combined.img.gz" n) entries;
    in
    if matches != [ ] then
      "${dir}/${builtins.head matches}"
    else
      throw "OpenWrt combined image not found in ${dir}";

  chosenFile = findImage "${owImageDrv}";

  # Extract compressed image to store
  owBaseRaw =
    pkgs.runCommand "openwrt-base.img"
      {
        nativeBuildInputs = [ pkgs.p7zip ];
      }
      ''
        7z x -so ${chosenFile} > "$out" 2>/dev/null || true
        [ -s "$out" ] || { echo "Failed to extract image" >&2; exit 1; }
      '';

  # Runtime paths
  overlayDir = "/run/openwrt";
  overlayPath = "${overlayDir}/owtest-openwrt.qcow2";
  uciConfigFile = "${./ow-config.uci}";
in
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.sops-nix.nixosModules.sops
    ../openssh.nix
    ../hardware-prox-vm.nix
    ../users.nix
    ./disko.nix
  ];

  # Basic system configuration
  system.stateVersion = "25.05";
  programs.zsh.enable = true;

  networking.hostName = "owtest";
  networking.useDHCP = false;

  systemd.network.enable = true;

  # Network configuration
  systemd.network.netdevs."20-br0".netdevConfig = {
    Name = "br0";
    Kind = "bridge";
  };

  systemd.network.networks = {
    "30-uplink" = {
      matchConfig.Name = "ens18";
      networkConfig.DHCP = "ipv4";
    };
    "30-br0" = {
      matchConfig.Name = "br0";
      networkConfig.ConfigureWithoutCarrier = "yes";
      address = [ "10.77.0.2/24" ];
    };
  };

  # Libvirt configuration
  virtualisation.libvirtd = {
    enable = true;
    allowedBridges = [ "br0" ];
  };

  # User permissions
  users.users.chuck.extraGroups = [ "libvirtd" ];
  users.users.root.extraGroups = [ "libvirtd" ];

  # System packages
  environment.systemPackages = with pkgs; [
    bat
    eza
    fd
    git
    neovim
    ripgrep
    yazi
  ];

  # Setup default system-wide git configuration.
  environment.etc."gitconfig".text = ''
    [user]
      email = bogorad@gmail.com
      name = Eugene Bogorad
  '';

  # Create overlay directory
  systemd.tmpfiles.rules = [ "d ${overlayDir} 0755 root root -" ];

  # OpenWrt VM domain XML: unpack and replace wildcards.
  environment.etc."libvirt/qemu/owtest-openwrt.xml".text =
    builtins.replaceStrings [ "@OVERLAY@" ] [ overlayPath ]
      (builtins.readFile ./owtest-openwrt.xml);

  # Services
  systemd.services = {
    # Create qcow2 overlay
    "prepare-owtest-overlay" = {
      description = "Create ephemeral qcow2 overlay for OpenWrt VM";
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.coreutils
        pkgs.qemu
      ];
      script = ''
        mkdir -p "${overlayDir}"
        if [ ! -e "${overlayPath}" ]; then
          qemu-img create -f qcow2 -F raw -b "${owBaseRaw}" "${overlayPath}" 4G
          chmod 0644 "${overlayPath}"
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    # Define and start OpenWrt VM
    owtest-define-openwrt = {
      description = "Define/start owtest-openwrt domain";
      after = [
        "libvirtd.service"
        "systemd-networkd.service"
        "prepare-owtest-overlay.service"
      ];
      wants = [
        "libvirtd.service"
        "prepare-owtest-overlay.service"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.libvirt
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Define or re-define domain
        if virsh dominfo owtest-openwrt >/dev/null 2>&1; then
          virsh destroy owtest-openwrt >/dev/null 2>&1 || true
          virsh undefine owtest-openwrt || true
        fi
        virsh define /etc/libvirt/qemu/owtest-openwrt.xml
        virsh autostart owtest-openwrt || true
        virsh start owtest-openwrt || true
      '';
    };

    # Deploy UCI configuration after the OpenWrt VM is ready.
    ow-config-deploy = {
      description = "Deploy configuration to OpenWrt";
      after = [
        "owtest-define-openwrt.service"
        "network-online.target"
      ];
      wants = [
        "owtest-define-openwrt.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.coreutils
        pkgs.openssh
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        # Wait for SSH (up to 3 minutes)
        for i in $(seq 1 180); do
          if ssh -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o ConnectTimeout=2 \
                 root@10.77.0.1 true 2>/dev/null; then
            break
          fi
          sleep 1
        done

        # Deploy UCI configuration
        scp -O \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          "${uciConfigFile}" root@10.77.0.1:/tmp/
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            root@10.77.0.1 "uci batch < /tmp/$(basename "${uciConfigFile}") && /etc/init.d/network restart"
      '';
    };

    # Clone nix-config repository so we can initiate rebuld locally.
    # For this to work we need proper git configuration.
    clone-nix-config = {
      description = "Clone nix-config repo";
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.git
        pkgs.coreutils
        pkgs.openssh
      ];
      serviceConfig = {
        Type = "oneshot";
        Environment = [ ];
      };
      script = ''
        mkdir -p /persist/nix-config
        if [ ! -d /persist/nix-config/.git ]; then
          git clone git@github.com:bogorad/nix-config.git /persist/nix-config
          chown -R chuck:users /persist/nix-config
        fi
      '';
    };
  };
}
