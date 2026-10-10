# services.blake2b-node
#
# The opinionated profile: a pruned Bitcoin Knots node plus a DATUM gateway
# pointed at a pinned pool. Everything a template
# user would change is an option here; the payout address may also be left
# empty and set at runtime through the gateway's settings file.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.blake2b-node;
  pools = import ../data/pools.nix;
  inst = "blake2b";
  bitcoind = config.services.bitcoind.${inst};
  pool = if cfg.pool == "custom" then cfg.customPool else pools.${cfg.pool};
  isX86 = pkgs.stdenv.hostPlatform.isx86_64;

  # ---- Knots build selection -------------------------------------------------------------------
  builds = cfg.knotsBuilds;
  defaultBuild =
    builds.${cfg.knotsBuildDefault}
      or (throw "services.blake2b-node.knotsBuildDefault (${cfg.knotsBuildDefault}) is not a name in services.blake2b-node.knotsBuilds (${lib.concatStringsSep ", " (builtins.attrNames builds)})");
  buildInfo = lib.mapAttrs (name: p: {
    version = p.version or "unknown";
    assumeutxoHeights = p.assumeutxoHeights or [ ];
    store = "${p}";
  }) builds;
  # bin/bitcoind: read the selector, validate the name against the bundled builds, exec that build.
  # Every build's store path is spelled out here, which is what keeps them all in the closure. When run
  # by systemd with a RuntimeDirectory, the chosen name is left in $RUNTIME_DIRECTORY/knots-build so the
  # setup page can show which build is running.
  switchScript = pkgs.writeShellScript "bitcoind-knots-switch" ''
    set -u
    selector=${lib.escapeShellArg cfg.knotsBuildSelector}
    default=${lib.escapeShellArg cfg.knotsBuildDefault}
    name=""
    if [ -r "$selector" ]; then
      IFS= read -r name < "$selector" || true
    fi
    name=''${name//[[:space:]]/}
    case "$name" in
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (n: p: "  ${lib.escapeShellArg n}) exe=${lib.escapeShellArg "${p}/bin/bitcoind"} ;;") builds
    )}
      "")
        name=$default
        exe=${lib.escapeShellArg "${defaultBuild}/bin/bitcoind"}
        ;;
      *)
        echo "bitcoind-knots-switch: unknown Knots build '$name' in $selector, running the default ($default)" >&2
        name=$default
        exe=${lib.escapeShellArg "${defaultBuild}/bin/bitcoind"}
        ;;
    esac
    if [ -n "''${RUNTIME_DIRECTORY:-}" ] && [ -d "$RUNTIME_DIRECTORY" ]; then
      printf '%s\n' "$name" > "$RUNTIME_DIRECTORY/knots-build" 2>/dev/null || true
    fi
    exec "$exe" "$@"
  '';
  switcher =
    pkgs.runCommand "bitcoind-knots-switch-${defaultBuild.version or "unknown"}"
      {
        passthru = {
          version = defaultBuild.version or "unknown";
          assumeutxoHeights = defaultBuild.assumeutxoHeights or [ ];
          inherit builds;
        };
        meta = {
          description = "Bitcoin Knots, the build named in ${cfg.knotsBuildSelector} (${lib.concatStringsSep ", " (builtins.attrNames builds)})";
          mainProgram = "bitcoind";
        };
      }
      ''
        mkdir -p $out/bin
        for f in ${defaultBuild}/bin/*; do
          n=$(basename "$f")
          [ "$n" = bitcoind ] || ln -s "$f" "$out/bin/$n"
        done
        cp ${switchScript} $out/bin/bitcoind
        chmod 755 $out/bin/bitcoind
      '';
  runtimePackage = if builtins.length (builtins.attrNames builds) == 1 then defaultBuild else switcher;
  gatewayPackage =
    {
      convoy = pkgs.datum-gateway-convoy;
      iohzrd = pkgs.datum-gateway-iohzrd;
      ratum = pkgs.ratum-gateway;
    }
    .${cfg.gateway};
  poolModule = {
    options = {
      host = lib.mkOption {
        type = lib.types.str;
        description = "DATUM server host";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 28915;
        description = "DATUM server port";
      };
      pubkey = lib.mkOption {
        type = lib.types.str;
        description = "DATUM server public key (128 hex chars). Always pinned: an empty key means the gateway trusts whatever the far end presents.";
      };
    };
  };
in
{
  options.services.blake2b-node = {
    enable = lib.mkEnableOption "a pruned bitcoin (Knots) node + DATUM gateway";

    knotsPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        One Bitcoin Knots build to run, with no runtime choice. When set, `knotsBuilds` holds just this
        package and bitcoind runs it directly. Leave null (the default) to bundle every build in
        `knotsBuilds` and pick one at service start through the selector file.
      '';
    };

    knotsBuilds = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default =
        if cfg.knotsPackage != null then
          { ${cfg.knotsBuildDefault} = cfg.knotsPackage; }
        else
          {
            official = pkgs.bitcoind-knots-bin;
          }
          // lib.optionalAttrs isX86 {
            assumeutxo-976000 = pkgs.bitcoind-knots-976000-bin;
          };
      defaultText = lib.literalExpression ''
        { official = pkgs.bitcoind-knots-bin; assumeutxo-976000 = pkgs.bitcoind-knots-976000-bin; }  # x86_64
      '';
      description = ''
        Bitcoin Knots builds bundled in the image, by name. All of them are in the system closure; the one
        that runs is named in the selector file (`knotsBuildSelector`) and can be changed from the setup page
        without a rebuild, falling back to `knotsBuildDefault`. bitcoin-cli and the other tools come from
        the default build (the RPC interface is the same).
      '';
    };

    knotsBuildDefault = lib.mkOption {
      type = lib.types.str;
      default =
        if cfg.knotsPackage != null then
          lib.getName cfg.knotsPackage
        else if isX86 then
          "assumeutxo-976000"
        else
          "official";
      defaultText = lib.literalExpression ''"assumeutxo-976000"'';
      description = "Name in `knotsBuilds` that runs when the selector file is missing or names an unknown build.";
    };

    knotsBuildSelector = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/datum-wizard/knots-build";
      description = "File holding the name of the Knots build to run (one line). Written by the setup page.";
    };

    knotsRuntimePackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        What `services.bitcoind` actually runs: the single build when there is one, otherwise a wrapper
        whose bin/bitcoind reads the selector file and execs the chosen build. Use it wherever the
        node's binaries are wanted (bitcoin-cli, the `bcli` alias).
      '';
    };

    prune = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10000;
      description = "Block-file budget in MiB. 550 is bitcoind's floor; assumeutxo needs at least 1100; 10000 is comfortable on a 100+ GB disk.";
    };

    dbCache = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = ''
        bitcoind -dbcache in MiB. 600 leaves a 4 GB VPS enough page cache to follow the tip while the
        assumeutxo background validation runs (1024 on 4 GB swapped the UTXO cache out and the node fell
        minutes behind new blocks); 2048-4096 speeds up a full initial sync on 8 GB or more.
      '';
    };

    maxUploadTarget = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 10000;
      description = ''
        bitcoind -maxuploadtarget in MiB per 24 h (0 = unlimited). Past the target the node stops serving
        blocks older than a week to other peers; new blocks and transactions still relay, so mining is
        unaffected. Keeps a VPS inside its bandwidth allowance.
      '';
    };

    gateway = lib.mkOption {
      type = lib.types.enum [
        "convoy"
        "iohzrd"
        "ratum"
      ];
      default = "convoy";
      description = "Which gateway implementation to run.";
    };

    pool = lib.mkOption {
      type = lib.types.enum (builtins.attrNames pools ++ [ "custom" ]);
      default = "omegapool";
      description = "Pool from data/pools.nix, or `custom` with `customPool`.";
    };

    customPool = lib.mkOption {
      type = lib.types.submodule poolModule;
      default = { };
      description = "Used when `pool = \"custom\"`.";
    };

    payoutAddress = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Bitcoin address the coinbase pays. Leave empty to set it at runtime in the gateway's settings file; the gateway waits until it is set.";
    };

    coinbaseTag = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Secondary coinbase tag (the pool sets the primary one).";
    };

    stratumPort = lib.mkOption {
      type = lib.types.port;
      default = 23334;
      description = "Stratum port miners connect to.";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 7152;
      description = "Gateway dashboard/API port (loopback only).";
    };

    extraBitcoindConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra lines for bitcoin.conf.";
    };

    extraGatewaySettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra gateway settings merged over the profile's (Nix-side, static).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.blake2b-node.knotsRuntimePackage = runtimePackage;

    # what the setup page reads to offer the switch
    environment.etc."datum-node-image/knots-builds.json".text = builtins.toJSON {
      default = cfg.knotsBuildDefault;
      selector = cfg.knotsBuildSelector;
      builds = buildInfo;
    };

    # the wrapper records the running build in /run/bitcoind-blake2b/knots-build
    systemd.services."bitcoind-${inst}".serviceConfig = {
      RuntimeDirectory = "bitcoind-${inst}";
      RuntimeDirectoryMode = "0755";
    };

    services.bitcoind.${inst} = {
      enable = true;
      package = runtimePackage;
      prune = cfg.prune;
      dbCache = cfg.dbCache;
      extraConfig = ''
        server=1
        listen=1
        # bitcoin's 800,000 WU block limit; leave room for the pool's payout tx
        blockmaxweight=785000
        maxuploadtarget=${toString cfg.maxUploadTarget}
        # the gateway reads the RPC cookie as a member of the bitcoind group
        rpccookieperms=group
        # block notifications go to the gateway's API; DATUM does not use ZMQ
        blocknotify=${pkgs.curl}/bin/curl -fsS -m 5 -o /dev/null http://127.0.0.1:${toString cfg.apiPort}/NOTIFY
        ${cfg.extraBitcoindConfig}
      '';
    };

    services.datum-gateway = {
      enable = true;
      package = gatewayPackage;
      bitcoindInstance = inst;
      settings = lib.recursiveUpdate {
        bitcoind = {
          rpcurl = "http://127.0.0.1:${toString (if bitcoind.rpc.port == null then 8332 else bitcoind.rpc.port)}";
          rpccookiefile = "${bitcoind.dataDir}/.cookie";
          work_update_seconds = 40;
          notify_fallback = true;
        };
        stratum = {
          listen_addr = "0.0.0.0";
          listen_port = cfg.stratumPort;
          vardiff_min = 16384;
        };
        api = {
          listen_addr = "127.0.0.1";
          listen_port = cfg.apiPort;
          modify_conf = false;
        };
        mining = {
          pool_address = cfg.payoutAddress;
          coinbase_tag_primary = "DATUM";
          coinbase_tag_secondary = cfg.coinbaseTag;
          allow_hasher_time_rolling = false;
        };
        datum = {
          pool_host = pool.host;
          pool_port = pool.port;
          pool_pubkey = pool.pubkey;
          pool_pass_workers = true;
          pool_pass_full_users = false;
          pooled_mining_only = true;
        };
      } cfg.extraGatewaySettings;
    };

    # P2P
    networking.firewall.allowedTCPPorts = [ 8333 ];

    environment.systemPackages = [
      runtimePackage
      pkgs.jq
    ];

    # `bcli getblockchaininfo` for admins
    environment.shellAliases.bcli = "sudo -u ${bitcoind.user} ${runtimePackage}/bin/bitcoin-cli -datadir=${bitcoind.dataDir}";
  };
}
