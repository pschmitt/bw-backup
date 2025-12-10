#!/usr/bin/env bash

if [[ -n "$DEBUG" ]]
then
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

export BW_NOINTERACTIVE=1

DEFAULT_BW_URL="${BW_URL:-https://bitwarden.com}"
SRC_BW_URL="${SRC_BW_URL:-$DEFAULT_BW_URL}"
DEST_BW_URL="${DEST_BW_URL:-${BW_URL:-$DEFAULT_BW_URL}}"

SRC_BW_CLIENTID="${SRC_BW_CLIENTID:-$BW_CLIENTID}"
SRC_BW_CLIENTSECRET="${SRC_BW_CLIENTSECRET:-$BW_CLIENTSECRET}"
SRC_BW_PASSWORD="${SRC_BW_PASSWORD:-$BW_PASSWORD}"

WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/bw-sync}"
SRC_BW_CONFIG_HOME="${SRC_BW_CONFIG_HOME:-${WORKDIR}/src-config}"
DEST_BW_CONFIG_HOME="${DEST_BW_CONFIG_HOME:-${WORKDIR}/dest-config}"
SOURCE_EXPORT_FILE="${WORKDIR}/source-export.json"
SOURCE_ITEMS_LIST="${WORKDIR}/source-items.json"
SOURCE_ITEMS_WRAPPED="${WORKDIR}/source-items-wrapped.json"
ATTACHMENTS_DIR="${WORKDIR}/attachments"
SOURCE_ATTACHMENTS_DIR="${ATTACHMENTS_DIR}/source"
DEST_ITEMS_AFTER_IMPORT="${WORKDIR}/dest-items-after-import.json"
ID_MAPPING_FILE="${WORKDIR}/id-mapping.tsv"
SOURCE_ATTACH_COUNT=0
DEST_ATTACH_COUNT=0

HELPER_PY="${SCRIPT_DIR}/bw.py"

SOURCE_SESSION=""
DEST_SESSION=""

require_vars() {
  local missing=0
  for var in "$@"
  do
    if [[ -z "${!var:-}" ]]
    then
      echo_error "Missing env var: $var"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]
  then
    exit 1
  fi

  echo_info "Syncing from ${SRC_BW_URL} to ${DEST_BW_URL}"
}

bw_use_env() {
  local config_home="$1"
  local session="$2"

  mkdir -p "$config_home"
  export BITWARDENCLI_APPDATA_DIR="$config_home"
  export BW_CONFIG_HOME="$config_home"
  export BW_CONFIG_DIR="$config_home"
  export XDG_CONFIG_HOME="$config_home"
  export HOME="$config_home"
  export BW_SESSION="$session"
  export BW_NOINTERACTIVE=1
}

bw_set_server() {
  local url="$1"

  if [[ -z "$url" ]]
  then
    return 0
  fi

  echo_info "Setting Bitwarden server to $url"
  bw config server "$url" &>/dev/null
}

bw_login() {
  local label="$1"
  local url="$2"
  local client_id="$3"
  local client_secret="$4"
  local password="$5"
  local config_home="$6"

  bw_use_env "$config_home" ""

  export BW_CLIENTID="$client_id"
  export BW_CLIENTSECRET="$client_secret"

  bw logout &>/dev/null || true
  bw_set_server "$url"

  echo_info "[$label] Logging in using API key."
  if ! bw login --apikey --raw --nointeraction >/dev/null
  then
    echo_error "[$label] Login failed. Verify values of *_BW_CLIENTID and *_BW_CLIENTSECRET."
    return 1
  fi

  local session
  session=$(bw unlock --raw "$password" | awk 'NF {last=$0} END {print last}' | tr -d '\r')
  if [[ -z "$session" ]]
  then
    echo_error "[$label] Unlock failed. Verify value of *_BW_PASSWORD."
    return 1
  fi

  bw_use_env "$config_home" "$session"
  echo_info "[$label] Syncing vault."
  { bw --session "$session" sync --force; echo; }>&2

  if [[ "$label" == "source" ]]
  then
    SOURCE_SESSION="$session"
  elif [[ "$label" == "destination" ]]
  then
    DEST_SESSION="$session"
  fi
}

