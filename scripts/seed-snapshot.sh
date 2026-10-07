#!/usr/bin/env bash
# Seed the UTXO snapshot torrent from a VPS with aria2 (never from a home connection).
#
#   seed-snapshot.sh /path/to/utxo-976000.dat.torrent [/dir/with/utxo-976000.dat]
#
# Expects aria2c in PATH (NixOS: `nix shell nixpkgs#aria2`, or the store path in
# /root/aria2-path.txt on the test droplet). Opens 6881 tcp+udp in the NixOS
# firewall for the running system only; put it in the host config to make it stick.
set -euo pipefail
torrent=${1:?torrent file}
dir=${2:-$(dirname "$torrent")}
port=${PORT:-6881}
aria2c=${ARIA2C:-$( (cat /root/aria2-path.txt 2>/dev/null | sed 's|$|/bin/aria2c|') || true)}
aria2c=${aria2c:-aria2c}
if command -v iptables >/dev/null && iptables -S nixos-fw >/dev/null 2>&1; then
  iptables -C nixos-fw -p tcp --dport "$port" -j nixos-fw-accept 2>/dev/null || iptables -I nixos-fw -p tcp --dport "$port" -j nixos-fw-accept
  iptables -C nixos-fw -p udp --dport "$port" -j nixos-fw-accept 2>/dev/null || iptables -I nixos-fw -p udp --dport "$port" -j nixos-fw-accept
fi
systemctl stop snapshot-seed.service 2>/dev/null || true
systemd-run --unit=snapshot-seed --property=Restart=always --property=RestartSec=30 \
  "$aria2c" --dir="$dir" --seed-ratio=0.0 --check-integrity=true --continue=true \
  --listen-port="$port" --dht-listen-port="$port" --enable-dht=true --bt-enable-lpd=false \
  --max-upload-limit="${UPLOAD_LIMIT:-8M}" --console-log-level=warn --summary-interval=0 \
  "$torrent"
echo "seeding $(basename "$torrent") from $dir on port $port (unit snapshot-seed; journalctl -u snapshot-seed)"
