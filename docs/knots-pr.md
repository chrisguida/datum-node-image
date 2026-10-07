# Knots PR: assumeutxo snapshot at height 976000

Patch: `knots-assumeutxo-976000.patch` (one entry appended to the mainnet
`m_assumeutxo_data` table in `src/kernel/chainparams.cpp`, branch `29.x-knots`).
Local branch: `~/projects/claude/knots-pr/bitcoin` → `assumeutxo-976000`
(remote `chris` = github.com/chrisguida/bitcoin). Target: bitcoinknots/bitcoin `29.x-knots`.

## Title

chainparams: add assumeutxo snapshot at height 976000

## Body

Adds an assumeutxo entry for height 976000 so pruned nodes can start from a
recent snapshot instead of validating from genesis. The previous newest entry
(910000) predates the BLAKE2b proof-of-work activation at 961640, which left
about 65,000 blocks to validate after loading it. 976000 is below the long
coinbase maturity flag day (979920, #429), so the snapshot is identical under
29.4.2 and the next release.

Snapshot produced with `dumptxoutset rollback=976000` on a fully synced,
unpruned v29.4.2.knots20260508 node on 2026-10-07 (123 s):

```
coins_written   167095701
base_height     976000
base_hash       000000000000000098441aee029573795681eb1602c75271e809b136e9217373
txoutset_hash   dbd67717d3f108e4fbd8b4f9efc4057cac11a0ba7c23584b43cca42c9edb7118
nchaintx        1417215373
```

File: `utxo-976000.dat`, 9,517,597,408 bytes,
SHA256 `<<SHA256 — filled in once the file is published>>`,
served at https://mb-beast.tail4a715.ts.net:8443/datum-node-image/utxo-976000.dat
and as a torrent: `<<magnet — filled in once seeded>>`.

## How to verify (reviewers)

You need a synced Knots 29.4.x node that still has the blocks from 976000 to
its tip (any unpruned node; a pruned one only if it has not pruned past 976000).

1. Recompute the UTXO set hash at height 976000:

   ```
   bitcoin-cli -rpcclienttimeout=0 -named dumptxoutset path=check-976000.dat rollback=976000
   ```

   On 29.4.2 this pauses network activity and rolls the node back temporarily;
   it took 123 s for 59 blocks on an NVMe disk and gets slower the further the
   tip moves away, so do it soon. With the companion backport of bitcoin/bitcoin#33477
   the rollback runs on a copy of the chainstate, the node stays online, and
   `in_memory=true` makes it faster on a machine with more than 12 GB of RAM.

2. Compare the result with this entry. Expected:

   ```
   base_height     976000
   base_hash       000000000000000098441aee029573795681eb1602c75271e809b136e9217373
   txoutset_hash   dbd67717d3f108e4fbd8b4f9efc4057cac11a0ba7c23584b43cca42c9edb7118
   nchaintx        1417215373
   coins_written   167095701
   ```

   `txoutset_hash` is `hash_serialized`, `nchaintx` is `m_chain_tx_count`. Post an
   ACK with the values you got.

3. Optional: check the published file. `sha256sum utxo-976000.dat` must print the
   SHA256 above. Loading it with `loadtxoutset` on a node built from this branch
   also verifies the serialized hash against the entry and refuses a mismatch.

The entry is used by the datum-node-image project (a VPS image with a pruned
Knots node and a DATUM gateway); until it is released the image builds Knots
from source with this patch.
