# The C DATUM gateway, in the two builds that speak bitcoin's BLAKE2b proof of work.
#
#   convoy  - CONVOYMining/datum_gateway master (carries the BLAKE2b fixes first)
#   iohzrd  - iohzrd/datum_gateway at the commit some pools pin (AlphaPool)
#
# convoy is at its v0.5.0-beta; iohzrd is OCEAN's datum_gateway 0.4.1 plus its changes. Same config schema.
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
      rev = "69c61a95cb941c35138c30b8d738e789ad8cdac1"; # master, 2026-10-10 "Bump version to v0.5.0-beta"
      hash = "sha256-y2A0W3Wh57S7sBPEjb6+GOIiYHMmO7r3ztTwa/5Trk4=";
      version = "0.5.0-beta-convoy-20261010";
    };
    iohzrd = {
      owner = "iohzrd";
      rev = "76d748e8ba2069879e356b3d8b38b8785192f816"; # 2026-10-05, 164-byte BLAKE2b header in the coinbase weight limit, sigop limit on coinbaser outputs
      hash = "sha256-omlHZJLb8GgwQze2GYoSvTLSVwWQYe9Y8YWbzIlXtDo=";
      version = "0.4.1-iohzrd-20261005";
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
    description = "DATUM gateway for bitcoin (${variant} build)";
    homepage = "https://github.com/${v.owner}/datum_gateway";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "datum_gateway";
  };
}
