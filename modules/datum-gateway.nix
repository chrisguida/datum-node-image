# services.datum-gateway
#
# Runs one DATUM gateway (a C build or ratum-gateway; all read the same JSON
# config) against a local services.bitcoind.<instance>. The static config from
# Nix is deep-merged under a runtime settings file that the setup wizard, or a
# person, writes later; the service restarts by itself when that file changes
# and stays inactive (not failed) until a payout address exists.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.datum-gateway;
  jsonFormat = pkgs.formats.json { };
  baseConfig = jsonFormat.generate "datum-gateway-base.json" cfg.settings;
  bitcoind = config.services.bitcoind.${cfg.bitcoindInstance} or { };
  bitcoindUnit = "bitcoind-${cfg.bitcoindInstance}.service";
  stateDir = "/var/lib/datum-gateway";
  runDir = "/run/datum-gateway";

  # ExecCondition: build the effective config. Exit 1 means "condition failed":
  # systemd leaves the unit inactive without counting a failure.
  prepare = pkgs.writeShellScript "datum-gateway-prepare" ''
    set -eu
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.jq
      ]
    }
    umask 077
    if [ ! -s ${stateDir}/admin-password ]; then
      tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 > ${stateDir}/admin-password
    fi
    admin=$(cat ${stateDir}/admin-password)
    runtime='{}'
    if [ -s "${cfg.runtimeSettingsFile}" ]; then
      runtime=$(jq -c . "${cfg.runtimeSettingsFile}")
    fi
    jq -n --slurpfile base ${baseConfig} --argjson rt "$runtime" --arg admin "$admin" '
      ($base[0] * $rt)
      | if ((.api.admin_password // "") == "") then .api.admin_password = $admin else . end
    ' > ${runDir}/config.json
    addr=$(jq -r '.mining.pool_address // ""' ${runDir}/config.json)
    if [ -z "$addr" ]; then
      echo "datum-gateway: mining.pool_address is empty. Set it in ${cfg.runtimeSettingsFile}; the gateway starts by itself once that file changes."
      exit 1
    fi
  '';
in
{
  options.services.datum-gateway = {
    enable = lib.mkEnableOption "the DATUM gateway";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        Gateway implementation. `datum-gateway-convoy`, `datum-gateway-iohzrd`
        and `ratum-gateway` all read the same JSON configuration.
      '';
    };

    settings = lib.mkOption {
      type = jsonFormat.type;
      default = { };
      description = ''
        Static gateway configuration in the C gateway's JSON schema
        (`bitcoind`, `stratum`, `api`, `mining`, `datum` sections).
      '';
    };

    runtimeSettingsFile = lib.mkOption {
      type = lib.types.str;
      default = "${stateDir}/settings.json";
      description = ''
        JSON file deep-merged over `settings` at every start; the file wins.
        Written by the setup wizard or by hand. A change restarts the service.
      '';
    };

    bitcoindInstance = lib.mkOption {
      type = lib.types.str;
      default = "blake2b";
      description = "The `services.bitcoind.<name>` instance the gateway builds templates from.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the stratum port to miners.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = bitcoind.enable or false;
        message = "services.datum-gateway needs services.bitcoind.${cfg.bitcoindInstance}.enable = true";
      }
    ];

    users.users.datum-gateway = {
      isSystemUser = true;
      group = "datum-gateway";
      # reads bitcoind's RPC cookie, which the node profile makes group-readable
      extraGroups = [ bitcoind.group ];
      home = stateDir;
    };
    users.groups.datum-gateway = { };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      (cfg.settings.stratum.listen_port or 23334)
    ];

    systemd.services.datum-gateway = {
      description = "DATUM gateway";
      wantedBy = [ "multi-user.target" ];
      requires = [ bitcoindUnit ];
      # a bitcoind restart writes a new RPC cookie, so the gateway restarts with it
      partOf = [ bitcoindUnit ];
      after = [
        bitcoindUnit
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "datum-gateway";
        Group = "datum-gateway";
        StateDirectory = "datum-gateway";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "datum-gateway";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = stateDir;
        ExecCondition = prepare;
        ExecStart = "${lib.getExe cfg.package} -c ${runDir}/config.json";
        Restart = "on-failure";
        RestartSec = "5s";
        LimitNOFILE = 65535;

        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
      };
    };

    # A changed settings file restarts the gateway (and clears the "no payout
    # address yet" condition once one is written).
    systemd.paths.datum-gateway-settings = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = cfg.runtimeSettingsFile;
        Unit = "datum-gateway-restart.service";
      };
    };
    systemd.services.datum-gateway-restart = {
      description = "Restart the DATUM gateway after its settings changed";
      serviceConfig.Type = "oneshot";
      script = "${pkgs.systemd}/bin/systemctl restart datum-gateway.service";
    };
  };
}
