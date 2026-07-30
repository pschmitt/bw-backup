#!/usr/bin/env bash

if [[ -n "$DEBUG" ]]
then
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

ACCOUNT="${ACCOUNT:-backup}"
LOCKFILE="${TMPDIR:-/tmp}/bw-backup.lock"
HEALTHCHECK_URL="${HEALTHCHECK_URL%/}"
BW_BACKUP_DIR="${BW_BACKUP_DIR:-/data}"
BW_BACKUP_DIR="${BW_BACKUP_DIR%/}"
BW_BACKUP_RETENTION_EXPLICIT=0
if [[ -n "${BW_BACKUP_RETENTION+x}" ]]
then
  BW_BACKUP_RETENTION_EXPLICIT=1
fi
BW_BACKUP_RETENTION="${BW_BACKUP_RETENTION:-${KEEP:-30}}"
BW_BACKUP_ATTACHMENTS="${BW_BACKUP_ATTACHMENTS:-1}"
BW_CURRENT_BACKUP_FILE=""

validate_backup_root() {
  if [[ -z "$BW_BACKUP_DIR" || "$BW_BACKUP_DIR" == "/" ]]
  then
    echo_error "Invalid BW_BACKUP_DIR: '$BW_BACKUP_DIR'"
    return 1
  fi
}

validate_retention() {
  if ! [[ "$BW_BACKUP_RETENTION" =~ ^[0-9]+$ ]]
  then
    echo_error "Invalid BW_BACKUP_RETENTION: '$BW_BACKUP_RETENTION' (expected integer)"
    return 1
  fi
}

bw_export() {
  validate_backup_root || return 1

  if ! rbw_prepare_account "$ACCOUNT" "$BW_PASSWORD"
  then
    healthcheck_ping fail "Login/unlock failed (bw-backup)"
    exit 1
  fi

  mkdir -p "$BW_BACKUP_DIR"
  if [[ -e "$CLEAR_DATA" ]]
  then
    rm -rf "${BW_BACKUP_DIR:?}/"*
  fi

  local ext="json"
  local -a export_args=(export)

  if [[ "$BW_BACKUP_ATTACHMENTS" == "1" ]]
  then
    export_args+=(--attachments)
  fi

  if [[ -z "$ENCRYPTION_PASSPHRASE" ]]
  then
    echo_info "No encryption passphrase provided. Skipping encryption."
  else
    export_args+=(--encrypt)
    ext="tar.gz.gpg"
    export RBW_EXPORT_PASSPHRASE="$ENCRYPTION_PASSPHRASE"
  fi

  BW_CURRENT_BACKUP_FILE="${BW_BACKUP_DIR}/bw-export-$(date -Iseconds).${ext}"

  echo_info "Exporting vault ($ACCOUNT) -> $BW_CURRENT_BACKUP_FILE"
  if ! rbw --account "$ACCOUNT" "${export_args[@]}" --output "$BW_CURRENT_BACKUP_FILE"
  then
    echo_error "Export failed."
    healthcheck_ping fail "Export failed (bw-backup)"
    exit 1
  fi

  ln -sfv "$(basename "$BW_CURRENT_BACKUP_FILE")" "${BW_BACKUP_DIR}/bw-export-latest"
  date '+%s' > "${BW_BACKUP_DIR}/LAST_BACKUP"
}

backup_rotate() {
  if [[ -z "$BW_BACKUP_RETENTION" || "$BW_BACKUP_RETENTION" == "0" ]]
  then
    echo_info "BW_BACKUP_RETENTION is unset or 0. Skip rotation."
    return 0
  fi

  validate_retention

  if [[ -n "${KEEP:-}" && "$BW_BACKUP_RETENTION_EXPLICIT" == "0" ]]
  then
    echo_warning "KEEP is deprecated; use BW_BACKUP_RETENTION instead."
  fi

  echo_info "Pruning old backups (keep: $BW_BACKUP_RETENTION)"

  # remove files
  local file
  find "$BW_BACKUP_DIR" -type f -name 'bw-export-*' | sort -nr | \
    tail -n +$((BW_BACKUP_RETENTION + 1)) | while read -r file
  do
    rm -vf "$file"
  done
}

cleanup() {
  rbw_cleanup_account "$ACCOUNT"
  rm -f "$LOCKFILE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  if [[ -e "$LOCKFILE" ]]
  then
    echo_error "$LOCKFILE exists. Another instance is running."
    cat "$LOCKFILE" >&2

    if [[ -z "$IGNORE_LOCK" ]]
    then
      exit 1
    fi

    echo_warning "Ignoring lock file"
  fi

  # Create the lock file
  echo "pid: $$ date: $(date -Iseconds)" > "$LOCKFILE"
  trap cleanup EXIT INT TERM ERR

  healthcheck_ping start "Starting bw-backup"

  if ! bw_export "$@"
  then
    RC=$?
    healthcheck_ping fail "Backup failed (rc: $RC)"
    exit "$RC"
  fi

  if ! backup_rotate
  then
    RC=$?
    healthcheck_ping fail "Backup rotation failed (rc: $RC)"
    exit "$RC"
  fi

  healthcheck_ping "" "Backup successful"
fi
