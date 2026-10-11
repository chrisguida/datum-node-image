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
    # Without "disk_setup" and "mounts": the image has one root partition that NixOS grows itself, and the
    # mounts module fails the whole cloud-config unit trying to write the read-only /etc/fstab.
    settings.cloud_config_modules = [
      "ssh-import-id"
      "set-passwords"
      "timezone"
      "disable-ec2-metadata"
      "runcmd"
      "ssh"
    ];
  };

  services.blake2b-node.enable = true;
  # Two attested Guix tarballs are bundled (services.blake2b-node.knotsBuilds): "assumeutxo-976000", 29.4.2
  # plus the 976,000 assumeutxo entry (#444, pkgs/bitcoind-knots-976000-bin.nix), runs by default;
  # "official" is the unmodified 29.4.2 (pkgs/bitcoind-knots-bin.nix). The setup page switches between
  # them at runtime through /var/lib/datum-wizard/knots-build; no source build.
  services.blake2b-node.knotsBuildDefault = "assumeutxo-976000";
  # assumeutxo fast start: snapshot taken 2026-10-02 from a synced unpruned Knots 29.4.2
  # (dumptxoutset type=latest); the build above carries the chainparams entry until it is upstream
  services.blake2b-node.fastStart = {
    enable = true;
    patchKnots = false;
    height = 976000;
    blockhash = "000000000000000098441aee029573795681eb1602c75271e809b136e9217373";
    utxoHash = "dbd67717d3f108e4fbd8b4f9efc4057cac11a0ba7c23584b43cca42c9edb7118";
    chainTxCount = 1417215373;
    # the same file AlphaPool publishes for its installer (sha256 identical); the torrent ships in the
    # image (data/, info hash 3cf7e4d15841f116856f6f19bf2ac15b1dbae2c3) with that URL as its web seed
    url = "https://snapshots.alphapool.tech:8444/xbt/utxo-976000.dat";
    torrentFile = ../data/utxo-976000.dat.torrent;
    sha256 = "bfd2460a55ae1d2e94b9957ccd512ae027855feed1dbef996cfed0abebe5d123";
    sizeBytes = 9517597408;
  };
  # first-boot setup page on https://<ip>/ (self-signed certificate), http redirects
  services.node-wizard.enable = true;
  # the setup page's "Update" button: fetch a signed release tag, verify it against data/release-keys,
  # build this variant from it and switch, rolling back if the node does not come up
  services.node-updater.enable = true;

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
