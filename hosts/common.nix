# Shared host configuration for every blake2b-vps variant.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  keys = import ./authorized-keys.nix;
in
{
  # below mkDefault, so provider image variants (DigitalOcean takes the name from metadata) win
  networking.hostName = lib.mkOverride 1100 "blake2b-node";
  networking.useDHCP = lib.mkDefault true;
  networking.useNetworkd = true;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # provider serial consoles
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200"
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = keys;
  users.users.admin = {
    isNormalUser = true;
    description = "Administrator";
    extraGroups = [
      "wheel"
      config.services.bitcoind.blake2b.group
    ];
    openssh.authorizedKeys.keys = keys;
  };
  security.sudo.wheelNeedsPassword = false;

  # On image-import providers (Vultr, DigitalOcean, LunaNode, ...) cloud-init
  # brings the SSH key, hostname and network from the provider's metadata.
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  services.blake2b-node.enable = true;
  # assumeutxo fast start: snapshot taken 2026-10-02 from a synced unpruned Knots 29.4.2
  # (dumptxoutset type=latest); the Knots build carries the chainparams entry until it is upstream
  services.blake2b-node.fastStart = {
    enable = true;
    height = 975245;
    blockhash = "0000000000000000ed0d972dbe57e3d8c5e80a5dd1963847196152bdb2f8f977";
    utxoHash = "4cd38b1ce3f8d3753f716b99a16c85138a8d60102d9b3d532264c19c16c54a97";
    chainTxCount = 1417062280;
    url = "https://mb-beast.tail4a715.ts.net:8443/datum-node-image/utxo-975245.dat";
    sha256 = "64c775cf1072d9ce6b6908b9d2c122a365cf1954bcde90a35fdcf8911e15b94c";
    sizeBytes = 9516250735;
  };
  # first-boot setup page on https://<ip>/ (self-signed certificate), http redirects
  services.node-wizard.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    htop
    curl
    jq
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "25.11";
}
