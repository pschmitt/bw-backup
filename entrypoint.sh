#!/usr/bin/env bash

if [[ -n "$DEBUG" ]]
then
  set -x
fi

echo_info() {
  echo -e "\e[1;34mNFO\e[0m ${*}" >&2
}

echo_warning() {
  echo -e "\e[1;33mWRN\e[0m ${*}" >&2
}

echo_error() {
  echo -e "\e[1;31mERR\e[0m ${*}" >&2
}

bw_set_url() {
  if [[ -z "$BW_URL" ]]
  then
    return 0
  fi

  echo_info "Setting Bitwarden server to $BW_URL"
  bw config server "$BW_URL"
}

bw_login() {
  echo_info "Logging in using API key."
  if ! bw login --raw --nointeraction --apikey >/dev/null
  then
    echo_error "Login failed. Verify values of BW_CLIENTID and BW_CLIENTSECRET"
    return 1
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
    exit 1
  fi

  export BW_SESSION
  bw status

  mkdir -p /data
  if [[ -e "$CLEAR_DATA" ]]
  then
    rm -rf /data/*
  fi

  BW_BACKUP_DIR="/data/$(date -Iseconds)"

  # NOTE this does NOT contains attachment data
  if ! bw export "$BW_PASSWORD" --format json --output "${BW_BACKUP_DIR}/bitwarden-export.json"
  then
    echo_error "Export failed."
    exit 1
  fi

  # NOTE this does contain attachment data
  if ! bw list items --pretty > "${BW_BACKUP_DIR}/bitwarden-list-items.json"
  then
    echo_error "List items failed."
    exit 1
  fi

  if bw_export_attachments
  then
    date '+%s' > "${BW_BACKUP_DIR}/LAST_BACKUP"
  fi
}

bw_export_attachments() {
  local items_with_attachements
  mapfile -t items_with_attachements < <(
    jq -cer '.[] | select(has("attachments"))' "${BW_BACKUP_DIR}/bitwarden-list-items.json"
  )

  local item_data item_id
  local attachements_data att_data att_id att_name att_dest
  for item_data in "${items_with_attachements[@]}"
  do
    item_id="$(jq -er '.id' <<< "$item_data")"
    item_name="$(jq -er '.name' <<< "$item_data")"
    echo_info "Processing attachements for item '$item_name' (id: '$item_id')"

    mkdir -p "${BW_BACKUP_DIR}/${item_id}"

    mapfile -t attachements_data < <(
      jq -cer '.attachments[]' <<< "$item_data"
    )
    for att_data in "${attachements_data[@]}"
    do
      att_id="$(jq -er '.id' <<< "$att_data")"
      att_name="$(jq -er '.fileName' <<< "$att_data")"
      att_dest="${BW_BACKUP_DIR}/${item_id}/${att_name}"
      if [[ -e "$att_dest" ]]
      then
        echo_warning "$att_dest already exists. Refusing to override. Skip."
        continue
      fi

      echo_info "Downloading attachment '$att_name'"
      if ! bw get attachment "$att_id" --itemid "$item_id" --output "$att_dest" || \
         [[ ! -e "$att_dest" ]]
      then
        echo_warning "Download of '$att_name' (id: '$att_id') failed."
      fi
    done
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  bw_export "$@"
fi
