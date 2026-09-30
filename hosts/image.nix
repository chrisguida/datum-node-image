# Host variant built as a disk image via system.build.images.<variant>:
#   qemu-efi  -> qcow2, UEFI      (LunaNode, DigitalOcean if UEFI, local QEMU)
#   raw-efi   -> raw,   UEFI      (Vultr)
#   raw       -> raw,   BIOS/GRUB (DigitalOcean, older hypervisors)
# The nixpkgs disk-image module defines "/" by label, grows the root partition
# on first boot and picks systemd-boot or GRUB per variant.
{ lib, ... }:
{
  # The image variants (nixpkgs disk-image module) define the root filesystem
  # and bootloader themselves. These low-priority defaults only make the base
  # configuration evaluable on its own (`nix flake check`); every variant
  # overrides them.
  fileSystems."/" = {
    device = lib.mkOverride 1100 "/dev/disk/by-label/nixos";
    fsType = lib.mkOverride 1100 "ext4";
  };
  boot.loader.grub.enable = lib.mkOverride 1100 true;
  boot.loader.grub.devices = lib.mkOverride 1100 [ "/dev/vda" ];

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
  boot.loader.timeout = lib.mkDefault 1;
  services.qemuGuest.enable = true;
}
