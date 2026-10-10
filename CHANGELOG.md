# Changelog

## Unreleased

- Bitcoin Knots runs from the attested Guix tarballs, not a source build: the official 29.4.2 and
  29.4.2 + the 976,000 assumeutxo entry (#444, two attestations on chrisguida/guix.sigs branch
  assumeutxo976000) are both in the image; the second is the default.
- The 976,000 snapshot torrent ships inside the image, with AlphaPool's server as web seed and
  https fallback; the 910,000 torrent is included too. Nothing points at a home machine any more.
- Reproducible disk images: a vendored nixpkgs builder with a fixed ext4 hash seed, a fixed VM
  clock and zeroed superblock timestamps (`lib/make-disk-image.nix`, `modules/deterministic-image.nix`).
- 4 GB VPS tuning: dbcache 600, zram a quarter of RAM with swappiness 10, bitcoind upload target
  10 GB/day. A 1024 MiB dbcache with half of RAM as zram had the UTXO cache living in swap.
- RIPTIDE (Maveth) added to the pinned pools.
- `docs/releasing.md`: how a release is cut, reproduced and attested.

## 2026-10-07

- Fast start downloads the snapshot before waiting for block headers; aria2 listens on a port range.

## 2026-10-05

- Published. Phases 1 to 3: the flake, the bilingual first-boot wizard, the 976,000 assumeutxo fast start.
