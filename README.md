# datum-node-image

A reproducible VPS image: a pruned **Bitcoin Knots** node plus a **DATUM
gateway**, built from a Nix flake anyone can rebuild and compare.

Bitcoin here is the chain with BLAKE2b proof of work (BIP-110), the one
Bitcoin Knots 29.4 follows. Bitcoin Core follows the sha256 chain and does
not work with this image. Flash it on a provider that imports images, or install it
from a rescue shell on one that does not.

Status: phase 2. The image boots to a browser setup page (Simplified Chinese
and English) that asks for a setup code, a password, the payout address, the
pool and a node name, then shows sync and mining status. No terminal needed.

## What is in the image

| Piece | Choice | Where |
|---|---|---|
| Node | Bitcoin Knots 29.4.2.knots20260508, the official Guix-built tarball from bitcoinknots.org, hashes as published in its SHA256SUMS, patched with autoPatchelf | `pkgs/bitcoind-knots-bin.nix` |
| Gateway | CONVOY's `datum_gateway` (default); iohzrd's build and the static `ratum-gateway` are packaged and selectable | `pkgs/datum-gateway.nix`, `pkgs/ratum-gateway.nix` |
| Pool | OmegaPool (default), Paperclip, Lazarus, CONVOY from `data/pools.nix`, public key pinned; solo or a custom pool from the setup page | `data/pools.nix` |
| Node settings | prune 10000, dbcache 1024, `blockmaxweight=785000`, block notifications by HTTP to the gateway, RPC cookie group-readable | `modules/blake2b-node.nix` |
| Gateway settings | stratum on 0.0.0.0:23334, dashboard on 127.0.0.1:7152, vardiff floor 16384, pooled mining only, hasher time rolling off | `modules/blake2b-node.nix` |
| Setup page | `node-wizard`, HTTPS on 443 (self-signed) with HTTP on 80 redirecting; writes the gateway's runtime settings, reads the node and gateway locally; runs as its own unprivileged user | `pkgs/node-wizard/`, `modules/node-wizard.nix` |
| Runtime overrides | `/var/lib/datum-wizard/gateway-settings.json` (written by the setup page), deep-merged over the static config at every gateway start | `modules/datum-gateway.nix` |
| Access | SSH key only (root and `admin`), cloud-init for provider metadata, firewall: 22, 80, 443, 7443, 8333, 23334 | `hosts/common.nix`, `modules/node-wizard.nix` |

## Build

```sh
# packages
nix build .#bitcoind-knots-bin .#datum-gateway-convoy .#datum-gateway-iohzrd .#ratum-gateway

# disk images (x86_64)
nix build .#image-qcow2      # qemu-efi: qcow2, UEFI  (LunaNode, local QEMU)
nix build .#image-raw-efi    # raw, UEFI              (Vultr)
nix build .#image-raw-bios   # raw, BIOS/GRUB         (DigitalOcean, older hypervisors)
```

The image is a few GB, sized to its contents; the root partition grows to the
VPS disk on first boot.

## Test locally

`scripts/qemu-test.sh` boots the qcow2 under KVM with UEFI firmware, a
cloud-init NoCloud seed and SSH forwarded to port 2222:

```sh
ssh-keygen -t ed25519 -N '' -f /tmp/testkey
printf '#cloud-config\nhostname: blake2b-test\nssh_authorized_keys:\n  - %s\n' "$(cat /tmp/testkey.pub)" > /tmp/user-data
printf 'instance-id: test-1\nlocal-hostname: blake2b-test\n' > /tmp/meta-data
nix shell nixpkgs#cdrkit -c genisoimage -quiet -output /tmp/seed.iso -volid cidata -joliet -rock /tmp/user-data /tmp/meta-data
nix build .#image-qcow2
scripts/qemu-test.sh result/*.qcow2 /tmp/seed.iso /tmp/vm
ssh -p 2222 -i /tmp/testkey root@localhost systemctl status bitcoind-blake2b datum-gateway
```

The image boots to SSH in about 15 seconds. Stop it with `kill $(cat /tmp/vm/qemu.pid)`.

## Deploy

**Image import (Vultr, LunaNode, DigitalOcean, Linode, ...):** upload the raw or
qcow2 file (or its URL) as a snapshot/custom image, deploy a server from it
with at least 4 GB RAM and 80 GB disk. cloud-init takes the SSH key and
hostname from the provider.

**Rescue mode (Hetzner, OVH, Scaleway, ...):** put your SSH public key in
`hosts/authorized-keys.nix`, boot the server into the provider's rescue
system, then from your machine:

```sh
nix run github:nix-community/nixos-anywhere -- --flake .#blake2b-vps-anywhere --target-host root@<ip>
```

Both paths end on the same NixOS configuration; the two host variants differ
only in how the disk is laid out.

## First boot

