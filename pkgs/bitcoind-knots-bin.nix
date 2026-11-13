# Bitcoin Knots, the official Guix-built release tarball from bitcoinknots.org.
#
# Hashes are the ones published in SHA256SUMS next to the tarballs
# (https://bitcoinknots.org/files/29.x/29.5.knots20260508/SHA256SUMS), which
# are themselves attested in https://github.com/bitcoinknots/guix.sigs.
{ callPackage }:
let
  version = "29.5.knots20260508";
  base = "https://bitcoinknots.org/files/29.x/${version}";
in
callPackage ./knots-tarball.nix { } {
  pname = "bitcoind-knots-bin";
  inherit version;
  perSystem = {
    x86_64-linux = {
      url = "${base}/bitcoin-${version}-x86_64-linux-gnu.tar.gz";
      sha256 = "2e0c1a9f52d76ed1fa8ad3efce5d52dfacae1dfb161558c85ef37c9379ba3d13";
    };
    aarch64-linux = {
      url = "${base}/bitcoin-${version}-aarch64-linux-gnu.tar.gz";
      sha256 = "47eb609d25f6de326dd0caaaab2cc093c3cc05540e18f203a6d8f60e33277569";
    };
  };
  description = "Bitcoin Knots (official release binaries)";
  assumeutxoHeights = [ 840000 880000 910000 976000 ];
}
