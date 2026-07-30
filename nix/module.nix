{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;

  backupCfg = config.services.bw-backup;
  syncCfg = config.services.bw-sync;
  collectionsCfg = syncCfg.collections;

  # systemd's `Environment=` word-splits unquoted values on whitespace, so a
  # value containing a space (an org/collection name, say) silently gets
  # truncated at the first one unless quoted -- NixOS's systemd module does
  # not do this quoting for us. None of this module's values ever contain a
  # literal `"`, so plain wrapping (no embedded-quote escaping) is enough.
  envList = env: lib.mapAttrsToList (n: v: ''${n}="${toString v}"'') env;

  backupDir = backupCfg.backupPath;
  syncDir = syncCfg.workDir;
  collectionsDir = collectionsCfg.workDir;

  ensureBackupUser = backupCfg.enable;
  ensureSyncUser = syncCfg.enable || collectionsCfg.enable;

  # rbw account config.json only ever needs non-secret connection metadata
  # (name/email/base_url/sso_id) -- the master password and, for
  # bitwarden.com, the personal-API-key used by `rbw register` are never
  # written to disk here. Both are supplied at service-start time as plain
  # environment variables (via environmentFiles, same as every other
  # credential this module already handles) and fed to `rbw` over stdin.
  accountModule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "rbw account name (used with --account/RBW_ACCOUNT).";
      };

      email = mkOption {
        type = types.str;
        description = "Email address to log into this account with.";
      };

      baseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Server URL for this account. Omit for the official bitwarden.com.";
        example = "https://vault.example.com";
      };

      ssoId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "SSO organization ID for this account, if applicable.";
      };
    };
  };

  renderAccount =
    a:
    {
      inherit (a) name email;
    }
    // lib.optionalAttrs (a.baseUrl != null) { base_url = a.baseUrl; }
    // lib.optionalAttrs (a.ssoId != null) { sso_id = a.ssoId; };

  # Renders rbw's config.json for a set of accounts. Placed via tmpfiles
  # (see below), not `environment.etc`, since it's per-service-user rather
  # than system-wide.
  mkRbwConfigFile =
    accounts:
    pkgs.writeText "rbw-config.json" (
      builtins.toJSON {
        accounts = map renderAccount accounts;
        primary_account = (lib.head accounts).name;
      }
    );

  rbwConfigTmpfiles =
    {
      user,
      group,
      home,
      accounts,
    }:
    [
      "d ${home}/.config 0750 ${user} ${group} -"
      "d ${home}/.config/rbw 0750 ${user} ${group} -"
      "L+ ${home}/.config/rbw/config.json - - - - ${mkRbwConfigFile accounts}"
    ];

  # Idempotently runs `rbw register --stdin` for an account, but only if
  # this specific service invocation was given that account's API key via
  # the named env vars -- a no-op (and no agent/network access) otherwise.
  # Safe to run on every service start: rbw only actually calls the
  # register endpoint when the account still needs its first login.
  mkRegisterCheck =
    {
      account,
      clientIdVar,
      clientSecretVar,
    }:
    ''
      if [[ -n "''${${clientIdVar}:-}" && -n "''${${clientSecretVar}:-}" ]]
      then
        printf '%s\n%s\n' "''${${clientIdVar}}" "''${${clientSecretVar}}" |
          ${pkgs.rbw}/bin/rbw --account ${lib.escapeShellArg account} register --stdin
      fi
    '';

  mkRegisterScript =
    name: checks:
    pkgs.writeShellScript "${name}-register" ''
      set -euo pipefail
      # rbw spawns rbw-agent via a plain PATH lookup (or $RBW_AGENT if set),
      # and this script otherwise runs with none of that set up.
      export PATH="${pkgs.rbw}/bin:$PATH"
      export RBW_AGENT="${pkgs.rbw}/bin/rbw-agent"
      ${lib.concatStringsSep "\n" checks}
    '';

  backupRegisterScript = mkRegisterScript "bw-backup" [
    (mkRegisterCheck {
      account = backupCfg.account.name;
      clientIdVar = "BW_BACKUP_REGISTER_CLIENT_ID";
      clientSecretVar = "BW_BACKUP_REGISTER_CLIENT_SECRET";
    })
  ];

  syncRegisterScript = mkRegisterScript "bw-sync" [
    (mkRegisterCheck {
      account = syncCfg.sourceAccount.name;
      clientIdVar = "SRC_REGISTER_CLIENT_ID";
      clientSecretVar = "SRC_REGISTER_CLIENT_SECRET";
    })
    (mkRegisterCheck {
      account = syncCfg.destAccount.name;
      clientIdVar = "DEST_REGISTER_CLIENT_ID";
      clientSecretVar = "DEST_REGISTER_CLIENT_SECRET";
    })
  ];

  mkLastRunCheck =
    {
      name,
      label,
      file,
      thresholdSeconds,
    }:
    pkgs.writeShellScript name ''
      set -euo pipefail
      THRESHOLD=''${1:-${toString thresholdSeconds}}
      NOW=$(${pkgs.coreutils}/bin/date '+%s')
      LAST_FILE="${file}"

      if [[ ! -s "$LAST_FILE" ]]
      then
        echo "🚨 No ${label} timestamp found"
        exit 1
      fi

      LAST_RUN=$(${pkgs.coreutils}/bin/cat "$LAST_FILE")

      if [[ $((NOW - LAST_RUN)) -gt $THRESHOLD ]]
      then
        echo "🚨 Last ${label} was more than $THRESHOLD seconds ago"
        echo "📅 $(${pkgs.coreutils}/bin/date -d "@$LAST_RUN")"
        exit 1
      else
        echo "✅ Last ${label} is fresh enough"
        echo "📅 $(${pkgs.coreutils}/bin/date -d "@$LAST_RUN")"
        exit 0
      fi
    '';
