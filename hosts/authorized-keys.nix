# SSH public keys baked into the image for root and admin.
#
# Needed for the nixos-anywhere / rescue-mode path. Image-import providers
# inject keys through cloud-init instead, so this list may stay empty there.
[
  # "ssh-ed25519 AAAA... you@laptop"
]
