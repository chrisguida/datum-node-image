# Bitcoin Knots, the official Guix-built release tarball from bitcoinknots.org,
# patched with autoPatchelf so the attested binary is what runs on NixOS.
#
# Hashes are the ones published in SHA256SUMS next to the tarballs
# (https://bitcoinknots.org/files/29.x/29.4.2.knots20260508/SHA256SUMS), which
# are themselves attested in https://github.com/bitcoinknots/guix.sigs.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
let
  version = "29.4.2.knots20260508";
  series = "29.x";
  perSystem = {
    x86_64-linux = {
      arch = "x86_64";
      sha256 = "b59d0445a317e21a03dc29425db3aba79b27d5125230b1a2b1dce62e120827c5";
    };
    aarch64-linux = {
      arch = "aarch64";
      sha256 = "e50c5717e834a68a324d0e8e2fdc097cb3c9ff38cd69ce2caf9360d1e24aa69a";
    };
  };
  s =
    perSystem.${stdenv.hostPlatform.system}
      or (throw "bitcoind-knots-bin: no release tarball for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "bitcoind-knots-bin";
  inherit version;

  src = fetchurl {
    url = "https://bitcoinknots.org/files/${series}/${version}/bitcoin-${version}-${s.arch}-linux-gnu.tar.gz";
    inherit (s) sha256;
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/doc/bitcoind-knots
    for b in bitcoind bitcoin-cli bitcoin-tx bitcoin-util bitcoin-wallet; do
      install -m755 bin/$b $out/bin/$b
    done
    cp README.md $out/share/doc/bitcoind-knots/ 2>/dev/null || true
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    # bitcoind creates its datadir even for --version; keep it out of HOME
    HOME=$TMPDIR $out/bin/bitcoind -datadir=$TMPDIR --version | head -1 | grep -F "${version}"
    $out/bin/bitcoin-cli --version | head -1 | grep -F "${version}"
  '';

  meta = {
    description = "Bitcoin Knots (official release binaries)";
    homepage = "https://bitcoinknots.org/";
    license = lib.licenses.mit;
    platforms = builtins.attrNames perSystem;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "bitcoind";
  };
}