bw_logout_env() {
  local config_home="$1"
  bw_use_env "$config_home" ""
  { bw logout; echo; } >&2 || true
}

prepare_workdir() {
  mkdir -p "$WORKDIR" "$ATTACHMENTS_DIR" "$SOURCE_ATTACHMENTS_DIR"
}

cleanup() {
  bw_logout_env "$SRC_BW_CONFIG_HOME"
  bw_logout_env "$DEST_BW_CONFIG_HOME"
  rm -rf "$WORKDIR"
}

export_attachments() {
  local session="$1"
  local items_json="$2"
  local dest_folder="$3"

  download_attachments "$session" "$items_json" "$dest_folder"
}

restore_attachments() {
  local session="$1"
  local attachments_folder="$2"
  local mapping_file="$3"

  if [[ ! -d "$attachments_folder" ]]
  then
    return 0
  fi

  mapfile -t upload_pairs < <(
    find "$attachments_folder" -mindepth 2 -type f -printf '%h/%f\n'
  )

  if [[ "${#upload_pairs[@]}" -eq 0 ]]
  then
    return 0
  fi

  declare -A id_map=()
  if [[ -s "$mapping_file" ]]
  then
    while IFS=$'\t' read -r src_id dst_id
    do
      id_map["$src_id"]="$dst_id"
    done < "$mapping_file"
  fi

  local attachment_path src_id dst_id
  for attachment_path in "${upload_pairs[@]}"
  do
    src_id="$(basename "$(dirname "$attachment_path")")"
    dst_id="${id_map[$src_id]:-$src_id}"
    echo_info "Uploading attachment $(basename "$attachment_path") to item $dst_id"
    if ! bw --session "$session" create attachment --file "$attachment_path" --itemid "$dst_id"
    then
      echo_warning "Failed to upload attachment $(basename "$attachment_path") to item $dst_id"
    fi
  done
}

export_source_data() {
  bw_use_env "$SRC_BW_CONFIG_HOME" "$SOURCE_SESSION"

  echo_info "Exporting source items."
  if ! bw --session "$SOURCE_SESSION" export --raw --format json > "$SOURCE_EXPORT_FILE"
  then
    echo_error "Export failed for source."
    exit 1
  fi

  echo_info "Exporting source item list (for attachments)."
  if ! bw --session "$SOURCE_SESSION" list items > "$SOURCE_ITEMS_LIST"
  then
    echo_error "Listing items failed for source."
    exit 1
  fi

  jq '{items: .}' "$SOURCE_ITEMS_LIST" > "$SOURCE_ITEMS_WRAPPED"
  export_attachments "$SOURCE_SESSION" "$SOURCE_ITEMS_WRAPPED" "$SOURCE_ATTACHMENTS_DIR"

  if [[ -d "$SOURCE_ATTACHMENTS_DIR" ]]
  then
    SOURCE_ATTACH_COUNT=$(find "$SOURCE_ATTACHMENTS_DIR" -type f | wc -l | tr -d ' ')
    echo_info "Downloaded ${SOURCE_ATTACH_COUNT} attachments from source."
  fi
}

purge_destination_vault() {
  echo_info "[destination] Purging vault."
  if ! python3 "$HELPER_PY" purge \
    --server "$DEST_BW_URL" \
    --api-client-id "$DEST_BW_CLIENTID" \
    --api-client-secret "$DEST_BW_CLIENTSECRET" \
    --email "$DEST_BW_EMAIL" \
    --master-password "$DEST_BW_PASSWORD" \
    >/tmp/bw-sync-purge.log 2>&1
  then
    echo_error "Failed to purge destination vault."
    cat /tmp/bw-sync-purge.log >&2 || true
    return 1
  fi
  rm -f /tmp/bw-sync-purge.log
}

