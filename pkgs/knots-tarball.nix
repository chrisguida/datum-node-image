# A Bitcoin Knots release tarball (a Guix build, attested in a guix.sigs repository), patched with
# autoPatchelf so the attested binary is what runs on NixOS. Instantiated by pkgs/bitcoind-knots-bin.nix
# (the official release) and pkgs/bitcoind-knots-976000-bin.nix (29.4.2 plus the 976,000 assumeutxo
# entry, bitcoinknots/bitcoin#444, built and attested ahead of a Knots tag).
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
{
  pname,
  version, # what `bitcoind --version` prints, checked after install
  perSystem, # { <system> = { url; sha256; }; }
  description,
  homepage ? "https://bitcoinknots.org/",
  assumeutxoHeights, # the snapshot heights compiled into this build's mainnet chainparams
}:
let
  s =
    perSystem.${stdenv.hostPlatform.system}
      or (throw "${pname}: no release tarball for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  inherit pname version;

  src = fetchurl { inherit (s) url sha256; };

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

  passthru = { inherit assumeutxoHeights; };

  meta = {
    inherit description homepage;
    license = lib.licenses.mit;
    platforms = builtins.attrNames perSystem;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "bitcoind";
  };
}
