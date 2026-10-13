# Releasing an image

A release is a signed git tag, the images built from it, their hashes, and the signatures of
whoever rebuilt them. Nothing in a release is produced by a service: every artifact is a
`nix build` of the tag that anyone can repeat, and the hashes must come out the same.

## Cut

1. Bump what the release changes (Knots tarball pins in `pkgs/`, snapshot pins in
   `hosts/common.nix`, the wizard), update the top of `CHANGELOG.md`, commit.
2. Tag and sign with the release key (its public half is `data/release-keys/*.asc`; the
   updater on every node checks tags against those files):

       git tag -s v2026.10.1 -m "datum-node-image v2026.10.1"
       git verify-tag v2026.10.1
       git push origin master v2026.10.1

3. Build the generic image from the tag, not from the working tree. One image boots from
   BIOS and UEFI on every provider tested; the three files are the same image in three
   containers (raw for URL imports, gzip for DigitalOcean and for downloading, qcow2 for
   providers that want it):

       git worktree add ../dni-v2026.10.1 v2026.10.1 && cd ../dni-v2026.10.1
       nix build --print-out-paths -o result-img   .#image-generic
       nix build --print-out-paths -o result-gz    .#image-generic-gz
       nix build --print-out-paths -o result-qcow2 .#image-generic-qcow2

   The provider-specific variants from before the generic image (`image-digitalocean`,
   `image-qcow2`, `image-raw-efi`, `image-raw-bios`) still build and still reproduce; a
   release does not need them.

4. Hash the files and sign the list (same layout as a Bitcoin Knots release):

       sha256sum result-*/*.{img,gz,qcow2} | sed 's|result-[a-z0-9]*/||' > SHA256SUMS
       gpg --detach-sign --armor --output SHA256SUMS.asc SHA256SUMS

5. Create the GitHub release on the tag with `SHA256SUMS`, `SHA256SUMS.asc`, the `.img.gz`
   (the only file under GitHub's 2 GB asset limit) and the `.torrent` files. The raw and
   qcow2 files are distributed by torrent with an HTTPS web seed, as the UTXO snapshots are;
   the release notes carry the magnet links. The notes also list the Knots builds bundled
   (name, version, assumeutxo heights) and the snapshot pins, because that is what a node
   operator decides on, and the machines the release is known to reproduce on.

## Reproduce

Anyone, on any machine with Nix and KVM:

    git clone https://github.com/chrisguida/datum-node-image && cd datum-node-image
    git verify-tag v2026.10.1 && git checkout v2026.10.1
    nix build .#image-generic && sha256sum result/*.img

The hash must equal the line in the release's `SHA256SUMS`. If it does not, nothing is
lost and the image is not necessarily bad: it is a reproducibility bug, and the project
wants to hear about it. Open an issue with your hash, `nix --version`, your OS and CPU, and
if you can, `diffoscope result/*.img <the released .img>` for the first differing bytes.
The release notes list the machines (OS, Nix version) a release is known to reproduce on.

To attest, add `attestations/<tag>/<you>/SHA256SUMS` (your own `sha256sum` lines) and its
`.asc` in a pull request; `attestations/README.md` says how the lists are compared. Two
matching attestations from different machines are the bar for calling a release reproduced.

## Why it reproduces

`lib/make-disk-image.nix` is nixpkgs' builder with three changes, each marked in the file:
a fixed ext4 directory hash seed (mke2fs otherwise draws one at random), a fixed clock in the
VM that installs the bootloader, and zeroed build-time fields in the ext4 superblock. The
DigitalOcean gzip is re-compressed without name and timestamp in `flake.nix`. Everything else
is Nix: the same inputs give the same closure.
