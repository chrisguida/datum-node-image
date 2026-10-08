# services.blake2b-node.fastStart
#
# First-boot assumeutxo: once bitcoind has the headers, download the published
# UTXO snapshot, verify its SHA256, hand it to `loadtxoutset`, and let the
# node validate history in the background while the gateway already serves
# work. Progress goes to a small JSON file the setup page shows. Any failure
# leaves the node syncing normally.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  node = config.services.blake2b-node;
  cfg = node.fastStart;
  inst = "blake2b";
  bitcoind = config.services.bitcoind.${inst};
  stateDir = "${bitcoind.dataDir}/fast-start";
  # aria2 gives up the whole torrent when it cannot bind its listen port, so it gets a range and takes the first
  # free one (the same range is open in the firewall).
  portRange = "${toString cfg.torrentPort}-${toString (cfg.torrentPort + 8)}";
  progressFile = "${stateDir}/progress.json";
  script = pkgs.writeShellScript "bitcoind-fast-start" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.aria2
        pkgs.jq
        pkgs.gnugrep
        node.knotsPackage
      ]
    }
    STATE=${stateDir}
    SNAP=$STATE/snapshot.dat
    mkdir -p "$STATE"
    chmod 750 "$STATE"
    cli() { bitcoin-cli -datadir=${bitcoind.dataDir} -rpcclienttimeout=0 "$@"; }
    progress() { # phase percent detail
      printf '{"phase":"%s","percent":%d,"detail":"%s","updated_at":%d}\n' "$1" "$2" "$3" "$(date +%s)" > "$STATE/progress.tmp"
      chmod 644 "$STATE/progress.tmp"
      mv "$STATE/progress.tmp" ${progressFile}
    }
    if [ -e "$STATE/done" ]; then
      exit 0
    fi
    # wait for RPC
    until cli getblockchaininfo >/dev/null 2>&1; do sleep 5; done
    blocks=$(cli getblockchaininfo | jq -r .blocks)
    if [ "$blocks" -ge ${toString cfg.height} ]; then
      progress done 100 "already past snapshot height"
      touch "$STATE/done"
      exit 0
    fi
    # disk: snapshot + a second chainstate during background validation
    avail=$(df --output=avail -B1 ${bitcoind.dataDir} | tail -1)
    need=$(( ${toString cfg.sizeBytes} + 20 * 1024 * 1024 * 1024 ))
    if [ "$avail" -lt "$need" ]; then
      progress failed 0 "not enough disk space"
      exit 0
    fi
    # download, resumable; skipped when a complete file is already there
    # (a previous run that stopped between download and verification)
    have=$(stat -c %s "$SNAP.part" 2>/dev/null || echo 0)
    if [ "$have" -lt ${toString cfg.sizeBytes} ]; then
      progress downloading 0 ""
      downloaded=0
      ${lib.optionalString (cfg.torrentUrl != null) ''
        # BitTorrent first: peers plus the HTTPS web seed in the torrent. aria2 names
        # the file after the torrent; stop seeding as soon as the download is complete.
        if curl -fsSL --retry 5 -o "$STATE/snapshot.torrent" ${lib.escapeShellArg cfg.torrentUrl}; then
          tname=$(aria2c --show-files "$STATE/snapshot.torrent" 2>/dev/null | grep -oE '^ *1\|.*' | sed 's/^ *1|//' | head -1)
          tname=''${tname:-${baseNameOf cfg.url}}
          aria2c --dir="$STATE" --seed-time=0 --bt-stop-timeout=600 --check-integrity=true \
            --continue=true --max-connection-per-server=4 --summary-interval=5 \
            --listen-port=${portRange} --dht-listen-port=${portRange} \
            --console-log-level=warn "$STATE/snapshot.torrent" > "$STATE/aria2.log" 2>&1 &
          pid=$!
          while kill -0 $pid 2>/dev/null; do
            pct=$(grep -aoE '\([0-9]+%\)' "$STATE/aria2.log" | tail -1 | tr -dc '0-9')
            progress downloading "''${pct:-0}" "torrent"
            sleep 5
          done
          if wait $pid && [ "$(stat -c %s "$STATE/$tname" 2>/dev/null || echo 0)" -ge ${toString cfg.sizeBytes} ]; then
            mv "$STATE/$tname" "$SNAP.part"
            rm -f "$STATE/$tname.aria2" "$STATE/snapshot.torrent"
            downloaded=1
          else
            echo "torrent download failed, falling back to HTTPS" >&2
            rm -f "$STATE/$tname" "$STATE/$tname.aria2"
          fi
        fi
      ''}
      if [ "$downloaded" = 0 ]; then
        curl -fsSL -C - --retry 30 --retry-delay 10 --retry-all-errors -o "$SNAP.part" ${lib.escapeShellArg cfg.url} &
        pid=$!
        while kill -0 $pid 2>/dev/null; do
          have=$(stat -c %s "$SNAP.part" 2>/dev/null || echo 0)
          pct=$(( have * 100 / ${toString cfg.sizeBytes} ))
          [ "$pct" -gt 100 ] && pct=100
          progress downloading "$pct" ""
          sleep 5
        done
        if ! wait $pid; then
          progress failed 0 "download failed"
          exit 0
        fi
      fi
    fi
    progress verifying 100 ""
    if ! echo "${cfg.sha256}  $SNAP.part" | sha256sum -c --status; then
      rm -f "$SNAP.part"
      progress failed 0 "checksum mismatch"
      exit 0
    fi
    mv "$SNAP.part" "$SNAP"
    # The file is on disk and checked. Only now wait for the block headers: the node needs the header of the
    # snapshot's block before loadtxoutset, and the download overlapped with that sync instead of waiting for it.
    progress headers 0 ""
    while :; do
      headers=$(cli getblockchaininfo | jq -r .headers)
      [ "$headers" -ge ${toString cfg.height} ] && break
      sleep 10
    done
    progress loading 0 ""
    # Pause peer traffic while the snapshot loads: otherwise the normal chainstate keeps
    # downloading and validating old blocks in parallel, competing for the two cores
    # and the RAM of a small VPS. Headers are already in; nothing is lost.
    cli setnetworkactive false >/dev/null 2>&1 || true
    trap 'cli setnetworkactive true >/dev/null 2>&1 || true' EXIT
    # bitcoind logs "[snapshot] N coins loaded (xx.xx%, ...)" to debug.log every million coins
    cli loadtxoutset "$SNAP" > "$STATE/load.out" 2>&1 &
    pid=$!
    while kill -0 $pid 2>/dev/null; do
      pct=$(grep -a "coins loaded (" ${bitcoind.dataDir}/debug.log 2>/dev/null | tail -1 | grep -oE '\([0-9]+' | tr -d '(')
      progress loading "''${pct:-0}" ""
      sleep 5
    done
    cli setnetworkactive true >/dev/null 2>&1 || true
    if wait $pid; then
      cat "$STATE/load.out"
      rm -f "$SNAP" "$STATE/load.out"
      touch "$STATE/done"
      progress catching_up 0 ""
    else
      echo "loadtxoutset failed: $(cat "$STATE/load.out")" >&2
      rm -f "$SNAP" "$STATE/load.out"
      progress failed 0 "snapshot load failed"
    fi
  '';
