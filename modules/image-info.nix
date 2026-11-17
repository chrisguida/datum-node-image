# datum-node-image.*
#
# What this system was built from and as, written to /etc/datum-node-image/image.json
# for the setup page and the updater: the flake revision (flake.nix passes self.rev),
# the image variant (each hosts/*.nix sets its own; the disk-image host sets it per
# variant through image.modules.<name>), and the fast-start snapshot pins.
{
  config,
  lib,
  ...
}:
let
  cfg = config.datum-node-image;
  fastStart = config.services.blake2b-node.fastStart or { };
  # the first "## v..." heading of the changelog names the release this tree is (or follows)
  changelogHeading = lib.findFirst (l: lib.hasPrefix "## v" l) null (
    lib.splitString "\n" (builtins.readFile ../CHANGELOG.md)
  );
in
{
  options.datum-node-image = {
    version = lib.mkOption {
      type = lib.types.str;
      default =
        if changelogHeading == null then "unknown" else builtins.elemAt (lib.splitString " " changelogHeading) 1;
      description = "Release tag this system corresponds to; the setup page compares it with the published releases.";
    };

    rev = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
      description = "Git revision of the datum-node-image flake this system was built from.";
    };

    variant = lib.mkOption {
      type = lib.types.enum [
        "generic"
        "generic-qcow2"
        "digital-ocean"
        "qemu-efi"
        "raw-efi"
        "raw"
        "anywhere"
        "unknown"
      ];
      default = "unknown";
      description = ''
        Which image this system was built as: a `system.build.images` variant name of the
        disk-image host, or `anywhere` for the nixos-anywhere host. The updater rebuilds the
        same variant from a newer tag.
      '';
    };
  };

  config.environment.etc."datum-node-image/image.json".text = builtins.toJSON (
    {
      inherit (cfg) version rev variant;
    }
    // lib.optionalAttrs (fastStart.enable or false) {
      snapshotHeight = fastStart.height;
      snapshotBlockhash = fastStart.blockhash;
    }
  );
}
