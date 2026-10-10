# services.node-updater
#
# Updates the running system to a signed release tag of the datum-node-image repository.
# The setup page writes the wanted tag to a request file and starts this oneshot (root);
# it fetches the tag, verifies its OpenPGP signature against the release keys baked into
# the *currently installed* image, builds this image variant's system closure from the
# tag, switches to it, and rolls back to the previous generation if the node is not up
# again within a short while. Progress goes to a JSON status file and a log the setup
# page shows.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.node-updater;
  image = config.datum-node-image;
  stateDir = "/var/lib/node-updater";
  keysDir = "/etc/datum-node-image/release-keys";
  flakeAttr =
    if image.variant == "anywhere" then
      "nixosConfigurations.blake2b-vps-anywhere.config.system.build.toplevel"
    else
      "nixosConfigurations.blake2b-vps-image.config.system.build.images.${image.variant}.passthru.config.system.build.toplevel";
  # The NODE_UPDATER_* variables only exist for testing the script outside the image (another
  # state directory, key directory, repository; stop after "verify" or "build").
  script = pkgs.writeShellScript "node-updater" ''
    set -u
    STATE=''${NODE_UPDATER_STATE:-${stateDir}}
    KEYS=''${NODE_UPDATER_KEYS:-${keysDir}}
    REPO=$STATE/repo
    LOG=$STATE/last.log
    STATUS=$STATE/status
    REQUEST=''${NODE_UPDATER_REQUEST:-${lib.escapeShellArg cfg.requestFile}}
    URL=''${NODE_UPDATER_REPO:-${lib.escapeShellArg cfg.repoUrl}}
    UNIT=${lib.escapeShellArg cfg.bitcoindUnit}
    PROFILE=/nix/var/nix/profiles/system
    STOP_AFTER=''${NODE_UPDATER_STOP_AFTER:-}
    tag=""

    mkdir -p "$STATE"
    chmod 755 "$STATE"
    : > "$LOG"
    chmod 644 "$LOG"
    exec >>"$LOG" 2>&1

    log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
    status() { # state message
      jq -n --arg s "$1" --arg m "$2" --arg t "$tag" --argjson ts "$(date +%s)" \
        '{state: $s, message: $m, tag: $t, timestamp: $ts}' > "$STATUS.tmp"
      chmod 644 "$STATUS.tmp"
      mv "$STATUS.tmp" "$STATUS"
    }
    fail() { log "FAILED: $*"; status failed "$*"; exit 1; }

    # ---- the request ------------------------------------------------------------------------
    if [ ! -s "$REQUEST" ]; then
      fail "no update request in $REQUEST"
    fi
    IFS= read -r tag < "$REQUEST" || true
    rm -f "$REQUEST"
    tag=''${tag//[[:space:]]/}
    case "$tag" in
      v*) ;;
      *) fail "not a release tag: '$tag'" ;;
    esac
    if ! printf '%s' "$tag" | grep -Eq '^v[0-9A-Za-z._-]+$'; then
      fail "not a release tag: '$tag'"
    fi
    ${lib.optionalString (image.variant == "unknown") ''
      fail "this system does not record which image variant it is (datum-node-image.variant); refusing to update"
    ''}
    log "update to $tag requested (variant ${image.variant}, running $(readlink -f /run/current-system))"
    status running "fetching $tag"

    # ---- the release keys of the installed image --------------------------------------------
    export GNUPGHOME
    GNUPGHOME=$(mktemp -d)
    trap 'rm -rf "$GNUPGHOME"' EXIT
    chmod 700 "$GNUPGHOME"
    nkeys=0
    for k in "$KEYS"/*.asc; do
      [ -e "$k" ] || continue
      if gpg --batch --quiet --import "$k" 2>>"$LOG"; then
        nkeys=$((nkeys + 1))
      else
        log "warning: could not import $k"
      fi
    done
    [ "$nkeys" -gt 0 ] || fail "no release keys in $KEYS"
    log "$nkeys release key(s): $(gpg --batch --list-keys --with-colons 2>/dev/null | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }' | tr '\n' ' ')"

    # ---- fetch the tag (shallow) ------------------------------------------------------------
    export GIT_TERMINAL_PROMPT=0
    if [ ! -d "$REPO/.git" ]; then
      rm -rf "$REPO"
      git init -q "$REPO" || fail "git init failed"
      git -C "$REPO" remote add origin "$URL" || fail "git remote add failed"
    fi
    git -C "$REPO" remote set-url origin "$URL"
    if ! git -C "$REPO" fetch -q --depth 1 --force origin "refs/tags/$tag:refs/tags/$tag"; then
      fail "could not fetch tag $tag from $URL"
    fi

    # ---- verify ------------------------------------------------------------------------------
    status running "verifying the signature on $tag"
    if ! git -C "$REPO" verify-tag "$tag"; then
      fail "tag $tag is not signed by a release key of this image; refusing to update"
    fi
    log "tag $tag verified"
    commit=$(git -C "$REPO" rev-parse "$tag^{commit}") || fail "cannot resolve $tag"
    git -C "$REPO" checkout -q --detach "$commit" || fail "checkout failed"
    git -C "$REPO" clean -fdxq || true
    log "tag $tag -> commit $commit"
    if [ "$STOP_AFTER" = verify ]; then
      status ok "verified $tag ($commit); stopped after verification as requested"
      exit 0
    fi

    # ---- build -------------------------------------------------------------------------------
    status running "building $tag (the node keeps running; this can take a while)"
    log "nix build git+file://$REPO?shallow=1#${flakeAttr}"
    toplevel=$(nix build --max-jobs 1 --no-link --print-out-paths \
      "git+file://$REPO?shallow=1#${flakeAttr}") || fail "build of $tag failed"
    log "built $toplevel"
    if [ ! -x "$toplevel/bin/switch-to-configuration" ]; then
      fail "$toplevel is not a NixOS system"
    fi
    if [ "$STOP_AFTER" = build ]; then
      status ok "built $tag as $toplevel; stopped before the switch as requested"
      exit 0
    fi
    previous=$(readlink -f /run/current-system)
    if [ "$toplevel" = "$previous" ]; then
      log "already running $toplevel"
      status ok "already up to date: $tag is what runs now"
      exit 0
    fi

    # ---- switch ------------------------------------------------------------------------------
    status running "switching to $tag"
    nix-env -p "$PROFILE" --set "$toplevel" || fail "could not set the system profile"
    # switch-to-configuration returns non-zero when some unit failed to (re)start; the health
    # check below decides whether that matters
    "$toplevel/bin/switch-to-configuration" switch || log "switch-to-configuration exited $?"
    log "switched; waiting for $UNIT"

    rollback() {
      log "rolling back to $previous"
      status running "rolling back to the previous system"
      "$previous/bin/switch-to-configuration" switch || log "rollback switch exited $?"
      nix-env -p "$PROFILE" --set "$previous" || log "could not reset the system profile"
      fail "$1; rolled back to the previous system"
    }

    deadline=$(( $(date +%s) + ${toString cfg.healthTimeout} ))
    while [ "$(systemctl is-active "$UNIT")" != active ]; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        rollback "$UNIT did not become active within ${toString cfg.healthTimeout} s after the switch"
      fi
      sleep 3
    done
    # a Knots build that rejects the node's snapshot exits a few seconds after it starts; watch for that
    restarts=$(systemctl show -p NRestarts --value "$UNIT")
    settle_until=$(( $(date +%s) + ${toString cfg.settleSeconds} ))
    while [ "$(date +%s)" -lt "$settle_until" ]; do
      sleep 3
      if [ "$(systemctl is-active "$UNIT")" != active ] || [ "$(systemctl show -p NRestarts --value "$UNIT")" != "$restarts" ]; then
        rollback "$UNIT stopped or restarted right after the switch: $(journalctl -u "$UNIT" -n 3 --no-pager -o cat | tail -n 3 | tr '\n' ' ')"
      fi
    done
    log "ok: $UNIT is active, running $(readlink -f /run/current-system)"
    status ok "updated to $tag"
  '';
in
{
  options.services.node-updater = {
    enable = lib.mkEnableOption "updating the image to a signed release tag from the setup page";

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/chrisguida/datum-node-image";
      description = "Git repository whose signed tags are releases.";
    };

    releaseKeys = lib.mkOption {
      type = lib.types.path;
      default = ../data/release-keys;
      defaultText = lib.literalExpression "./data/release-keys";
      description = ''
        Directory of ASCII-armored OpenPGP public keys (`*.asc`) allowed to sign release tags.
        Installed at /etc/datum-node-image/release-keys; a tag is accepted only when the keys of
        the image that is running right now verify it.
      '';
    };

    requestFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/datum-wizard/update-request";
      description = "File holding the requested tag (one line), written by the setup page.";
    };

    bitcoindUnit = lib.mkOption {
      type = lib.types.str;
      default = "bitcoind-blake2b.service";
      description = "The unit that must be active after the switch, or the update is rolled back.";
    };

    healthTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Seconds to wait for `bitcoindUnit` to be active after the switch before rolling back.";
    };

    settleSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = "Seconds the node must then stay active without a restart (a Knots build that cannot use the node's snapshot exits within this time).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."datum-node-image/release-keys".source = cfg.releaseKeys;

    systemd.services.node-updater = {
      description = "Update the image to a signed release tag";
      # the switch happens from inside this unit; never let switch-to-configuration stop or restart it
      restartIfChanged = false;
      stopIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.gitMinimal
        pkgs.gnupg
        pkgs.jq
        pkgs.gnutar
        pkgs.xz
        pkgs.gzip
        config.nix.package.out
        config.systemd.package
      ];
      environment = config.nix.envVars // {
        HOME = "/root";
      } // config.networking.proxy.envVars;
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "node-updater";
        StateDirectoryMode = "0755";
        ExecStart = script;
        TimeoutStartSec = "infinity";
        # a build next to a running node: single job, low priority
        Nice = 10;
      };
    };
  };
}
