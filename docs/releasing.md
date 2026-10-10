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

3. Build every variant from the tag, not from the working tree:

       git worktree add /tmp/dni-v2026.10.1 v2026.10.1 && cd /tmp/dni-v2026.10.1
       nix build --print-out-paths -o result-do   .#image-digitalocean
       nix build --print-out-paths -o result-qcow .#image-qcow2
       nix build --print-out-paths -o result-raw  .#image-raw-bios
       nix build --print-out-paths -o result-efi  .#image-raw-efi

4. Hash the files and sign the list (same layout as a Bitcoin Knots release):

       sha256sum result-*/*.{gz,qcow2,img} | sed 's|result-[a-z]*/||' > SHA256SUMS
       gpg --detach-sign --armor --output SHA256SUMS.asc SHA256SUMS

5. Create the GitHub release on the tag with the images, `SHA256SUMS` and `SHA256SUMS.asc`.
   The release notes list the Knots builds bundled (name, version, assumeutxo heights) and the
   snapshot pins, because that is what a node operator decides on.

## Reproduce

Anyone, on any machine with Nix and KVM:

    git clone https://github.com/chrisguida/datum-node-image && cd datum-node-image
    git verify-tag v2026.10.1 && git checkout v2026.10.1
    nix build .#image-digitalocean && sha256sum result/*.gz

The hash must equal the line in the release's `SHA256SUMS`. If it does not, that is a
finding: open an issue with your hash, nix version and the output of `nix build --rebuild
--keep-failed` on `.#nixosConfigurations.blake2b-vps-image.config.system.build.images.digital-ocean`,
which leaves the differing output next to the original as a `.check` path.

To attest, add `attestations/<tag>/<you>/SHA256SUMS` (your own `sha256sum` lines) and its
`.asc` in a pull request; `attestations/README.md` says how the lists are compared. Two
matching attestations from different machines are the bar for calling a release reproduced.

## Why it reproduces

`lib/make-disk-image.nix` is nixpkgs' builder with three changes, each marked in the file:
a fixed ext4 directory hash seed (mke2fs otherwise draws one at random), a fixed clock in the
VM that installs the bootloader, and zeroed build-time fields in the ext4 superblock. The
DigitalOcean gzip is re-compressed without name and timestamp in `flake.nix`. Everything else
is Nix: the same inputs give the same closure.