in
{
  options = {
    services.bw-backup = {
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./bw-backup.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./bw-backup.nix { }";
        description = "Package providing the bw-backup script.";
      };

      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable periodic Bitwarden backups.";
      };

      account = mkOption {
        type = accountModule;
        description = "The rbw account to back up.";
        example = lib.literalExpression ''
          {
            name = "backup";
            email = "me@example.com";
          }
        '';
      };

      user = mkOption {
        type = types.str;
        default = "bw-backup";
        description = "System user used to run backup jobs.";
      };

      group = mkOption {
        type = types.str;
        default = "bw-backup";
        description = "System group used to run backup jobs.";
      };

      backupPath = mkOption {
        type = types.str;
        default = "/var/lib/bw-backup/backups";
        description = "Directory where backups are written.";
      };

      retention = mkOption {
        type = types.int;
        default = 30;
        description = "Number of backups to keep (0 disables rotation).";
      };

      schedule = mkOption {
        type = types.str;
        default = "daily";
        description = "systemd OnCalendar expression for backups.";
        example = "00:30";
      };

      environmentFiles = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = ''
          Environment files to source for bw-backup. Use this to provide
          BW_PASSWORD (the account's master password), ENCRYPTION_PASSPHRASE,
          HEALTHCHECK_URL, and -- if `account` targets the official
          bitwarden.com and hasn't been registered yet --
          BW_BACKUP_REGISTER_CLIENT_ID/BW_BACKUP_REGISTER_CLIENT_SECRET
          (the account's personal API key, used once to run `rbw register`
          non-interactively).
        '';
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Extra environment variables passed to bw-backup.";
      };

      monit = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable Monit check for backup freshness.";
        };

        thresholdSeconds = mkOption {
          type = types.int;
          default = 86400;
          description = "Maximum allowed age of the last backup timestamp before Monit alerts.";
        };
      };
    };

    services.bw-sync = {
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./bw-sync.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./bw-sync.nix { }";
        description = "Package providing the bw-sync script.";
      };

      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the 1:1 personal-vault mirror sync job.";
      };

      sourceAccount = mkOption {
        type = accountModule;
        description = "The rbw account to mirror from.";
      };

      destAccount = mkOption {
        type = accountModule;
        description = "The rbw account to mirror into.";
      };

      purgeDestination = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Wipe the destination's personal vault before importing (via `rbw
          mirror --purge-dest`, the same server-side purge endpoint `rbw
          purge-vault` uses). Entries assigned to an organization
          collection are never touched by this, regardless.
        '';
      };

      user = mkOption {
        type = types.str;
        default = "bw-sync";
        description = "System user used to run sync jobs (shared by the personal and collections jobs).";
      };

      group = mkOption {
        type = types.str;
        default = "bw-sync";
        description = "System group used to run sync jobs.";
      };

      period = mkOption {
        type = types.str;
        default = "daily";
        description = "systemd OnCalendar expression for the personal sync job.";
      };

      environmentFiles = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = ''
          Environment files to source for both the personal and collections
          sync jobs. Use this to provide SRC_BW_PASSWORD/DEST_BW_PASSWORD
          (the two accounts' master passwords), HEALTHCHECK_URL, and --
          for whichever account targets the official bitwarden.com and
          hasn't been registered yet --
          SRC_REGISTER_CLIENT_ID/SRC_REGISTER_CLIENT_SECRET and/or
          DEST_REGISTER_CLIENT_ID/DEST_REGISTER_CLIENT_SECRET.
        '';
      };

      workDir = mkOption {
        type = types.str;
        default = "/var/lib/bw-sync/data";
        description = "Persistent work directory for the personal sync job's state (LAST_SYNC marker).";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Extra environment variables passed to both sync jobs.";
      };

      monit = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable Monit check for personal-sync freshness.";
        };

        thresholdSeconds = mkOption {
          type = types.int;
          default = 86400;
          description = "Maximum allowed age of the last sync timestamp before Monit alerts.";
        };
      };

      collections = {
        enable = mkEnableOption "mirroring the source vault into one or more destination organization collections";

        org = mkOption {
          type = types.str;
          description = ''
            Name of the destination organization to mirror into. Created
            automatically (under destAccount) if it doesn't already exist.
          '';
          example = "Example-Org";
        };

        names = mkOption {
          type = types.listOf types.nonEmptyStr;
          description = ''
            Names of the collections (within `org`) to mirror the source
            vault into. Each collection gets its own full, independent
            mirror (not a folder/tag split) -- entries removed from the
            source are also removed from every collection listed here.
            Any collection that doesn't already exist is created
            automatically.
          '';
          example = [
            "default"
            "Some Other Collection"
          ];
        };

        period = mkOption {
          type = types.str;
          default = "daily";
          description = "systemd OnCalendar expression for the collections sync job.";
        };

        workDir = mkOption {
          type = types.str;
          default = "/var/lib/bw-sync/collections-data";
          description = ''
            Persistent work directory for the collections sync job's state
            (LAST_SYNC marker) -- kept separate from the personal job's
            `workDir` so the two jobs' freshness markers can't clobber
            each other.
          '';
        };

        monit = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Enable Monit check for collections-sync freshness.";
          };

          thresholdSeconds = mkOption {
            type = types.int;
            default = 86400;
            description = "Maximum allowed age of the last sync timestamp before Monit alerts.";
          };
        };
      };
    };
  };

  config = lib.mkIf (ensureBackupUser || ensureSyncUser) {
    assertions = [
      {
        assertion = !(backupCfg.monit.enable && !backupCfg.enable);
        message = "services.bw-backup.monit.enable requires services.bw-backup.enable";
      }
      {
        assertion = !(syncCfg.monit.enable && !syncCfg.enable);
        message = "services.bw-sync.monit.enable requires services.bw-sync.enable";
      }
      {
        assertion = !(collectionsCfg.monit.enable && !collectionsCfg.enable);
        message = "services.bw-sync.collections.monit.enable requires services.bw-sync.collections.enable";
      }
      {
        assertion = !collectionsCfg.enable || collectionsCfg.names != [ ];
        message = "services.bw-sync.collections.names must not be empty when services.bw-sync.collections.enable is set";
      }
    ];

    users.groups = lib.mkMerge [
      (lib.mkIf ensureBackupUser { ${backupCfg.group} = { }; })
      (lib.mkIf ensureSyncUser { ${syncCfg.group} = { }; })
    ];

    users.users = lib.mkMerge [
      (lib.mkIf ensureBackupUser {
        ${backupCfg.user} = {
          isSystemUser = true;
          inherit (backupCfg) group;
          home = "/var/lib/${backupCfg.user}";
          createHome = true;
        };
      })
      (lib.mkIf ensureSyncUser {
        ${syncCfg.user} = {
          isSystemUser = true;
          inherit (syncCfg) group;
          home = "/var/lib/${syncCfg.user}";
          createHome = true;
        };
      })
    ];

    systemd = {
      tmpfiles.rules =
        (lib.optional ensureBackupUser "Z ${backupDir} 0750 ${backupCfg.user} ${backupCfg.group} -")
        ++ (lib.optional syncCfg.enable "Z ${syncDir} 0750 ${syncCfg.user} ${syncCfg.group} -")
        ++ (lib.optional collectionsCfg.enable "Z ${collectionsDir} 0750 ${syncCfg.user} ${syncCfg.group} -")
        # Ensure parent directory of backupPath exists if it is not inside the user's home
        ++ (lib.optional (
          ensureBackupUser && (dirOf backupDir) != config.users.users.${backupCfg.user}.home
        ) "z ${dirOf backupDir} 0750 ${backupCfg.user} ${backupCfg.group} -")
        # Ensure parent directory of workDir/collections workDir exists if not inside the user's home
        ++ (lib.optional (
          syncCfg.enable && (dirOf syncDir) != config.users.users.${syncCfg.user}.home
        ) "z ${dirOf syncDir} 0750 ${syncCfg.user} ${syncCfg.group} -")
        ++ (lib.optional (
          collectionsCfg.enable && (dirOf collectionsDir) != config.users.users.${syncCfg.user}.home
        ) "z ${dirOf collectionsDir} 0750 ${syncCfg.user} ${syncCfg.group} -")
        ++ (lib.optionals ensureBackupUser (rbwConfigTmpfiles {
          inherit (backupCfg) user group;
          home = config.users.users.${backupCfg.user}.home;
          accounts = [ backupCfg.account ];
        }))
        ++ (lib.optionals ensureSyncUser (rbwConfigTmpfiles {
          inherit (syncCfg) user group;
          home = config.users.users.${syncCfg.user}.home;
          accounts = [
            syncCfg.sourceAccount
            syncCfg.destAccount
          ];
        }));

      services = {
        bw-backup = lib.mkIf backupCfg.enable {
          description = "Bitwarden backup";
          serviceConfig = {
            Type = "oneshot";
            User = backupCfg.user;
            Group = backupCfg.group;
            WorkingDirectory = backupDir;
            ReadWritePaths = [ backupDir ];
            EnvironmentFile = backupCfg.environmentFiles;
            Environment = envList (
              {
                ACCOUNT = backupCfg.account.name;
                BW_BACKUP_DIR = backupDir;
                BW_BACKUP_RETENTION = toString backupCfg.retention;
              }
              // backupCfg.environment
            );
            ExecStartPre = "${backupRegisterScript}";
            ExecStart = "${backupCfg.package}/bin/bw-backup";
          };
        };

        bw-sync = lib.mkIf syncCfg.enable {
          description = "Bitwarden personal vault mirror sync";
          serviceConfig = {
            Type = "oneshot";
            User = syncCfg.user;
            Group = syncCfg.group;
            WorkingDirectory = syncDir;
            ReadWritePaths = [ syncDir ];
            EnvironmentFile = syncCfg.environmentFiles;
            Environment = envList (
              syncCfg.environment
              // {
                SRC_ACCOUNT = syncCfg.sourceAccount.name;
                DEST_ACCOUNT = syncCfg.destAccount.name;
                WORKDIR = syncDir;
                BW_SYNC_MODE = "personal";
              }
              // (lib.optionalAttrs syncCfg.purgeDestination { DEST_BW_PURGE_VAULT = "1"; })
            );
            ExecStartPre = "${syncRegisterScript}";
            ExecStart = "${syncCfg.package}/bin/bw-sync";
          };
        };

        bw-sync-collections = lib.mkIf collectionsCfg.enable {
          description = "Bitwarden organization collections mirror sync";
          serviceConfig = {
            Type = "oneshot";
            User = syncCfg.user;
            Group = syncCfg.group;
            WorkingDirectory = collectionsDir;
            ReadWritePaths = [ collectionsDir ];
            EnvironmentFile = syncCfg.environmentFiles;
            Environment = envList (
              syncCfg.environment
              // {
                SRC_ACCOUNT = syncCfg.sourceAccount.name;
                DEST_ACCOUNT = syncCfg.destAccount.name;
                WORKDIR = collectionsDir;
                BW_SYNC_MODE = "collections";
                DEST_BW_ORG = collectionsCfg.org;
                DEST_BW_COLLECTIONS = lib.concatStringsSep "," collectionsCfg.names;
              }
            );
            ExecStartPre = "${syncRegisterScript}";
            ExecStart = "${syncCfg.package}/bin/bw-sync";
          };
        };
      };

      timers = {
        bw-backup = lib.mkIf backupCfg.enable {
          description = "Run Bitwarden backup";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = backupCfg.schedule;
            Persistent = true;
          };
        };

        bw-sync = lib.mkIf syncCfg.enable {
          description = "Run Bitwarden personal vault mirror sync";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = syncCfg.period;
            Persistent = true;
          };
        };

        bw-sync-collections = lib.mkIf collectionsCfg.enable {
          description = "Run Bitwarden organization collections mirror sync";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = collectionsCfg.period;
            Persistent = true;
          };
        };
      };
    };

    services.monit.config = lib.mkMerge [
      (lib.mkIf (backupCfg.enable && backupCfg.monit.enable) (
        let
          lastBackupCheck = mkLastRunCheck {
            name = "bw-last-backup";
            label = "backup";
            file = "${backupDir}/LAST_BACKUP";
            inherit (backupCfg.monit) thresholdSeconds;
          };
        in
        lib.mkAfter ''
          check program "bw-backup" with path "${lastBackupCheck}"
            group backup
            every 2 cycles
            if status > 0 then alert
        ''
      ))
      (lib.mkIf (syncCfg.enable && syncCfg.monit.enable) (
        let
          lastSyncCheck = mkLastRunCheck {
            name = "bw-last-sync";
            label = "sync";
            file = "${syncDir}/LAST_SYNC";
            inherit (syncCfg.monit) thresholdSeconds;
          };
        in
        lib.mkAfter ''
          check program "bw-sync" with path "${lastSyncCheck}"
            group sync
            every 2 cycles
            if status > 0 then alert
        ''
      ))
      (lib.mkIf (collectionsCfg.enable && collectionsCfg.monit.enable) (
        let
          lastCollectionsSyncCheck = mkLastRunCheck {
            name = "bw-last-sync-collections";
            label = "collections sync";
            file = "${collectionsDir}/LAST_SYNC";
            inherit (collectionsCfg.monit) thresholdSeconds;
          };
        in
        lib.mkAfter ''
          check program "bw-sync-collections" with path "${lastCollectionsSyncCheck}"
            group sync
            every 2 cycles
            if status > 0 then alert
        ''
      ))
    ];
  };
}
