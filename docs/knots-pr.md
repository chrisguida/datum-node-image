# Knots PR: assumeutxo snapshot at height 976000

Opened 2026-10-07: https://github.com/bitcoinknots/bitcoin/pull/444 (companion backport: https://github.com/bitcoinknots/bitcoin/pull/443)

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
SHA256 `bfd2460a55ae1d2e94b9957ccd512ae027855feed1dbef996cfed0abebe5d123`,
served at https://mb-beast.tail4a715.ts.net:8443/datum-node-image/utxo-976000.dat
with `SHA256SUMS` and `utxo-976000.dat.torrent` next to it. Torrent (the HTTPS URL above is
its web seed, so it works even with no other peers):

```
magnet:?xt=urn:btih:3cf7e4d15841f116856f6f19bf2ac15b1dbae2c3&dn=utxo-976000.dat&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce&tr=udp%3A%2F%2Fexodus.desync.com%3A6969%2Fannounce&ws=https%3A%2F%2Fmb-beast.tail4a715.ts.net%3A8443%2Fdatum-node-image%2Futxo-976000.dat
```

## How to verify (reviewers)

You need a synced Knots 29.4.x node that still has the blocks from 976000 to
its tip (any unpruned node; a pruned one only if it has not pruned past 976000).

1. Recompute the UTXO set hash at height 976000:

   ```
   bitcoin-cli -rpcclienttimeout=0 -named dumptxoutset path=check-976000.dat rollback=976000
   ```

   Two ways to run it:

   a) Stock 29.4.2: network activity pauses and the node rolls back temporarily
      (123 s for 59 blocks on an NVMe disk; slower the further the tip has moved
      away from 976000, so do it soon).

   b) Node stays online: build the companion backport of bitcoin/bitcoin#33477
      (bitcoinknots/bitcoin#443) first. A branch with this entry on top of it is at

      ```
      git fetch https://github.com/chrisguida/bitcoin assumeutxo-976000-online && git checkout FETCH_HEAD
      ```

      then run the same command; add `in_memory=true` on a machine with more
      than 12 GB of RAM. An assumeutxo node cannot roll back to its own base
      height until background validation has passed it, so use a full node.

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
