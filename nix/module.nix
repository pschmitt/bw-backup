{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  backupCfg = config.services.rbw-auto-backup;
  syncCfg = config.services.rbw-auto-sync;

  # systemd's `Environment=` word-splits unquoted values on whitespace, so a
  # value containing a space (an org/collection name, say) silently gets
  # truncated at the first one unless quoted -- NixOS's systemd module does
  # not do this quoting for us. None of this module's values ever contain a
  # literal `"`, so plain wrapping (no embedded-quote escaping) is enough.
  envList = env: lib.mapAttrsToList (n: v: ''${n}="${toString v}"'') env;

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

  # A oneshot job has no business keeping rbw-agent alive after it exits --
  # forcibly stops it for every account this job touched, tolerating an
  # account that was never unlocked (nothing to stop) or an already-dead
  # agent. Run via ExecStopPost, so it fires even if the job failed or was
  # killed (unlike a script-internal EXIT trap, which a SIGKILL bypasses).
  mkAgentStopScript =
    name: accounts:
    pkgs.writeShellScript "${name}-agent-stop" ''
      export PATH="${pkgs.rbw}/bin:$PATH"
      export RBW_AGENT="${pkgs.rbw}/bin/rbw-agent"
      ${lib.concatMapStringsSep "\n" (
        account:
        "${pkgs.rbw}/bin/rbw --account ${lib.escapeShellArg account} stop-agent &>/dev/null || true"
      ) accounts}
      exit 0
    '';

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

  # Each named backup/sync job gets its own independent systemd
  # service+timer (rbw-auto-backup-<name>/rbw-auto-sync-<name>), the way
  # `services.restic.backups.<name>` works -- rather than one fixed job (or,
  # for sync, one fixed job plus a single hardcoded "collections" variant).
  # Jobs of the same kind still share one system user/group (and therefore
  # one rbw config.json listing every account any of that kind's enabled
  # jobs use) since rbw's own multi-account support already keys entirely
  # off --account; there's no need for one Unix user per job.
  backupJobModule = types.submodule (
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable this backup job.";
        };

        account = mkOption {
          type = accountModule;
          description = "The rbw account to back up.";
          example = lib.literalExpression ''
            {
              name = "personal";
              email = "me@example.com";
            }
          '';
        };

        backupPath = mkOption {
          type = types.str;
          default = "/var/lib/bw-backup/${name}";
          description = "Directory where this job's backups are written.";
        };

        retention = mkOption {
          type = types.int;
          default = 30;
          description = "Number of backups to keep (0 disables rotation).";
        };

        schedule = mkOption {
          type = types.str;
          default = "daily";
          description = "systemd OnCalendar expression for this job.";
          example = "00:30";
        };

        environmentFiles = mkOption {
          type = types.listOf types.path;
          default = [ ];
          description = ''
            Environment files to source for this job. Use this to provide
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
          description = "Extra environment variables passed to this job.";
        };

        monit = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable a Monit check for this job's backup freshness.";
          };

          thresholdSeconds = mkOption {
            type = types.int;
            default = 86400;
            description = "Maximum allowed age of the last backup timestamp before Monit alerts.";
          };
        };
      };
    }
  );

  syncJobModule = types.submodule (
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable this sync job.";
        };

        sourceAccount = mkOption {
          type = accountModule;
          description = "The rbw account to mirror from.";
        };

        destAccount = mkOption {
          type = accountModule;
          description = "The rbw account to mirror into.";
        };

        mode = mkOption {
          type = types.enum [
            "personal"
            "collections"
          ];
          default = "personal";
          description = ''
            "personal": 1:1 mirror of sourceAccount's whole vault into
            destAccount's personal vault.
            "collections": mirror into one or more destAccount organization
            collections (see the `collections` option).
          '';
        };

        purgeDestination = mkOption {
          type = types.bool;
          default = false;
          description = ''
            "personal" mode only: wipe the destination's personal vault
            before importing (via `rbw mirror --purge-dest`, the same
            server-side purge endpoint `rbw purge-vault` uses). Entries
            assigned to an organization collection are never touched by
            this, regardless.
          '';
        };

        collections = {
          org = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              "collections" mode only: name of the destination organization
              to mirror into. Created automatically (under destAccount) if
              it doesn't already exist.
            '';
            example = "Example-Org";
          };

          names = mkOption {
            type = types.listOf types.nonEmptyStr;
            default = [ ];
            description = ''
              "collections" mode only: names of the collections (within
              `org`) to mirror into. A name matching an existing
              sourceAccount collection gets a scoped 1:1 mirror of just that
              collection; a name with no source-side match gets a full
              mirror of the entire source vault instead. Any destination
              collection that doesn't already exist is created
              automatically.
            '';
            example = [
              "default"
              "Some Other Collection"
            ];
          };
        };

        period = mkOption {
          type = types.str;
          default = "daily";
          description = "systemd OnCalendar expression for this job.";
        };

        workDir = mkOption {
          type = types.str;
          default = "/var/lib/bw-sync/${name}";
          description = "Persistent work directory for this job's state (LAST_SYNC marker).";
        };

        environmentFiles = mkOption {
          type = types.listOf types.path;
          default = [ ];
          description = ''
            Environment files to source for this job. Use this to provide
            SRC_BW_PASSWORD/DEST_BW_PASSWORD (the two accounts' master
            passwords), HEALTHCHECK_URL, and -- for whichever account
            targets the official bitwarden.com and hasn't been registered
            yet -- SRC_REGISTER_CLIENT_ID/SRC_REGISTER_CLIENT_SECRET and/or
            DEST_REGISTER_CLIENT_ID/DEST_REGISTER_CLIENT_SECRET.
          '';
        };

        environment = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Extra environment variables passed to this job.";
        };

        monit = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Enable a Monit check for this job's sync freshness.";
          };

          thresholdSeconds = mkOption {
            type = types.int;
            default = 86400;
            description = "Maximum allowed age of the last sync timestamp before Monit alerts.";
          };
        };
      };
    }
  );

  enabledBackups = lib.filterAttrs (_: b: b.enable) backupCfg.backups;
  enabledSyncs = lib.filterAttrs (_: s: s.enable) syncCfg.syncs;

  anyBackups = enabledBackups != { };
  anySyncs = enabledSyncs != { };

  backupAccountsRaw = lib.mapAttrsToList (_: b: b.account) enabledBackups;
  syncAccountsRaw = lib.concatMap (s: [
    s.sourceAccount
    s.destAccount
  ]) (lib.attrValues enabledSyncs);

  # Every job of a given kind shares one rbw config.json, so the same
  # account name used by two jobs must describe the exact same account --
  # otherwise whichever job's entry happens to win would silently point the
  # other job at the wrong email/server.
  conflictingAccountNames =
    accounts:
    let
      grouped = lib.groupBy (a: a.name) accounts;
    in
    lib.attrNames (lib.filterAttrs (_: accs: lib.length (lib.unique accs) > 1) grouped);

  backupAccounts = lib.unique backupAccountsRaw;
  syncAccounts = lib.unique syncAccountsRaw;
