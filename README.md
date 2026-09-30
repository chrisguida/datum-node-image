# datum-node-image

A reproducible VPS image: a pruned **Bitcoin Knots** node on the BLAKE2b
(BIP-110) chain plus a **DATUM gateway**, built from a Nix flake anyone can
rebuild and compare. Flash it on a provider that imports images, or install it
from a rescue shell on one that does not.

Status: phase 1 (the flake, the packages, the image variants). No setup wizard
yet; the payout address is set through a JSON file (see "First boot").

## What is in the image

| Piece | Choice | Where |
|---|---|---|
| Node | Bitcoin Knots 29.4.2.knots20260508, the official Guix-built tarball from bitcoinknots.org, hashes as published in its SHA256SUMS, patched with autoPatchelf | `pkgs/bitcoind-knots-bin.nix` |
| Gateway | CONVOY's `datum_gateway` (default); iohzrd's fork and the static `ratum-gateway` are packaged and selectable | `pkgs/datum-gateway.nix`, `pkgs/ratum-gateway.nix` |
| Pool | picked from `data/pools.nix`, public key pinned | `data/pools.nix` |
| Node settings | prune 10000, dbcache 1024, `blockmaxweight=785000`, block notifications by HTTP to the gateway, RPC cookie group-readable | `modules/blake2b-node.nix` |
| Gateway settings | stratum on 0.0.0.0:23334, dashboard on 127.0.0.1:7152, vardiff floor 16384, pooled mining only, hasher time rolling off | `modules/blake2b-node.nix` |
| Runtime overrides | `/var/lib/datum-gateway/settings.json`, deep-merged over the static config at every start | `modules/datum-gateway.nix` |
| Access | SSH key only (root and `admin`), cloud-init for provider metadata, firewall: 22, 8333, 23334 | `hosts/common.nix` |

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

The node starts syncing on its own. The gateway waits until it has a payout
address, then starts by itself:

```sh
sudo tee /var/lib/datum-gateway/settings.json <<'EOF'
{ "mining": { "pool_address": "bc1q...", "coinbase_tag_secondary": "my node" } }
EOF
```

Anything in the gateway's JSON schema can go in that file; it wins over the
static config. The gateway's dashboard is on `http://127.0.0.1:7152` (admin
password in `/var/lib/datum-gateway/admin-password`); reach it over an SSH
tunnel. Point miners at `stratum+tcp://<ip>:23334`.

Useful commands on the box:

```sh
bcli getblockchaininfo            # bitcoin-cli against the node
journalctl -fu bitcoind-blake2b   # node log
journalctl -fu datum-gateway      # gateway log
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

## Layout

```
flake.nix                 outputs: packages, nixosModules, nixosConfigurations, images
pkgs/                     bitcoind-knots-bin, datum-gateway (convoy|iohzrd), ratum-gateway
modules/datum-gateway.nix services.datum-gateway
modules/blake2b-node.nix  services.blake2b-node (the profile)
data/pools.nix            pinned pool endpoints and keys
hosts/common.nix          shared host config
hosts/image.nix           disk-image variant (system.build.images.*)
hosts/anywhere.nix        nixos-anywhere / disko variant
hosts/authorized-keys.nix your SSH keys (rescue-mode path)
```

## Roadmap

1. this flake (done when the image boots and mines)
2. first-boot wizard (Simplified Chinese and English) behind TLS on 443
3. assumeutxo snapshot at the fork point, hash submitted to Knots; provider tests
4. reproducibility CI on two runners, published hashes and attestations
5. StartOS-via-CLI recipe and the templates proposal to Start9
