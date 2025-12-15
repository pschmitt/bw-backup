{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.bw-backup;

  envList = env: lib.mapAttrsToList (n: v: "${n}=${toString v}") env;

  backupDir = cfg.backup.backupPath;
  syncDir = cfg.sync.workDir;

  ensureUser = cfg.backup.enable || cfg.sync.enable;
in
{
  options.bw-backup = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./bw-backup.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./bw-backup.nix { }";
      description = "Package providing the bw-backup script.";
    };

    syncPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./bw-sync.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./bw-sync.nix { }";
      description = "Package providing the bw-sync script.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "bw-backup";
      description = "System user used to run backup and sync jobs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "bw-backup";
      description = "System group used to run backup and sync jobs.";
    };

    backup = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable periodic Bitwarden backups.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = cfg.user;
        description = "System user used to run backup jobs.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = cfg.group;
        description = "System group used to run backup jobs.";
      };

      backupPath = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/bw-backup/backups";
        description = "Directory where backups are written.";
      };

      retention = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "Number of backups to keep (0 disables rotation).";
      };

      monit = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable Monit check for backup freshness.";
        };

        thresholdSeconds = lib.mkOption {
          type = lib.types.int;
          default = 86400;
          description = "Maximum allowed age of the last backup timestamp before Monit alerts.";
        };
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "systemd OnCalendar expression for backups.";
        example = "00:30";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Environment files to source for bw-backup.";
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Extra environment variables passed to bw-backup.
          Use this to provide BW_* credentials, ENCRYPTION_PASSPHRASE, BW_BACKUP_RETENTION, HEALTHCHECK_URL, etc.
        '';
      };
    };

    sync = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable syncing between two vaults.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "bw-sync";
        description = "System user used to run sync jobs.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "bw-sync";
        description = "System group used to run sync jobs.";
      };

      period = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "systemd OnCalendar expression for sync runs.";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Environment files to source for bw-sync.";
      };

      workDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/bw-backup/sync";
        description = "Persistent work directory for sync scratch data and attachments.";
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Extra environment variables passed to bw-sync.
          Provide SRC_BW_* and DEST_BW_* values here as needed.
        '';
      };
    };

  };

  config = lib.mkIf ensureUser {
    assertions = [
      {
        assertion = !(cfg.backup.monit.enable && !cfg.backup.enable);
        message = "bw-backup.backup.monit.enable requires bw-backup.backup.enable";
      }
    ];

    users.groups = lib.mkMerge [
      (lib.mkIf cfg.backup.enable { ${cfg.backup.group} = { }; })
      (lib.mkIf cfg.sync.enable { ${cfg.sync.group} = { }; })
    ];

    users.users = lib.mkMerge [
      (lib.mkIf cfg.backup.enable {
        ${cfg.backup.user} = {
          isSystemUser = true;
          inherit (cfg.backup) group;
          home = backupDir;
          createHome = true;
        };
      })
      (lib.mkIf cfg.sync.enable {
        ${cfg.sync.user} = {
          isSystemUser = true;
          inherit (cfg.sync) group;
          home = syncDir;
          createHome = true;
        };
      })
    ];

    systemd = {
      tmpfiles.rules =
        (lib.optional cfg.backup.enable "d ${backupDir} 0750 ${cfg.backup.user} ${cfg.backup.group} -")
        ++ (lib.optional cfg.sync.enable "d ${syncDir} 0750 ${cfg.sync.user} ${cfg.sync.group} -");

      services.bw-backup = lib.mkIf cfg.backup.enable {
        description = "Bitwarden backup";
        serviceConfig = {
          Type = "oneshot";
          User = cfg.backup.user;
          Group = cfg.backup.group;
          WorkingDirectory = backupDir;
          ReadWritePaths = [ backupDir ];
          EnvironmentFile = cfg.backup.environmentFiles;
          Environment = envList (
            {
              BW_BACKUP_DIR = backupDir;
              BW_BACKUP_RETENTION = toString cfg.backup.retention;
            }
            // cfg.backup.environment
          );
          ExecStart = "${cfg.package}/bin/bw-backup";
        };
      };

      timers.bw-backup = lib.mkIf cfg.backup.enable {
        description = "Run Bitwarden backup";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;
        };
      };

      services.bw-sync = lib.mkIf cfg.sync.enable {
        description = "Bitwarden vault sync";
        serviceConfig = {
          Type = "oneshot";
          User = cfg.sync.user;
          Group = cfg.sync.group;
          WorkingDirectory = syncDir;
          ReadWritePaths = [ syncDir ];
          EnvironmentFile = cfg.sync.environmentFiles;
          Environment = envList (cfg.sync.environment // { WORKDIR = syncDir; });
          ExecStart = "${cfg.syncPackage}/bin/bw-sync";
        };
      };

      timers.bw-sync = lib.mkIf cfg.sync.enable {
        description = "Run Bitwarden vault sync";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.sync.period;
          Persistent = true;
        };
      };
    };

    services.monit.config = lib.mkIf (cfg.backup.enable && cfg.backup.monit.enable) (
      let
        lastBackupCheck = pkgs.writeShellScript "bw-last-backup" ''
          set -euo pipefail
          THRESHOLD=''${1:-${toString cfg.backup.monit.thresholdSeconds}}
          NOW=$(${pkgs.coreutils}/bin/date '+%s')
          LAST_FILE="${backupDir}/LAST_BACKUP"

          if [[ ! -s "$LAST_FILE" ]]
          then
            echo "🚨 No backup timestamp found"
            exit 1
          fi

          LAST_BACKUP=$(${pkgs.coreutils}/bin/cat "$LAST_FILE")

          if [[ $((NOW - LAST_BACKUP)) -gt $THRESHOLD ]]
          then
            echo "🚨 Last backup was more than $THRESHOLD seconds ago"
            echo "📅 $(${pkgs.coreutils}/bin/date -d "@$LAST_BACKUP")"
            exit 1
          else
            echo "✅ Last backup is fresh enough"
            echo "📅 $(${pkgs.coreutils}/bin/date -d "@$LAST_BACKUP")"
            exit 0
          fi
        '';
      in
      lib.mkAfter ''
        check program "bw-backup" with path "${lastBackupCheck}"
          group backup
          every 2 cycles
          if status > 0 then alert
      ''
    );
  };
}
