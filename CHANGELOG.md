# Changelog

## v2026.11.1-rc2 (2026-11-12)

rc1 was tagged but never published: it still ran Knots 29.4.2.

- Bitcoin Knots 29.5, the official release tarball, is the only bundled build. 29.4.2 does not
  enforce the long coinbase maturity softfork as extended in 29.4.3 and must not run past block
  979,919. 29.5 carries the 976,000 assumeutxo entry, so the 29.4.2 + #444 build is gone; a node
  updated from an October image falls back to `official`.
- DATUM gateway: CONVOY v0.5.0-beta (2026-10-10); the iohzrd build at its 2026-10-05 head;
  ratum-gateway 0.1.74.

## v2026.11.1-rc1 (2026-11-12)

First release candidate (not published). It replaces the unpublished v2026.10.1-rc1 draft, whose
image carried a kernel open to CVE-2026-98432.

- Kernel 6.18.63 (nixpkgs 2026-11-11). CVE-2026-98432, remote root through IPv4 options on a TCP
  SYN, is fixed from 6.18.56; the October images ran 6.18.54.
- One generic image for every provider: boots from BIOS and UEFI, in three containers (raw, gzip,
  qcow2) as `.#image-generic`, `.#image-generic-gz` and `.#image-generic-qcow2`.
- cloud-init without the provider's vendor data and without the disk and mount modules, and the
  SSH host keys are left to NixOS: no failed unit on first boot.
- Updating from the setup page: switch between the two bundled Knots builds, or move the running
  system to a signed release tag (`node-updater`), with a rollback.
- `/etc/datum-node-image/image.json` records the flake revision and the image variant.
- `docs/install.md`: installing on DigitalOcean (import and in place), Vultr and LunaNode.
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
