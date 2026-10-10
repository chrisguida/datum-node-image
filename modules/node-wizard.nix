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
  bitcoindUnit = "bitcoind-${cfg.bitcoindInstance}.service";
  updaterUnit = "node-updater.service";
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

    dashboardPort = lib.mkOption {
      type = lib.types.port;
      default = 7443;
      description = "HTTPS port where the gateway's own dashboard is proxied, behind the wizard's login.";
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

    releasesURL = lib.mkOption {
      type = lib.types.str;
      default = "https://api.github.com/repos/chrisguida/datum-node-image/releases";
      description = "GitHub releases API endpoint listed on the Update page (unauthenticated, cached ten minutes).";
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

    # setgid dir: files the wizard creates belong to the datum-gateway group. The directory is
    # traversable by everyone because bitcoind's wrapper reads the Knots build selector here; the
    # gateway settings file itself (it holds the gateway's admin password) stays group-only (0640).
    systemd.tmpfiles.rules = [
      "d ${settingsDir} 2755 node-wizard datum-gateway - -"
    ];

    # The wizard restarts the node after a Knots build switch and starts the updater, as user
    # node-wizard over D-Bus. polkit allows exactly those two units and nothing else.
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      /* node-wizard: restart the node after a Knots build switch, start the image updater */
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "node-wizard") {
          var unit = action.lookup("unit");
          var verb = action.lookup("verb");
          if ((unit == "${bitcoindUnit}" && (verb == "restart" || verb == "start")) ||
              (unit == "${updaterUnit}" && verb == "start")) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    environment.etc."node-wizard/pools.json".source = poolsJson;

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      cfg.port
      cfg.httpPort
      cfg.dashboardPort
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
          "-dashboard-listen :${toString cfg.dashboardPort}"
          "-console-devices ${lib.concatStringsSep "," cfg.consoleDevices}"
          "-fast-start-progress ${bitcoind.dataDir}/fast-start/progress.json"
          "-knots-builds /etc/datum-node-image/knots-builds.json"
          "-knots-selector ${node.knotsBuildSelector or "${settingsDir}/knots-build"}"
          "-knots-running /run/bitcoind-${cfg.bitcoindInstance}/knots-build"
          "-image-info /etc/datum-node-image/image.json"
          "-update-request ${settingsDir}/update-request"
          "-updater-unit ${updaterUnit}"
          "-updater-status /var/lib/node-updater/status"
          "-updater-log /var/lib/node-updater/last.log"
          "-releases-url ${lib.escapeShellArg cfg.releasesURL}"
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
