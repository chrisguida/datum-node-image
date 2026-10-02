# ratum-gateway: iohzrd's Rust reimplementation of the C DATUM gateway, shipped
# as a static musl binary. Reads the C gateway's JSON config unchanged.
{
  lib,
  stdenv,
  fetchurl,
}:
let
  version = "0.1.57";
  perSystem = {
    x86_64-linux = {
      arch = "x86_64";
      sha256 = "64aaf929b2071530a0263a6b0d5b85d347dc6f48543c96706f8a315408818b23";
    };
    aarch64-linux = {
      arch = "aarch64";
      sha256 = "83487458bad0fd8e2bc10dac8b8474816165b5839093cf57d434c6d08cf4830b";
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
