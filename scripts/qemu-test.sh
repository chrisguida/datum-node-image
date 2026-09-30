#!/usr/bin/env bash
# Boot the qcow2 image in QEMU (UEFI, KVM) with a cloud-init NoCloud seed, the
# serial console in a log, and SSH, HTTPS and HTTP forwarded to localhost:2222, :8443 and :8080.
#
#   scripts/qemu-test.sh <image.qcow2> <seed.iso> [workdir]
#
# The image is not modified: a throwaway overlay is created in workdir.
# Stop with: kill $(cat workdir/qemu.pid)
set -euo pipefail

img=${1:?qcow2 image}
seed=${2:?cloud-init seed iso}
work=${3:-$(mktemp -d)}
mkdir -p "$work"

ovmf=$(nix build --no-link --print-out-paths nixpkgs#OVMF.fd)
cp --no-preserve=mode "$ovmf/FV/OVMF_VARS.fd" "$work/OVMF_VARS.fd"

nix shell nixpkgs#qemu -c qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$img")" "$work/disk.qcow2" 80G

echo "serial log: $work/serial.log   ssh: ssh -p 2222 -i <key> root@localhost"
exec nix shell nixpkgs#qemu -c qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 2 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf/FV/OVMF_CODE.fd" \
  -drive if=pflash,format=raw,file="$work/OVMF_VARS.fd" \
  -drive file="$work/disk.qcow2",if=virtio,format=qcow2 \
  -drive file="$seed",if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8443-:443,hostfwd=tcp:127.0.0.1:8080-:80 \
  -device virtio-net-pci,netdev=n0 \
  -display none -serial file:"$work/serial.log" \
  -pidfile "$work/qemu.pid" -daemonize
