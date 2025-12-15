{
  config,
  lib,
  pkgs,
  ...
}:

let
  backupCfg = config.services.bw-backup;
  syncCfg = config.services.bw-sync;

  envList = env: lib.mapAttrsToList (n: v: "${n}=${toString v}") env;

  backupDir = backupCfg.backupPath;
  syncDir = syncCfg.workDir;

  ensureUser = backupCfg.enable || syncCfg.enable;
in
{
  options = {
    services.bw-backup = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./bw-backup.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./bw-backup.nix { }";
        description = "Package providing the bw-backup script.";
      };

      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable periodic Bitwarden backups.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "bw-backup";
        description = "System user used to run backup jobs.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "bw-backup";
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
    };

    services.bw-sync = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./bw-sync.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./bw-sync.nix { }";
        description = "Package providing the bw-sync script.";
      };

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
        default = "/var/lib/bw-sync";
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
        assertion = !(backupCfg.monit.enable && !backupCfg.enable);
        message = "services.bw-backup.monit.enable requires services.bw-backup.enable";
      }
    ];

    users.groups = lib.mkMerge [
      (lib.mkIf backupCfg.enable { ${backupCfg.group} = { }; })
      (lib.mkIf syncCfg.enable { ${syncCfg.group} = { }; })
    ];

    users.users = lib.mkMerge [
      (lib.mkIf backupCfg.enable {
        ${backupCfg.user} = {
          isSystemUser = true;
          inherit (backupCfg) group;
          home = backupDir;
          createHome = true;
        };
      })
      (lib.mkIf syncCfg.enable {
        ${syncCfg.user} = {
          isSystemUser = true;
          inherit (syncCfg) group;
          home = syncDir;
          createHome = true;
        };
      })
    ];

    systemd = {
      tmpfiles.rules =
        (lib.optional backupCfg.enable "d ${backupDir} 0750 ${backupCfg.user} ${backupCfg.group} -")
        ++ (lib.optional syncCfg.enable "d ${syncDir} 0750 ${syncCfg.user} ${syncCfg.group} -");

      services.bw-backup = lib.mkIf backupCfg.enable {
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
              BW_BACKUP_DIR = backupDir;
              BW_BACKUP_RETENTION = toString backupCfg.retention;
            }
            // backupCfg.environment
          );
          ExecStart = "${backupCfg.package}/bin/bw-backup";
        };
      };

      timers.bw-backup = lib.mkIf backupCfg.enable {
        description = "Run Bitwarden backup";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = backupCfg.schedule;
          Persistent = true;
        };
      };

      services.bw-sync = lib.mkIf syncCfg.enable {
        description = "Bitwarden vault sync";
        serviceConfig = {
          Type = "oneshot";
          User = syncCfg.user;
          Group = syncCfg.group;
          WorkingDirectory = syncDir;
          ReadWritePaths = [ syncDir ];
          EnvironmentFile = syncCfg.environmentFiles;
          Environment = envList (syncCfg.environment // { WORKDIR = syncDir; });
          ExecStart = "${syncCfg.package}/bin/bw-sync";
        };
      };

      timers.bw-sync = lib.mkIf syncCfg.enable {
        description = "Run Bitwarden vault sync";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = syncCfg.period;
          Persistent = true;
        };
      };
    };

    services.monit.config = lib.mkIf (backupCfg.enable && backupCfg.monit.enable) (
      let
        lastBackupCheck = pkgs.writeShellScript "bw-last-backup" ''
          set -euo pipefail
          THRESHOLD=''${1:-${toString backupCfg.monit.thresholdSeconds}}
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
