# Bitcoin Knots 29.4.2 plus exactly one commit, the assumeutxo entry at height 976,000
# (bitcoinknots/bitcoin#444, commit 6ce57028d6cf), as a Guix build released at
# https://github.com/chrisguida/bitcoin/releases/tag/v29.4.2.knots20260508-assumeutxo976000.
#
# The sha256 is the one in that release's SHA256SUMS, attested by two independent Guix
# reproductions on https://github.com/chrisguida/guix.sigs/tree/assumeutxo976000. The build
# prints the same version string as the official 29.4.2; only the chainparams entry differs.
# Obsolete the day a Knots tag carries the entry: then pkgs/bitcoind-knots-bin.nix moves to it.
{ callPackage }:
callPackage ./knots-tarball.nix { } {
  pname = "bitcoind-knots-976000-bin";
  version = "29.4.2.knots20260508";
  perSystem = {
    x86_64-linux = {
      url = "https://github.com/chrisguida/bitcoin/releases/download/v29.4.2.knots20260508-assumeutxo976000/bitcoin-6ce57028d6cf-x86_64-linux-gnu.tar.gz";
      sha256 = "5c26890d72daa499fe22b905de5cfb0a78e2445aedbde0726278f57672106a9d";
    };
  };
  description = "Bitcoin Knots 29.4.2 + the 976,000 assumeutxo entry (#444), Guix build with two attestations";
  homepage = "https://github.com/chrisguida/bitcoin/releases/tag/v29.4.2.knots20260508-assumeutxo976000";
  assumeutxoHeights = [ 840000 880000 910000 976000 ];
}
