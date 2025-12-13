{ config, lib, pkgs, ... }:

let
  cfg = config.bw-backup;

  envList = env:
    lib.mapAttrsToList (n: v: "${n}=${toString v}") env;

  ensureUser = cfg.backup.enable || cfg.sync.enable;
in
{
  options.bw-backup = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.bw-backup;
      defaultText = lib.literalExpression "pkgs.bw-backup";
      description = "Package providing the bw-backup script.";
    };

    syncPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.bw-sync;
      defaultText = lib.literalExpression "pkgs.bw-sync";
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

    backupPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/bw-backup/backups";
      description = "Directory where backups are written.";
    };

    backup = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable periodic Bitwarden backups.";
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
          Use this to provide BW_* credentials, ENCRYPTION_PASSPHRASE, KEEP, HEALTHCHECK_URL, etc.
        '';
      };
    };

    sync = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable syncing between two vaults.";
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

  config = lib.mkIf ensureUser {
    assertions = [
      {
        assertion = !(cfg.monit.enable && !cfg.backup.enable);
        message = "bw-backup.monit.enable requires bw-backup.backup.enable";
      }
    ];

    users.groups.${cfg.group} = { };

    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) group;
      home = cfg.backupPath;
      createHome = true;
    };

    systemd = {
      tmpfiles.rules =
        (lib.optional cfg.backup.enable "d ${cfg.backupPath} 0750 ${cfg.user} ${cfg.group} -")
        ++ (lib.optional cfg.sync.enable "d ${cfg.sync.workDir} 0750 ${cfg.user} ${cfg.group} -");

      services.bw-backup = lib.mkIf cfg.backup.enable {
        description = "Bitwarden backup";
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.backupPath;
          ReadWritePaths = [ cfg.backupPath ];
          BindPaths = [ "${cfg.backupPath}:/data" ];
          EnvironmentFile = cfg.backup.environmentFiles;
          Environment = envList cfg.backup.environment;
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
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.sync.workDir;
          ReadWritePaths = [ cfg.sync.workDir ];
          EnvironmentFile = cfg.sync.environmentFiles;
          Environment = envList (cfg.sync.environment // { WORKDIR = cfg.sync.workDir; });
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

    services.monit.config = lib.mkIf cfg.monit.enable (let
      lastBackupCheck = pkgs.writeShellScript "bw-last-backup" ''
        set -euo pipefail
        THRESHOLD=''${1:-${toString cfg.monit.thresholdSeconds}}
        NOW=$(${pkgs.coreutils}/bin/date '+%s')
        LAST_FILE="${cfg.backupPath}/LAST_BACKUP"

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
      '');
  };
}
