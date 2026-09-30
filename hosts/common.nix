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
  networking.hostName = lib.mkDefault "blake2b-node";
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
