# Host variant for nixos-anywhere (rescue-mode install on providers without
# image import: Hetzner, OVH, Scaleway, ...). GPT with a BIOS boot partition
# and an ESP, GRUB installed for both, so it boots on legacy and UEFI VMs.
#
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#blake2b-vps-anywhere --target-host root@<ip>
{ ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02";
        };
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
    "ahci"
    "sd_mod"
    "sr_mod"
    "nvme"
    "xen_blkfront"
  ];
}