in
{
  options = {
    services.rbw-auto-backup = {
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./rbw-auto-backup.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./rbw-auto-backup.nix { }";
        description = "Package providing the rbw-auto-backup script.";
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

      backups = mkOption {
        type = types.attrsOf backupJobModule;
        default = { };
        description = ''
          Named Bitwarden backup jobs. Each gets its own independent
          systemd service+timer (`rbw-auto-backup-<name>`), so different
          accounts can be backed up on entirely different
          schedules/retention/paths.
        '';
        example = lib.literalExpression ''
          {
            personal = {
              account = { name = "personal"; email = "me@example.com"; };
              environmentFiles = [ config.sops.secrets."rbw-auto-backup-personal".path ];
            };
          }
        '';
      };
    };

    services.rbw-auto-sync = {
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./rbw-auto-sync.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./rbw-auto-sync.nix { }";
        description = "Package providing the rbw-auto-sync script.";
      };

      user = mkOption {
        type = types.str;
        default = "bw-sync";
        description = "System user used to run sync jobs.";
      };

      group = mkOption {
        type = types.str;
        default = "bw-sync";
        description = "System group used to run sync jobs.";
      };

      syncs = mkOption {
        type = types.attrsOf syncJobModule;
        default = { };
        description = ''
          Named Bitwarden vault-mirror sync jobs. Each gets its own
          independent systemd service+timer (`rbw-auto-sync-<name>`), so
          different account pairs/modes/schedules can run entirely
          independently of one another.
        '';
        example = lib.literalExpression ''
          {
            personal = {
              sourceAccount = { name = "personal"; email = "me@example.com"; };
              destAccount = { name = "vaultwarden"; email = "me@example.com"; baseUrl = "https://vault.example.com"; };
              purgeDestination = true;
              environmentFiles = [ config.sops.secrets."rbw-auto-sync-personal".path ];
            };
            org-collections = {
              sourceAccount = { name = "personal"; email = "me@example.com"; };
              destAccount = { name = "vaultwarden"; email = "me@example.com"; baseUrl = "https://vault.example.com"; };
              mode = "collections";
              collections = { org = "Example-Org"; names = [ "Shared" ]; };
              environmentFiles = [ config.sops.secrets."rbw-auto-sync-org-collections".path ];
            };
          }
        '';
      };
    };
  };

  config = lib.mkIf (anyBackups || anySyncs) {
    assertions = [
      {
        assertion =
          (conflictingAccountNames backupAccountsRaw == [ ])
          && (conflictingAccountNames syncAccountsRaw == [ ]);
        message = ''
          services.rbw-auto-backup/rbw-auto-sync: the same rbw account name
          is used by more than one job with different email/baseUrl/ssoId.
          All jobs sharing an account name must describe it identically.
        '';
      }
    ]
    ++ (lib.mapAttrsToList (name: job: {
      assertion =
        job.mode != "collections" || (job.collections.org != null && job.collections.names != [ ]);
      message = "services.rbw-auto-sync.syncs.${name}: mode = \"collections\" requires collections.org and a non-empty collections.names";
    }) enabledSyncs);

    users.groups = lib.mkMerge [
      (lib.mkIf anyBackups { ${backupCfg.group} = { }; })
      (lib.mkIf anySyncs { ${syncCfg.group} = { }; })
    ];

    users.users = lib.mkMerge [
      (lib.mkIf anyBackups {
        ${backupCfg.user} = {
          isSystemUser = true;
          inherit (backupCfg) group;
          home = "/var/lib/${backupCfg.user}";
          createHome = true;
        };
      })
      (lib.mkIf anySyncs {
        ${syncCfg.user} = {
          isSystemUser = true;
          inherit (syncCfg) group;
          home = "/var/lib/${syncCfg.user}";
          createHome = true;
        };
      })
    ];

    systemd = {
      tmpfiles.rules = lib.unique (
        (lib.mapAttrsToList (
          _: job: "Z ${job.backupPath} 0750 ${backupCfg.user} ${backupCfg.group} -"
        ) enabledBackups)
        ++ (lib.mapAttrsToList (
          _: job: "Z ${job.workDir} 0750 ${syncCfg.user} ${syncCfg.group} -"
        ) enabledSyncs)
        ++ (lib.concatMap (
          job:
          lib.optional (
            dirOf job.backupPath != config.users.users.${backupCfg.user}.home
          ) "z ${dirOf job.backupPath} 0750 ${backupCfg.user} ${backupCfg.group} -"
        ) (lib.attrValues enabledBackups))
        ++ (lib.concatMap (
          job:
          lib.optional (
            dirOf job.workDir != config.users.users.${syncCfg.user}.home
          ) "z ${dirOf job.workDir} 0750 ${syncCfg.user} ${syncCfg.group} -"
        ) (lib.attrValues enabledSyncs))
        ++ (lib.optionals anyBackups (rbwConfigTmpfiles {
          inherit (backupCfg) user group;
          home = config.users.users.${backupCfg.user}.home;
          accounts = backupAccounts;
        }))
        ++ (lib.optionals anySyncs (rbwConfigTmpfiles {
          inherit (syncCfg) user group;
          home = config.users.users.${syncCfg.user}.home;
          accounts = syncAccounts;
        }))
      );

      services =
        (lib.mapAttrs' (
          name: job:
          lib.nameValuePair "rbw-auto-backup-${name}" {
            description = "Bitwarden backup (${name})";
            serviceConfig = {
              Type = "oneshot";
              User = backupCfg.user;
              Group = backupCfg.group;
              WorkingDirectory = job.backupPath;
              ReadWritePaths = [ job.backupPath ];
              EnvironmentFile = job.environmentFiles;
              Environment = envList (
                {
                  ACCOUNT = job.account.name;
                  BW_BACKUP_DIR = job.backupPath;
                  BW_BACKUP_RETENTION = toString job.retention;
                }
                // job.environment
              );
              ExecStartPre = "${mkRegisterScript "rbw-auto-backup-${name}" [
                (mkRegisterCheck {
                  account = job.account.name;
                  clientIdVar = "BW_BACKUP_REGISTER_CLIENT_ID";
                  clientSecretVar = "BW_BACKUP_REGISTER_CLIENT_SECRET";
                })
              ]}";
              ExecStart = "${backupCfg.package}/bin/rbw-auto-backup";
              ExecStopPost = "${mkAgentStopScript "rbw-auto-backup-${name}" [ job.account.name ]}";
            };
          }
        ) enabledBackups)
        // (lib.mapAttrs' (
          name: job:
          lib.nameValuePair "rbw-auto-sync-${name}" {
            description = "Bitwarden vault mirror sync (${name}, ${job.mode})";
            serviceConfig = {
              Type = "oneshot";
              User = syncCfg.user;
              Group = syncCfg.group;
              WorkingDirectory = job.workDir;
              ReadWritePaths = [ job.workDir ];
              EnvironmentFile = job.environmentFiles;
              Environment = envList (
                {
                  SRC_ACCOUNT = job.sourceAccount.name;
                  DEST_ACCOUNT = job.destAccount.name;
                  WORKDIR = job.workDir;
                  BW_SYNC_MODE = job.mode;
                }
                // (lib.optionalAttrs (job.mode == "personal" && job.purgeDestination) {
                  DEST_BW_PURGE_VAULT = "1";
                })
                // (lib.optionalAttrs (job.mode == "collections") {
                  DEST_BW_ORG = job.collections.org;
                  DEST_BW_COLLECTIONS = lib.concatStringsSep "," job.collections.names;
                })
                // job.environment
              );
              ExecStartPre = "${mkRegisterScript "rbw-auto-sync-${name}" [
                (mkRegisterCheck {
                  account = job.sourceAccount.name;
                  clientIdVar = "SRC_REGISTER_CLIENT_ID";
                  clientSecretVar = "SRC_REGISTER_CLIENT_SECRET";
                })
                (mkRegisterCheck {
                  account = job.destAccount.name;
                  clientIdVar = "DEST_REGISTER_CLIENT_ID";
                  clientSecretVar = "DEST_REGISTER_CLIENT_SECRET";
                })
              ]}";
              ExecStart = "${syncCfg.package}/bin/rbw-auto-sync";
              ExecStopPost = "${mkAgentStopScript "rbw-auto-sync-${name}" [
                job.sourceAccount.name
                job.destAccount.name
              ]}";
            };
          }
        ) enabledSyncs);

      timers =
        (lib.mapAttrs' (
          name: job:
          lib.nameValuePair "rbw-auto-backup-${name}" {
            description = "Run Bitwarden backup (${name})";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = job.schedule;
              Persistent = true;
            };
          }
        ) enabledBackups)
        // (lib.mapAttrs' (
          name: job:
          lib.nameValuePair "rbw-auto-sync-${name}" {
            description = "Run Bitwarden vault mirror sync (${name})";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = job.period;
              Persistent = true;
            };
          }
        ) enabledSyncs);
    };

    services.monit.config = lib.mkMerge (
      (lib.mapAttrsToList (
        name: job:
        lib.mkIf job.monit.enable (
          let
            lastRunCheck = mkLastRunCheck {
              name = "rbw-auto-backup-${name}-last-run";
              label = "backup (${name})";
              file = "${job.backupPath}/LAST_BACKUP";
              inherit (job.monit) thresholdSeconds;
            };
          in
          lib.mkAfter ''
            check program "rbw-auto-backup-${name}" with path "${lastRunCheck}"
              group backup
              every 2 cycles
              if status > 0 then alert
          ''
        )
      ) enabledBackups)
      ++ (lib.mapAttrsToList (
        name: job:
        lib.mkIf job.monit.enable (
          let
            lastRunCheck = mkLastRunCheck {
              name = "rbw-auto-sync-${name}-last-run";
              label = "sync (${name})";
              file = "${job.workDir}/LAST_SYNC";
              inherit (job.monit) thresholdSeconds;
            };
          in
          lib.mkAfter ''
            check program "rbw-auto-sync-${name}" with path "${lastRunCheck}"
              group sync
              every 2 cycles
              if status > 0 then alert
          ''
        )
      ) enabledSyncs)
    );
  };
}
