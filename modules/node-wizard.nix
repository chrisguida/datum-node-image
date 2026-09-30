# services.node-wizard
#
# The browser-based first-boot setup page and status dashboard (HTTPS on 443,
# HTTP on 80 redirecting). Runs unprivileged as its own user: it reads the
# node's RPC cookie and the gateway's dashboard, and writes exactly one file,
# the gateway's runtime settings, which services.datum-gateway merges.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.node-wizard;
  node = config.services.blake2b-node;
  bitcoind = config.services.bitcoind.${cfg.bitcoindInstance} or { };
  poolsJson = pkgs.writeText "pools.json" (builtins.toJSON cfg.pools);
  settingsDir = "/var/lib/datum-wizard";
  gatewayKind = if node.gateway or "" == "ratum" then "ratum" else "c";
in
{
  options.services.node-wizard = {
    enable = lib.mkEnableOption "the first-boot setup page and dashboard";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.node-wizard;
      defaultText = lib.literalExpression "pkgs.node-wizard";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 443;
      description = "HTTPS port.";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "HTTP port that redirects to HTTPS.";
    };

    pools = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = import ../data/pools.nix;
      defaultText = lib.literalExpression "import ../data/pools.nix";
      description = "Pinned pools offered in the form (name, host, port, pubkey per key).";
    };

    defaultPool = lib.mkOption {
      type = lib.types.str;
      default = node.pool or "";
      defaultText = lib.literalExpression "config.services.blake2b-node.pool";
      description = "Pool preselected in the form.";
    };

    bitcoindInstance = lib.mkOption {
      type = lib.types.str;
      default = "blake2b";
    };

    consoleDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/dev/tty1"
        "/dev/ttyS0"
      ];
      description = "Consoles the setup code is printed on until setup completes.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.datum-gateway.enable;
        message = "services.node-wizard needs services.datum-gateway";
      }
    ];

    # the gateway reads the file the wizard writes
    services.datum-gateway.runtimeSettingsFile = "${settingsDir}/gateway-settings.json";

    users.users.node-wizard = {
      isSystemUser = true;
      group = "node-wizard";
      extraGroups = [
        bitcoind.group # RPC cookie (group-readable)
        "tty" # /dev/tty1
        "dialout" # /dev/ttyS0
      ];
    };
    users.groups.node-wizard = { };

    # setgid dir: files the wizard creates belong to the datum-gateway group
    systemd.tmpfiles.rules = [
      "d ${settingsDir} 2750 node-wizard datum-gateway - -"
    ];

    environment.etc."node-wizard/pools.json".source = poolsJson;

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      cfg.port
      cfg.httpPort
    ];

    systemd.services.node-wizard = {
      description = "Node setup page and dashboard";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.systemd ];
      serviceConfig = {
        User = "node-wizard";
        Group = "node-wizard";
        StateDirectory = "node-wizard";
        StateDirectoryMode = "0700";
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe cfg.package)
          "-state-dir /var/lib/node-wizard"
          "-gateway-settings ${settingsDir}/gateway-settings.json"
          "-pools /etc/node-wizard/pools.json"
          "-default-pool ${lib.escapeShellArg cfg.defaultPool}"
          "-bitcoind-cookie ${bitcoind.dataDir}/.cookie"
          "-bitcoind-rpc http://127.0.0.1:${toString (if (bitcoind.rpc.port or null) == null then 8332 else bitcoind.rpc.port)}"
          "-bitcoind-unit bitcoind-${cfg.bitcoindInstance}.service"
          "-gateway-unit datum-gateway.service"
          "-gateway-api http://127.0.0.1:${toString (node.apiPort or 7152)}"
          "-gateway-kind ${gatewayKind}"
          "-stratum-port ${toString (node.stratumPort or 23334)}"
          "-listen :${toString cfg.port}"
          "-http-listen :${toString cfg.httpPort}"
          "-console-devices ${lib.concatStringsSep "," cfg.consoleDevices}"
        ];
        Restart = "on-failure";
        RestartSec = "3s";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        ReadWritePaths = [ settingsDir ];
        # consoles must stay reachable, so no PrivateDevices
        DeviceAllow = [
          "char-tty rw"
          "/dev/ttyS0 rw"
        ];
      };
    };
  };
}
