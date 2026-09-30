# The C DATUM gateway, in the two forks that speak the BLAKE2b chain.
#
#   convoy  - CONVOYMining/datum_gateway master (carries the BLAKE2b fixes first)
#   iohzrd  - iohzrd/datum_gateway at the commit some pools pin (AlphaPool)
#
# Both are OCEAN's datum_gateway 0.4.1 plus the fork's changes; same config schema.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  curl,
  jansson,
  libmicrohttpd,
  libsodium,
  variant ? "convoy",
}:
let
  variants = {
    convoy = {
      owner = "CONVOYMining";
      rev = "ac9b70c8b361f14e90e2c963b429a9bbb414aecb"; # master, 2026-09-26 "conf: Drop default vardiff_min to 1024"
      hash = "sha256-rStCvdFGduz1Jy4Tu+lsJMtE3p/ZesIvRcFOwVL9BIk=";
      version = "0.4.1-convoy-20260926";
    };
    iohzrd = {
      owner = "iohzrd";
      rev = "7491a5099dd5d887a027c812f71de63e0d5986a3"; # 2026-09-05, BLAKE2b coinbase weight-limit fix
      hash = "sha256-psc7LogLcqUREvLAI6jrAFSXv172dC9UIS0k0okGB28=";
      version = "0.4.1-iohzrd-20260905";
    };
  };
  v = variants.${variant} or (throw "datum-gateway: unknown variant ${variant}");
in
stdenv.mkDerivation {
  pname = "datum-gateway-${variant}";
  inherit (v) version;

  src = fetchFromGitHub {
    inherit (v) owner rev hash;
    repo = "datum_gateway";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
  ];
  buildInputs = [
    curl
    jansson
    libmicrohttpd
    libsodium
  ];

  # cmake/script/GenerateBuildInfo.cmake shells out to git unless told not to;
  # the fetched source has no .git directory.
  env.BITCOIN_GENBUILD_NO_GIT = "1";

  cmakeBuildType = "Release";

  meta = {
    description = "DATUM gateway (${variant} fork) for the BLAKE2b (BIP-110) chain";
    homepage = "https://github.com/${v.owner}/datum_gateway";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "datum_gateway";
  };
}
