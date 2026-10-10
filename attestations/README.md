# Image attestations

One directory per release tag, one per signer inside it, holding the signer's own
`SHA256SUMS` (the output of `sha256sum` over the image files they built from the tag) and
a detached signature `SHA256SUMS.asc`. Lists are compared with `diff`; a release counts as
reproduced when two signers on different machines have identical lists. Signer keys live
in `data/release-keys/` once they have signed a release.
