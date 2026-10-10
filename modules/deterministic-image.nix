# Build the disk images with lib/make-disk-image.nix, nixpkgs' builder plus the three changes
# that make two builds of the same closure byte-identical (fixed ext4 hash seed, fixed VM clock,
# zeroed build-time superblock fields). nixpkgs' image modules import their builder by path, so
# the only hook is the build attribute each one sets; this overrides it with the same arguments.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  makeDiskImage = import ../lib/make-disk-image.nix;
in
{
  config = lib.mkMerge [
    # digital-ocean variant (nixos/modules/virtualisation/digital-ocean-image.nix)
    (lib.mkIf (options.virtualisation ? digitalOceanImage) {
      system.build.digitalOceanImage = lib.mkForce (makeDiskImage {
        name = "digital-ocean-image";
        inherit (config.image) baseName;
        inherit (config.virtualisation) diskSize;
        inherit config lib pkgs;
        format = "qcow2";
        # as upstream: the file is gzipped here; flake.nix re-gzips it without name and mtime
        postVM = ''
          ${pkgs.gzip}/bin/gzip $diskImage
        '';
        configFile =
          if config.virtualisation.digitalOceanImage.configFile == null then
            config.virtualisation.digitalOcean.defaultConfigFile
          else
            config.virtualisation.digitalOceanImage.configFile;
      });
    })
    # qemu-efi, raw-efi, raw variants (nixos/modules/virtualisation/disk-image.nix)
    (lib.mkIf (options.image ? efiSupport) {
      system.build.image = lib.mkForce (makeDiskImage {
        inherit lib config pkgs;
        inherit (config.virtualisation) diskSize;
        inherit (config.image) baseName format;
        partitionTableType = if config.image.efiSupport then "efi" else "legacy";
      });
    })
  ];
}
