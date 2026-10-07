# Knots PR: dumptxoutset rollback without invalidating blocks (backport of bitcoin/bitcoin#33477)

Opened 2026-10-07: https://github.com/bitcoinknots/bitcoin/pull/443 (used by https://github.com/bitcoinknots/bitcoin/pull/444)

Local branch: `~/projects/claude/knots-pr/bitcoin` → `dumptxoutset-rollback-copy` (3 commits on `29.x-knots`).
Target: bitcoinknots/bitcoin `29.x-knots`. Companion to the assumeutxo PR (`knots-pr.md`).

## Title

rpc: dumptxoutset rollback without invalidating blocks (backport of #33477)

## Body

Backport of bitcoin/bitcoin#33477 (fjahr, merged 2026-04-19) to 29.x-knots.

`dumptxoutset` with `rollback` currently invalidates blocks down to the target height,
suspends network activity, writes the snapshot and reconsiders the blocks. While it runs
the node is in a state that does not reflect reality, it cannot serve peers or follow the
chain, and a fork at the target height makes it fail. Reviewing an assumeutxo chainparams
entry means running exactly this on a synced node, which discourages people from doing it.

With this change the RPC copies the UTXO set into a temporary database, disconnects blocks
on that copy down to the target height, computes the snapshot from the copy and deletes
it. The node keeps running normally. A temporary prune lock keeps the needed block data on
pruned nodes. The new `in_memory=true` option keeps the temporary database in RAM (more
than 10 GB on mainnet) and is faster.

Deep rollbacks are slower than before (upstream measured 9m16s vs 3m17s for ~1500 blocks
on disk) but the time no longer depends on the state of the main chain, and the node stays
online.

Adapted to Knots' human-readable `dumptxoutset` format: the rolled-back dump takes the
same `format`, `show_header` and `separator` arguments as the tip dump. The functional
tests that checked the network-activity handling are dropped (there is nothing to suspend
any more); the upstream fork test and the in-memory case are added, and the sqlite tool
test exercises the rollback path.

Commits:
- rpc: Don't invalidate blocks in dumptxoutset (49d5e835a8 + fc736013a5)
- test: Add dumptxoutset fork test (ab9463efac)
- test: Extend named pipe sqlite tool test to use rollback (d0fd718948)

Motivation: makes verifying the assumeutxo snapshot in bitcoinknots/bitcoin#444 a background
operation on any synced node.

## Testing done

- Built on Ubuntu 26.04 (g++ 15.2, cmake 4.2.3, boost 1.90) on 2026-10-07.
- `test/functional/rpc_dumptxoutset.py` and `tool_utxo_to_sqlite.py` pass (python 3.14).
- Mainnet (2026-10-07, mb-beast node2: pruned assumeutxo node, snapshot at 976000, tip 976069):
  `dumptxoutset rollback=976001` with the node online (10 peers): disk 784 s (9.1 GB temp DB,
  cleaned up), in_memory=true 473 s, both txoutset_hash ed7dfbf6…fb98 / nchaintx 1417215824.
  rollback=976000 is refused on that node (base block has no undo data until background
  validation reaches it) — same check as before the backport.
