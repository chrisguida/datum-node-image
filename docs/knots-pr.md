# Knots PR: assumeutxo snapshot at height 975245

Patch: `knots-assumeutxo-975245.patch` (one entry appended to the mainnet
`m_assumeutxo_data` table in `src/kernel/chainparams.cpp`, branch `29.x-knots`).

## Title

chainparams: add assumeutxo snapshot at height 975245

## Body

Adds an assumeutxo entry for height 975245 so pruned nodes can start from a
recent snapshot instead of validating from genesis. The previous newest entry
(910000) predates the BLAKE2b proof-of-work activation at 961640, which left
about 65,000 blocks to validate after loading it.

Snapshot produced with `dumptxoutset` (`type=latest`) on a fully synced,
unpruned v29.4.2.knots20260508 node on 2026-10-02:

```
coins_written   167027210
base_height     975245
base_hash       0000000000000000ed0d972dbe57e3d8c5e80a5dd1963847196152bdb2f8f977
txoutset_hash   4cd38b1ce3f8d3753f716b99a16c85138a8d60102d9b3d532264c19c16c54a97
nchaintx        1417062280
```

File: `utxo-975245.dat`, 9,516,250,735 bytes,
SHA256 `64c775cf1072d9ce6b6908b9d2c122a365cf1954bcde90a35fdcf8911e15b94c`,
served at https://mb-beast.tail4a715.ts.net:8443/datum-node-image/utxo-975245.dat
(a torrent will follow).

To verify independently on a synced node:

```
bitcoin-cli -rpcclienttimeout=0 -named dumptxoutset path=check.dat rollback=975245
```

and compare `txoutset_hash` and `nchaintx` with the values above. To exercise
the entry, build with the patch, start a fresh node, wait for the headers,
then `bitcoin-cli -rpcclienttimeout=0 loadtxoutset /path/to/utxo-975245.dat`.

The entry is used by the datum-node-image project (a VPS image with a pruned
Knots node and a DATUM gateway); until it is released the image builds Knots
from source with this patch.
