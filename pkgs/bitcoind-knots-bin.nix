# Bitcoin Knots, the official Guix-built release tarball from bitcoinknots.org.
#
# Hashes are the ones published in SHA256SUMS next to the tarballs
# (https://bitcoinknots.org/files/29.x/29.4.2.knots20260508/SHA256SUMS), which
# are themselves attested in https://github.com/bitcoinknots/guix.sigs.
{ callPackage }:
let
  version = "29.4.2.knots20260508";
  base = "https://bitcoinknots.org/files/29.x/${version}";
in
callPackage ./knots-tarball.nix { } {
  pname = "bitcoind-knots-bin";
  inherit version;
  perSystem = {
    x86_64-linux = {
      url = "${base}/bitcoin-${version}-x86_64-linux-gnu.tar.gz";
      sha256 = "b59d0445a317e21a03dc29425db3aba79b27d5125230b1a2b1dce62e120827c5";
    };
    aarch64-linux = {
      url = "${base}/bitcoin-${version}-aarch64-linux-gnu.tar.gz";
      sha256 = "e50c5717e834a68a324d0e8e2fdc097cb3c9ff38cd69ce2caf9360d1e24aa69a";
    };
  };
  description = "Bitcoin Knots (official release binaries)";
  assumeutxoHeights = [ 840000 880000 910000 ];
}