in
{
  options.services.blake2b-node.fastStart = {
    enable = lib.mkEnableOption "assumeutxo fast start from a published snapshot";

    height = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Snapshot base height (must be in Knots' chainparams).";
    };
    blockhash = lib.mkOption {
      type = lib.types.str;
      description = "Block hash at that height.";
    };
    utxoHash = lib.mkOption {
      type = lib.types.str;
      description = "AssumeUTXO hash_serialized of the snapshot.";
    };
    chainTxCount = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Transactions in the chain up to the snapshot (m_chain_tx_count).";
    };
    url = lib.mkOption {
      type = lib.types.str;
      description = "Where the snapshot file is served.";
    };
    torrentUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL of a .torrent for the snapshot (web seed + peers). Tried before the plain download; null disables BitTorrent.";
    };
    torrentPort = lib.mkOption {
      type = lib.types.port;
      default = 6881;
      description = "First of nine TCP/UDP ports aria2 may listen on while downloading the snapshot (opened in the firewall when torrentUrl is set); it takes the first free one.";
    };
    sha256 = lib.mkOption {
      type = lib.types.str;
      description = "SHA256 of the snapshot file (hex).";
    };
    sizeBytes = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Size of the snapshot file in bytes (for the progress bar and the disk check).";
    };
    patchKnots = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Build Knots from source with the snapshot in chainparams. Turn off once the entry is upstream and the release tarball knows it.";
    };
  };

  config = lib.mkIf (node.enable && cfg.enable) {
    assertions = [
      {
        assertion = node.prune >= 1100;
        message = "assumeutxo needs services.blake2b-node.prune >= 1100 while two chainstates exist";
      }
    ];

    services.blake2b-node.knotsPackage = lib.mkIf cfg.patchKnots (
      lib.mkDefault (
        pkgs.bitcoind-knots-patched {
          inherit (cfg)
            height
            blockhash
            utxoHash
            chainTxCount
            ;
        }
      )
    );

    networking.firewall = lib.mkIf (cfg.torrentUrl != null) {
      allowedTCPPortRanges = [ { from = cfg.torrentPort; to = cfg.torrentPort + 8; } ];
      allowedUDPPortRanges = [ { from = cfg.torrentPort; to = cfg.torrentPort + 8; } ];
    };

    systemd.services.bitcoind-fast-start = {
      description = "assumeutxo fast start";
      wantedBy = [ "multi-user.target" ];
      after = [
        "bitcoind-${inst}.service"
        "network-online.target"
      ];
      requires = [ "bitcoind-${inst}.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = bitcoind.user;
        Group = bitcoind.group;
        ExecStart = script;
        TimeoutStartSec = "infinity";
        Restart = "on-failure";
        RestartSec = "60s";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
