# hosts/owtest/disko.nix

{
  lib,
  ...
}:

{
  disko.devices = {
    disk.disk1 = {
      device = lib.mkDefault "/dev/sda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            name = "boot";
            size = "1M";
            type = "EF02"; # BIOS boot partition
          };
          bootfs = {
            name = "bootfs";
            size = "1G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/boot";
            };
          };
          swap = {
            size = "1G";
            content = {
              type = "swap";
              randomEncryption = true;
              discardPolicy = "both";
              resumeDevice = true;
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [
                "noatime" # fewer writes; see ArchWiki fstab notes
                "lazytime" # cache inode times, flush on sync/interval
              ];
            };
          };
        };
      };
    };
  };
}
