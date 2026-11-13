# ratum-gateway: iohzrd's Rust reimplementation of the C DATUM gateway, shipped
# as a static musl binary. Reads the C gateway's JSON config unchanged.
{
  lib,
  stdenv,
  fetchurl,
}:
let
  version = "0.1.74";
  perSystem = {
    x86_64-linux = {
      arch = "x86_64";
      sha256 = "e55e92502fba17923023dd9550c8fa601d1680b4fc233035465765587eb71c15";
    };
    aarch64-linux = {
      arch = "aarch64";
      sha256 = "281b3b111ac6958530cad507fb3b6ef6d61621bf68225778a1d6c4d776d45d98";
    };
  };
  s =
    perSystem.${stdenv.hostPlatform.system}
      or (throw "ratum-gateway: no release binary for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "ratum-gateway";
  inherit version;

  src = fetchurl {
    url = "https://github.com/iohzrd/ratum/releases/download/v${version}/ratum-gateway-${version}-${s.arch}-linux-musl.tar.gz";
    inherit (s) sha256;
  };

  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true; # static-pie, nothing to patch
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 ratum-gateway $out/bin/ratum-gateway
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/ratum-gateway --version | grep -F "${version}"
  '';

  meta = {
    description = "DATUM gateway for bitcoin, Rust implementation (static binary)";
    homepage = "https://github.com/iohzrd/ratum";
    license = lib.licenses.mit;
    platforms = builtins.attrNames perSystem;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "ratum-gateway";
  };
}