1. The server prints a **setup code** on its console (the provider's "View
   console" button) once a minute until setup is done, together with the URL
   to open. The code can also be pre-set by writing it to
   `/var/lib/node-wizard/setup-code` (for example with cloud-init `write_files`).
2. Open `https://<ip>/` in a browser. The certificate is self-signed, so the
   browser warns once; choose Advanced and continue.
3. Enter the setup code, choose a password, paste the payout address, pick a
   pool (or solo, or a custom pool with its public key) and an optional node
   name. The gateway starts by itself the moment this is saved; the node has
   been syncing since boot.
4. The status page shows the node (sync, peers, disk), the gateway (pool
   connection, hashrate with a 24-hour chart, miners, shares), what the pool
   reports for your address (share of the next block, payout per block, pool
   hashrate, blocks found, luck; OmegaPool, Paperclip and Lazarus publish this,
   the others get a link to their page), and the stratum URL to point miners at
   (`stratum+tcp://<ip>:23334`) with a QR code.

Everything can be changed later under Settings. The gateway's own dashboard
(per-miner tables, current job, its config page) is proxied at
`https://<ip>:7443/` for signed-in browsers; its protected pages ask for user
`admin` and the password shown under Settings > Advanced.

The setup page only ever writes `/var/lib/datum-wizard/gateway-settings.json`;
anything in the gateway's JSON schema can also be put there by hand, and the
gateway restarts when the file changes.

Useful commands on the box:

```sh
bcli getblockchaininfo            # bitcoin-cli against the node
journalctl -fu bitcoind-blake2b   # node log
journalctl -fu datum-gateway      # gateway log
```

## Fast start (assumeutxo)

With `services.blake2b-node.fastStart` enabled, the first boot downloads a
published UTXO snapshot instead of validating all history first:

```nix
services.blake2b-node.fastStart = {
  enable = true;
  height = 975000;                 # snapshot base height (in Knots' chainparams)
  blockhash = "0000...";           # block hash at that height
  utxoHash = "...";                # hash_serialized from dumptxoutset
  chainTxCount = 1300000000;       # nchaintx from dumptxoutset
  url = "https://example/utxo-975000.dat";
  sha256 = "...";                  # of the file
  sizeBytes = 9500000000;
};
```

What happens on the box: once bitcoind has the block headers past the
snapshot, a oneshot service downloads the file (resumable), checks its SHA256,
runs `loadtxoutset`, and deletes it. The node then serves templates as soon as
it catches up to the tip, usually under an hour on a 2 vCPU VPS, while the
full history is validated in the background over the following days. Any
failure (disk, download, checksum) leaves the node syncing normally. The
setup page shows each phase.

`loadtxoutset` only accepts snapshots whose height and hash are compiled into
Knots. Until the entry is merged upstream, `patchKnots = true` (the default)
builds Knots from nixpkgs' verified source with that one entry added
(`pkgs/bitcoind-knots-patched.nix`); set it to `false` once a Knots release
ships the entry, and the official release tarball is used again.

The snapshot itself comes from a synced unpruned node:
`bitcoin-cli -named dumptxoutset path=utxo.dat type=latest` prints the
height, block hash, UTXO hash and tx count to put in the options above.

## Configuration

Everything a template user would change is an option of
`services.blake2b-node`; set it in `hosts/common.nix` or a host file:

```nix
services.blake2b-node = {
  enable = true;
  gateway = "convoy";          # "convoy" | "iohzrd" | "ratum"
  pool = "convoy";             # a key of data/pools.nix, or "custom" + customPool
  prune = 10000;               # MiB; 550 minimum, >= 1100 with assumeutxo
  dbCache = 1024;              # 2048-4096 on an 8 GB box speeds up the sync
  payoutAddress = "";          # or leave empty and use settings.json
  coinbaseTag = "";
};
```

`services.datum-gateway` underneath can also be used on its own, with any
`services.bitcoind.<name>` instance.

## Reproducibility

Every input is pinned: nixpkgs by `flake.lock`, the node by the release
tarball's SHA256, the gateways by commit hash or release-asset SHA256. To
check that two machines agree:

```sh
nix build .#image-raw-efi --rebuild --keep-failed   # rebuilds and compares to the store copy
sha256sum result/*.img
```

Bit-for-bit reproducibility of the disk image itself is designed in by the
nixpkgs image builder but is not proven until two independent runners produce
the same hash; that is phase 4.

## Layout

```
flake.nix                 outputs: packages, nixosModules, nixosConfigurations, images
pkgs/                     bitcoind-knots-bin, datum-gateway (convoy|iohzrd), ratum-gateway
modules/datum-gateway.nix services.datum-gateway
modules/blake2b-node.nix  services.blake2b-node (the profile)
modules/node-wizard.nix   services.node-wizard (setup page + dashboard)
modules/fast-start.nix    services.blake2b-node.fastStart (assumeutxo at first boot)
pkgs/bitcoind-knots-patched.nix Knots from source with the snapshot in chainparams
pkgs/node-wizard/         the Go program behind it (templates, locales)
data/pools.nix            pinned pool endpoints and keys
hosts/common.nix          shared host config
hosts/image.nix           disk-image variant (system.build.images.*)
hosts/anywhere.nix        nixos-anywhere / disko variant
hosts/authorized-keys.nix your SSH keys (rescue-mode path)
```

## Roadmap

1. this flake: done, boot-tested under QEMU (UEFI and BIOS)
2. first-boot setup page (Simplified Chinese and English) on 443: done
3. recent assumeutxo snapshot, hash submitted to Knots; provider tests: in progress
4. reproducibility CI on two runners, published hashes and attestations
5. StartOS-via-CLI recipe and the templates proposal to Start9
