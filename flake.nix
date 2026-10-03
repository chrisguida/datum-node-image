{
  description = "Reproducible VPS image: pruned Bitcoin Knots + DATUM gateway (bitcoin, BLAKE2b proof of work)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      overlay = final: prev: {
        bitcoind-knots-bin = final.callPackage ./pkgs/bitcoind-knots-bin.nix { };
        datum-gateway-convoy = final.callPackage ./pkgs/datum-gateway.nix { variant = "convoy"; };
        datum-gateway-iohzrd = final.callPackage ./pkgs/datum-gateway.nix { variant = "iohzrd"; };
        ratum-gateway = final.callPackage ./pkgs/ratum-gateway.nix { };
        node-wizard = final.callPackage ./pkgs/node-wizard { };
        # a function: { height, blockhash, utxoHash, chainTxCount } -> Knots with that snapshot in chainparams
        bitcoind-knots-patched = final.callPackage ./pkgs/bitcoind-knots-patched.nix { };
      };

      mkHost =
        extraModules:
        nixpkgs.lib.nixosSystem {
          modules = [
            { nixpkgs.hostPlatform = "x86_64-linux"; }
            { nixpkgs.overlays = [ overlay ]; }
            self.nixosModules.datum-gateway
            self.nixosModules.blake2b-node
            self.nixosModules.node-wizard
            self.nixosModules.fast-start
            ./hosts/common.nix
          ]
          ++ extraModules;
        };

      images = self.nixosConfigurations.blake2b-vps-image.config.system.build.images;
    in
    {
      overlays.default = overlay;

      nixosModules = {
        datum-gateway = ./modules/datum-gateway.nix;
        blake2b-node = ./modules/blake2b-node.nix;
        node-wizard = ./modules/node-wizard.nix;
        fast-start = ./modules/fast-start.nix;
      };

      nixosConfigurations = {
        # disk images (system.build.images.<variant>)
        blake2b-vps-image = mkHost [ ./hosts/image.nix ];
        # nixos-anywhere / rescue-mode install
        blake2b-vps-anywhere = mkHost [
          disko.nixosModules.disko
          ./hosts/anywhere.nix
        ];
      };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ overlay ];
          };
        in
        {
          inherit (pkgs)
            bitcoind-knots-bin
            datum-gateway-convoy
            datum-gateway-iohzrd
            ratum-gateway
            node-wizard
            ;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          image-qcow2 = images.qemu-efi;
          image-raw-efi = images.raw-efi;
          image-raw-bios = images.raw;
          image-digitalocean = images.digital-ocean;
        }
      );

      checks = forAllSystems (system: {
        inherit (self.packages.${system})
          bitcoind-knots-bin
          datum-gateway-convoy
          datum-gateway-iohzrd
          ratum-gateway
          node-wizard
          ;
      });
    };
}
