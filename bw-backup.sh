#!/usr/bin/env bash

if [[ -n "$DEBUG" ]]
then
  set -x
fi

BW_CONFIG_HOME="${BW_CONFIG_HOME:-$HOME/.config/Bitwarden CLI}"
LOCKFILE="${TMPDIR:-/tmp}/bw-backup.lock"
HEALTHCHECK_URL="${HEALTHCHECK_URL%/}"

echo_info() {
  echo -e "\e[1;34mNFO\e[0m ${*}" >&2
}

echo_warning() {
  echo -e "\e[1;33mWRN\e[0m ${*}" >&2
}

echo_error() {
  echo -e "\e[1;31mERR\e[0m ${*}" >&2
}

healthcheck_ping() {
  if [[ -z "$HEALTHCHECK_URL" ]]
  then
    return 0
  fi

  local suffix="${1:-}"
  local message="${2:-}"
  local url="$HEALTHCHECK_URL"
  if [[ -n "$suffix" ]]
  then
    url="${HEALTHCHECK_URL}/${suffix#/}"
  fi

  local curl_args=(-fsS -m 10 --retry 5)
  if [[ -n "$message" ]]
  then
    curl_args+=(-X POST -H "Content-Type: text/plain" --data "$message")
  fi

  if ! curl "${curl_args[@]}" "$url" >/dev/null
  then
    echo_warning "Healthcheck ping failed: $url"
    return 1
  fi
}

bw_set_url() {
  if [[ -z "$BW_URL" ]]
  then
    return 0
  fi

  local bw_current_server
  # Check if there is a config file
  if [[ -e ${BW_CONFIG_HOME}/data.json ]]
  then
    bw_current_server=$(bw config server)
  fi

  if [[ "$bw_current_server" == "$BW_URL" ]]
  then
    return 0
  fi

  echo_info "Setting Bitwarden server to $BW_URL"
  bw config server "$BW_URL"
}

bw_login() {
  echo_info "Logging in using API key."
  local bw_status
  bw_status=$(bw status | jq -er .status)

  if [[ -z "$BW_SESSION" && "$bw_status" == "unauthenticated" ]]
  then
    if ! bw login --raw --nointeraction --apikey >/dev/null
    then
      echo_error "Login failed. Verify values of BW_CLIENTID and BW_CLIENTSECRET"
      return 1
    fi
  fi

  if ! bw unlock --raw "$BW_PASSWORD"
  then
    echo_error "Unlock failed. Verify value of BW_PASSWORD"
    return 1
  fi
}

bw_export() {
  bw_set_url
  if ! BW_SESSION=$(bw_login)
  then
    healthcheck_ping fail "Login failed (bw-backup)"
    exit 1
  fi

  export BW_SESSION
  echo_info "bw status"
  bw status

  echo_info "Force syncing vault"
  bw sync --force

  mkdir -p /data
  if [[ -e "$CLEAR_DATA" ]]
  then
    rm -rf /data/*
  fi

  BW_BACKUP_DIR="/data/bw-export-$(date -Iseconds)"

  # NOTE this does NOT contains attachment data
  echo_info "Exporting items (bw export)"
  if ! bw export --format json --output "${BW_BACKUP_DIR}/bitwarden-export.json"
  then
    echo_error "Export failed."
    healthcheck_ping fail "Export failed (bw-backup)"
    exit 1
  fi

  # NOTE this does contain attachment data
  echo_info "Exporting all item (bw list items)"
  if ! bw list items --pretty > "${BW_BACKUP_DIR}/bitwarden-list-items.json"
  then
    echo_error "List items failed."
    healthcheck_ping fail "List items failed (bw-backup)"
    exit 1
  fi

  if ! bw_export_attachments
  then
    echo_error "Export of attachments failed."
  fi

  local archive="$BW_BACKUP_DIR.tar.gz"
  echo_info "Creating archive: $BW_BACKUP_DIR/* -> $archive"
  (cd "$BW_BACKUP_DIR" || exit 3; tar cvzf "$archive" --transform 's|^./||' -- *)

  local latest="$archive"
  if [[ -z "$ENCRYPTION_PASSPHRASE" ]]
  then
    echo_info "No encryption passphrase provided. Skipping encryption."
  else
    local gpg_archive="${archive}.gpg"
    echo_info "Encrypting backup: $archive -> $gpg_archive"
    if gpg --batch --yes --passphrase "$ENCRYPTION_PASSPHRASE" --symmetric \
      --cipher-algo AES256 --output "${archive}.gpg" "$archive"
    then
      latest="$gpg_archive"
      rm -vf "$archive"
    else
      echo_error "Encryption FAILED."
    fi
  fi

  ln -sfv "$(basename "$latest")" "/data/bw-export-latest"
  date '+%s' > "/data/LAST_BACKUP"
}

bw_export_attachments() {
  local items_with_attachements
  mapfile -t items_with_attachements < <(
    jq -cer '.[] | select(has("attachments"))' \
      "${BW_BACKUP_DIR}/bitwarden-list-items.json"
  )

  local item_data item_id item_att_dir
  local attachements_data att_data att_id att_name att_dest
  for item_data in "${items_with_attachements[@]}"
  do
    item_id="$(jq -er '.id' <<< "$item_data")"
    item_name="$(jq -er '.name' <<< "$item_data")"
    echo_info "Processing attachements for item '$item_name' (id: $item_id)"

    item_att_dir="${BW_BACKUP_DIR}/attachments/${item_id}"
    mkdir -p "$item_att_dir"

    mapfile -t attachements_data < <(
      jq -cer '.attachments[]' <<< "$item_data"
    )
    for att_data in "${attachements_data[@]}"
    do
      att_id="$(jq -er '.id' <<< "$att_data")"
      att_name="$(jq -er '.fileName' <<< "$att_data")"
      att_dest="${item_att_dir}/${att_name}"
      if [[ -e "$att_dest" ]]
      then
        echo_warning "$att_dest already exists. Refusing to override. Skip."
        continue
      fi

      echo_info "Downloading attachment '$att_name'"
      if ! bw get attachment "$att_id" --itemid "$item_id" --output "$att_dest" || \
         [[ ! -e "$att_dest" ]]
      then
        echo_warning "Download of '$att_name' (id: $att_id) failed."
      fi
    done
  done
}

backup_rotate() {
  if [[ -z "$KEEP" ]]
  then
    echo_info "KEEP is not set. Skip rotation."
    return 0
  fi

  echo_info "Pruning old backups (keep: $KEEP)"

  # remove files
  local file
  find /data -type f -name 'bw-export-*' | sort -nr | \
    tail -n +$((KEEP + 1)) | while read -r file
  do
    rm -vf "$file"
  done
}

cleanup() {
  bw logout
  rm -rf "$BW_BACKUP_DIR" "$LOCKFILE" "$BW_CONFIG_HOME"
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

  healthcheck_ping start "Starting backup (bw-backup)"

  if ! bw_export "$@"
  then
    RC=$?
    healthcheck_ping fail "Backup failed (bw-backup, rc: $RC)"
    exit "$RC"
  fi

  if ! backup_rotate
  then
    RC=$?
    healthcheck_ping fail "Backup rotation failed (bw-backup, rc: $RC)"
    exit "$RC"
  fi

  healthcheck_ping "" "Backup successful (bw-backup)"
fi
