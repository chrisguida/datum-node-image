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

  # compressed-RAM swap: a safety margin for the snapshot load on 2 to 4 GB boxes, not working memory.
  # Half of RAM as zram plus dbcache=1024 made a 4 GB node keep its UTXO cache in swap during the
  # background validation; a quarter, with a low swappiness, keeps the page cache for block files.
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };
  boot.kernel.sysctl."vm.swappiness" = 10;

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
    height = 976000;
    blockhash = "000000000000000098441aee029573795681eb1602c75271e809b136e9217373";
    utxoHash = "dbd67717d3f108e4fbd8b4f9efc4057cac11a0ba7c23584b43cca42c9edb7118";
    chainTxCount = 1417215373;
    url = "https://mb-beast.tail4a715.ts.net:8443/datum-node-image/utxo-976000.dat";
    torrentUrl = "https://mb-beast.tail4a715.ts.net:8443/datum-node-image/utxo-976000.dat.torrent";
    sha256 = "bfd2460a55ae1d2e94b9957ccd512ae027855feed1dbef996cfed0abebe5d123";
    sizeBytes = 9517597408;
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
