# Host variant built as a disk image via system.build.images.<variant>:
#   generic       -> raw,   BIOS and UEFI (any KVM provider that imports raw disks: DigitalOcean, Vultr)
#   generic-qcow2 -> qcow2, BIOS and UEFI (providers that import qcow2 only: LunaNode; local QEMU)
#   qemu-efi      -> qcow2, UEFI only, systemd-boot
#   raw-efi       -> raw,   UEFI only, systemd-boot
#   raw           -> raw,   BIOS only, GRUB
#   digital-ocean -> qcow2, BIOS only, GRUB, DigitalOcean metadata services instead of cloud-init
# The nixpkgs disk-image module defines "/" by label, grows the root partition
# on first boot and picks systemd-boot or GRUB per variant.
{ lib, ... }:
let
  genericImage =
    variant: format:
    { modulesPath, ... }:
    {
      imports = [ (modulesPath + "/virtualisation/disk-image.nix") ];
      datum-node-image.variant = variant;
      image.format = format;
      image.efiSupport = true;
      boot.loader.systemd-boot.enable = false;
      boot.loader.efi.canTouchEfiVariables = false;
      boot.loader.grub = {
        enable = true;
        efiSupport = true;
        efiInstallAsRemovable = true;
        devices = [ "/dev/vda" ];
      };
    };
in
{
  imports = [ ../modules/deterministic-image.nix ];

  # Each variant records its own name (datum-node-image.variant -> /etc/datum-node-image/image.json),
  # so a deployed system knows which image to rebuild when it updates itself. image.modules.<name>
  # is nixpkgs' per-variant module list; these entries merge with its defaults.
  image.modules =
    lib.genAttrs [ "digital-ocean" "qemu-efi" "raw-efi" "raw" ] (name: {
      datum-node-image.variant = name;
    })
    // {
      # One image for any KVM host: a GPT disk with both a BIOS boot partition and an ESP, GRUB
      # installed for both firmwares (the EFI copy at the removable-media path, since a fresh VM has
      # no boot entries), cloud-init for the provider's metadata. Raw for providers that import raw
      # disks (DigitalOcean, Vultr), qcow2 for those that take only qcow2 (LunaNode).
      generic = genericImage "generic" "raw";
      generic-qcow2 = genericImage "generic-qcow2" "qcow2";
    };

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
    "ata_piix"
    "sd_mod"
    "sr_mod"
    "nvme"
    "xen_blkfront"
  ];
  boot.loader.timeout = lib.mkDefault 1;
  services.qemuGuest.enable = true;
}
