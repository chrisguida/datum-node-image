# Bitcoin Knots built from source (nixpkgs' verified tarball) with one extra
# assumeutxo entry in the mainnet chainparams: the snapshot this image ships.
#
# Needed only until the entry is merged upstream in Knots; then the official
# release tarball (pkgs/bitcoind-knots-bin.nix) takes over again.
{
  lib,
  bitcoind-knots,
  python3,
}:
{
  height,
  blockhash,
  utxoHash,
  chainTxCount,
}:
let
  entry = ''
    ,
                {
                    .height = ${toString height},
                    .hash_serialized = AssumeutxoHash{uint256{"${utxoHash}"}},
                    .m_chain_tx_count = ${toString chainTxCount},
                    .blockhash = consteval_ctor(uint256{"${blockhash}"}),
                }'';
in
bitcoind-knots.overrideAttrs (old: {
  pname = "bitcoind-knots-assumeutxo-${toString height}";
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ python3 ];
  postPatch = (old.postPatch or "") + ''
    python3 - <<'PY'
    import re, sys
    p = "src/kernel/chainparams.cpp"
    s = open(p).read()
    # the mainnet table: everything from "m_assumeutxo_data = {" up to its closing "};"
    m = re.search(r"m_assumeutxo_data = \{(.*?)\n        \};", s, flags=re.S)
    if not m or "840'000" not in m.group(1):
        sys.exit("mainnet assumeutxo table not found")
    table = m.group(1).rstrip()
    if '"${blockhash}"' in table:
        sys.exit(0)  # already upstream
    assert table.endswith("}")
    new = table + ${builtins.toJSON entry}
    s = s[:m.start(1)] + new + "\n        };" + s[m.end():]
    open(p, "w").write(s)
    PY
    grep -q '${blockhash}' src/kernel/chainparams.cpp
  '';
  meta = old.meta // {
    description = "Bitcoin Knots with the image's assumeutxo snapshot (height ${toString height}) in chainparams";
  };
})