import_to_destination() {
  bw_use_env "$DEST_BW_CONFIG_HOME" "$DEST_SESSION"

  echo_info "[destination] Importing items from source export."
  local import_log="${WORKDIR}/dest-import.log"
  if ! bw --session "$DEST_SESSION" --raw import bitwardenjson "$SOURCE_EXPORT_FILE" >"$import_log" 2>&1
  then
    echo_error "Import into destination failed."
    cat "$import_log" >&2
    return 1
  fi
  echo_info "[destination] Import completed. Log: $import_log"

  if [[ ! -d "$SOURCE_ATTACHMENTS_DIR" ]]
  then
    return 0
  fi

  echo_info "[destination] Exporting items for attachment mapping."
  if ! bw --session "$DEST_SESSION" list items > "$DEST_ITEMS_AFTER_IMPORT"
  then
    echo_error "Failed to list destination items after import."
    return 1
  fi

  echo_info "[destination] Building attachment mapping."
  if ! python3 "$HELPER_PY" match "$SOURCE_EXPORT_FILE" "$DEST_ITEMS_AFTER_IMPORT" > "$ID_MAPPING_FILE"
  then
    echo_error "Failed to generate attachment mapping."
    return 1
  fi

  restore_attachments "$DEST_SESSION" "$SOURCE_ATTACHMENTS_DIR" "$ID_MAPPING_FILE"

  if [[ -d "$SOURCE_ATTACHMENTS_DIR" ]]
  then
    DEST_ATTACH_COUNT=$(find "$SOURCE_ATTACHMENTS_DIR" -type f | wc -l | tr -d ' ')
    echo_info "Uploaded ${DEST_ATTACH_COUNT} attachments to destination."
  fi
}

main() {
  require_vars \
    SRC_BW_CLIENTID \
    SRC_BW_CLIENTSECRET \
    SRC_BW_PASSWORD \
    DEST_BW_CLIENTID \
    DEST_BW_CLIENTSECRET \
    DEST_BW_PASSWORD \
    DEST_BW_EMAIL

  healthcheck_ping start "Starting bw-sync"

  prepare_workdir
  trap cleanup EXIT INT TERM

  if ! bw_login "source" "$SRC_BW_URL" "$SRC_BW_CLIENTID" "$SRC_BW_CLIENTSECRET" "$SRC_BW_PASSWORD" "$SRC_BW_CONFIG_HOME"
  then
    healthcheck_ping fail "bw-sync source login failed"
    return 1
  fi

  export_source_data
  bw_logout_env "$SRC_BW_CONFIG_HOME"

  if ! bw_login "destination" "$DEST_BW_URL" "$DEST_BW_CLIENTID" "$DEST_BW_CLIENTSECRET" "$DEST_BW_PASSWORD" "$DEST_BW_CONFIG_HOME"
  then
    healthcheck_ping fail "bw-sync destination login failed"
    return 1
  fi

  if [[ -n "${DEST_BW_PURGE_VAULT:-}" ]]
  then
    purge_destination_vault
  fi
  import_to_destination
  bw_logout_env "$DEST_BW_CONFIG_HOME"

  echo_info "Sync complete."
  if [[ "${SOURCE_ATTACH_COUNT:-0}" -gt 0 || "${DEST_ATTACH_COUNT:-0}" -gt 0 ]]
  then
    if [[ "${SOURCE_ATTACH_COUNT:-0}" -eq "${DEST_ATTACH_COUNT:-0}" ]]
    then
      echo_info "Attachments: source=${SOURCE_ATTACH_COUNT:-0}, uploaded=${DEST_ATTACH_COUNT:-0}"
    else
      echo_warning "Attachments mismatch: source=${SOURCE_ATTACH_COUNT:-0}, uploaded=${DEST_ATTACH_COUNT:-0}"
    fi
  fi
  healthcheck_ping "" "bw-sync successful"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi
