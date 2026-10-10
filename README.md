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
| Node | Bitcoin Knots 29.4.2.knots20260508, two attested Guix tarballs bundled: the official one from bitcoinknots.org and the same release plus the 976,000 assumeutxo entry (runs by default); switchable at runtime from the setup page | `pkgs/bitcoind-knots-bin.nix`, `pkgs/bitcoind-knots-976000-bin.nix` |
| Gateway | CONVOY's `datum_gateway` (default); iohzrd's build and the static `ratum-gateway` are packaged and selectable | `pkgs/datum-gateway.nix`, `pkgs/ratum-gateway.nix` |
| Pool | OmegaPool (default), Paperclip, Lazarus, CONVOY from `data/pools.nix`, public key pinned; solo or a custom pool from the setup page | `data/pools.nix` |
| Node settings | prune 10000, dbcache 1024, `blockmaxweight=785000`, block notifications by HTTP to the gateway, RPC cookie group-readable | `modules/blake2b-node.nix` |
| Gateway settings | stratum on 0.0.0.0:23334, dashboard on 127.0.0.1:7152, vardiff floor 16384, pooled mining only, hasher time rolling off | `modules/blake2b-node.nix` |
| Setup page | `node-wizard`, HTTPS on 443 (self-signed) with HTTP on 80 redirecting; writes the gateway's runtime settings, reads the node and gateway locally; runs as its own unprivileged user | `pkgs/node-wizard/`, `modules/node-wizard.nix` |
| Runtime overrides | `/var/lib/datum-wizard/gateway-settings.json` (written by the setup page), deep-merged over the static config at every gateway start | `modules/datum-gateway.nix` |
| Updates | the setup page switches the Knots build (selector file + node restart) and updates the whole image to a signed release tag (`node-updater`: verify, build, switch, roll back if the node stays down) | `modules/node-updater.nix`, `data/release-keys/` |
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

## Updating

Both kinds of update are done from the setup page, **Update** in the top bar
(Chinese and English). Nothing there needs a terminal; the equivalent commands
are given for people who prefer one.

### Switching the Knots build

The image bundles more than one Bitcoin Knots build
(`services.blake2b-node.knotsBuilds`); today these two, both attested Guix
tarballs:

| Name | What | Snapshot heights it knows |
|---|---|---|
| `assumeutxo-976000` (default) | 29.4.2 plus the 976,000 assumeutxo entry ([bitcoinknots/bitcoin#444](https://github.com/bitcoinknots/bitcoin/pull/444)) | 840000, 880000, 910000, 976000 |
| `official` | the unmodified 29.4.2 release from bitcoinknots.org | 840000, 880000, 910000 |

`bitcoind` is a small wrapper: at every start it reads
`/var/lib/datum-wizard/knots-build` (one line, a build name; missing or
unknown means the default) and runs that build. The Update page shows which
build runs, which one the next start would use, and a **Switch** button per
other build; switching writes the selector and restarts
`bitcoind-blake2b.service` (the gateway pauses for a few minutes). By hand:

```sh
echo official > /var/lib/datum-wizard/knots-build && systemctl restart bitcoind-blake2b
```

**The guard.** A node that started from a UTXO snapshot keeps a second
("snapshot") chainstate until the full history has been validated in the
background and the node has restarted once. In that period it can only run a
build whose chainparams carry that snapshot; any other build stops at startup
with `Assumeutxo data not found for the given blockhash`. The page reads
`getchainstates`, maps the snapshot block to its height, and disables the
Switch button of any build that lacks the entry, saying why. Once the status
page's fast-start line is gone (validation finished, node restarted), every
build is available. If you switch by hand, check the same thing first:
`bcli getchainstates` must show one chainstate, or the target build must list
the snapshot height in `/etc/datum-node-image/knots-builds.json`.

### Updating the image to a release

Releases are **signed git tags** of this repository
(`git tag -s vX.Y.Z`). The keys allowed to sign them are in
`data/release-keys/*.asc`, which the image installs at
`/etc/datum-node-image/release-keys`. The Update page lists the GitHub
releases (tag, date, first lines of the notes) with an **Update to** button,
plus a field for any tag name. Pressing it writes
`/var/lib/datum-wizard/update-request` and starts `node-updater.service`,
which

1. fetches the tag (shallow) into `/var/lib/node-updater/repo` and runs
   `git verify-tag` against a keyring built from the release keys of the
   image that is running right now; anything unsigned, or signed by another
   key, is refused;
2. builds this machine's variant (`/etc/datum-node-image/image.json` says
   which: `digital-ocean`, `qemu-efi`, `raw-efi`, `raw` or `anywhere`) from
   the tag with `nix build --max-jobs 1`, so the node keeps running;
3. sets the system profile to the result and runs `switch-to-configuration
   switch`;
4. waits up to 90 s for `bitcoind-blake2b.service` to be active and 30 s more
   for it to stay up; if not, switches back to the previous generation and
   resets the profile to it.

Progress is in `/var/lib/node-updater/status` (JSON: state, message, tag,
timestamp) and `/var/lib/node-updater/last.log`; the page polls both. The
setup page itself may be restarted by the switch, which signs the browser
out; the update continues. By hand:

```sh
echo v1.2.0 > /var/lib/datum-wizard/update-request && systemctl start --no-block node-updater
tail -f /var/lib/node-updater/last.log
```

The setup page runs unprivileged; a polkit rule lets its user restart
`bitcoind-blake2b.service` and start `node-updater.service`, nothing else.

### Rolling back by hand

Every update is a new NixOS generation; the old ones stay until garbage
collected.

```sh
nix-env -p /nix/var/nix/profiles/system --list-generations
nixos-rebuild switch --rollback            # previous generation, or:
nix-env -p /nix/var/nix/profiles/system --switch-generation 12
/nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

A Knots build switch is not a generation: put the previous name back in
`/var/lib/datum-wizard/knots-build` (or delete the file for the default) and
restart `bitcoind-blake2b`.

### Making a release

Tag with a key listed in `data/release-keys` of the images already out there
(a new key only becomes trusted by images built after it was added), push the
tag, and publish a GitHub release for it so the page lists it:

```sh
git tag -s v1.2.0 -m "v1.2.0"
git push origin v1.2.0
```

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

## Known issues and caveats (2026-10-05)

- **Snapshot hosting is temporary and slow.** The fast start downloads the
  UTXO snapshot from a Tailscale Funnel on a home machine at about 1.4 MB/s,
  so that phase takes about two hours instead of ten minutes. Proper hosting
  (a torrent with an HTTP web seed, or object storage) is next. In the one
  real VPS test so far the file was pushed to the server directly and the
  rest of the fast start took 44 minutes from power-on to a mining-ready node.
- **The default Knots build is not an official release.** `loadtxoutset` only
  accepts snapshots whose hash is compiled into Knots, so the build that runs
  by default is 29.4.2 plus one chainparams commit
  ([bitcoinknots/bitcoin#444](https://github.com/bitcoinknots/bitcoin/pull/444)),
  a Guix build with two attestations rather than a source build. The official
  29.4.2 is bundled too and can be switched to from the setup page once the
  snapshot's background validation is done (see Updating); when a Knots
  release carries the entry, it replaces both.
- **The image is not yet bit-for-bit reproducible.** Two builds differ because
  nixpkgs' image builder leaves the ext4 directory hash seed random and writes
  build-time timestamps into the boot partition. Fixes are identified, not
  applied; see the roadmap.
- **4 GB of RAM is the floor** with the current fixed settings; 2 GB plans
  need the first-boot auto-sizing that is still to be written.
- **Self-signed certificate.** The setup page cannot get a trusted certificate
  without a domain, so browsers warn once.
- **Pools:** OmegaPool, Paperclip, Lazarus and CONVOY are pinned; Maveth's
  RIPTIDE is missing because it does not publish its DATUM key. Pools can add
  themselves by pull request to `data/pools.nix` (host, port, pinned key).
- **Tested providers:** DigitalOcean (image import) and local QEMU. Vultr,
  LunaNode and the Hetzner rescue-mode path are untested.

## Layout

```
flake.nix                 outputs: packages, nixosModules, nixosConfigurations, images
pkgs/                     bitcoind-knots-bin, datum-gateway (convoy|iohzrd), ratum-gateway
modules/datum-gateway.nix services.datum-gateway
modules/blake2b-node.nix  services.blake2b-node (the profile)
modules/node-wizard.nix   services.node-wizard (setup page + dashboard)
modules/fast-start.nix    services.blake2b-node.fastStart (assumeutxo at first boot)
modules/image-info.nix    datum-node-image.{rev,variant} -> /etc/datum-node-image/image.json
modules/node-updater.nix  services.node-updater (update to a signed release tag from the setup page)
data/release-keys/        OpenPGP keys that may sign release tags
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
