# services.blake2b-node
#
# The opinionated profile: a pruned Bitcoin Knots node on the BLAKE2b (BIP-110)
# chain plus a DATUM gateway pointed at a pinned pool. Everything a template
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
    enable = lib.mkEnableOption "a pruned Knots node + DATUM gateway on the BLAKE2b chain";

    knotsPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.bitcoind-knots-bin;
      defaultText = lib.literalExpression "pkgs.bitcoind-knots-bin";
      description = "Bitcoin Knots build. The default is the official release tarball; `pkgs.bitcoind-knots` (nixpkgs source build) also works.";
    };

    prune = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10000;
      description = "Block-file budget in MiB. 550 is bitcoind's floor; assumeutxo needs at least 1100; 10000 is comfortable on a 100+ GB disk.";
    };

    dbCache = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1024;
      description = "bitcoind -dbcache in MiB. 1024 fits a 4 GB VPS; 2048-4096 speeds up the initial sync on 8 GB.";
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
      description = "Address on this chain that the coinbase pays. Leave empty to set it at runtime in the gateway's settings file; the gateway waits until it is set.";
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
    services.bitcoind.${inst} = {
      enable = true;
      package = cfg.knotsPackage;
      prune = cfg.prune;
      dbCache = cfg.dbCache;
      extraConfig = ''
        server=1
        listen=1
        # BLAKE2b chain: 800,000 WU block limit; leave room for the pool's payout tx
        blockmaxweight=785000
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
      cfg.knotsPackage
      pkgs.jq
    ];

    # `bcli getblockchaininfo` for admins
    environment.shellAliases.bcli = "sudo -u ${bitcoind.user} ${cfg.knotsPackage}/bin/bitcoin-cli -datadir=${bitcoind.dataDir}";
  };
}
