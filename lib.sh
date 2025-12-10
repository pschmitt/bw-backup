# shellcheck shell=bash

echo_info() {
  printf "\e[1;34mNFO\e[0m %s\e[0m\n" "${*}" >&2
}

echo_warning() {
  printf "\e[1;33mWRN\e[0m %s\e[0m\n" "${*}" >&2
}

echo_error() {
  printf "\e[1;31mERR\e[0m %s\e[0m\n" "${*}" >&2
}

download_attachments() {
  local session="$1"
  local items_json="$2"
  local dest_root="$3"
  local jobs="${4:-${DOWNLOAD_PARALLELISM:-10}}"

  mkdir -p "$dest_root"

  local download_list
  download_list=$(mktemp)
  local total_attachments=0

  mapfile -t items_with_attachments < <(
    jq -cer '.items[] | select(.attachments != null and (.attachments | length) > 0)' \
      "$items_json"
  )

  if [[ "${#items_with_attachments[@]}" -eq 0 ]]
  then
    return 0
  fi

  local item_data item_id item_att_dir
  local att_data att_id att_name att_dest
  for item_data in "${items_with_attachments[@]}"
  do
    item_id="$(jq -er '.id' <<< "$item_data")"
    item_att_dir="$dest_root/$item_id"
    mkdir -p "$item_att_dir"

    mapfile -t att_data < <(jq -cer '.attachments[]' <<< "$item_data")
    local att_entry
    for att_entry in "${att_data[@]}"
    do
      att_id="$(jq -er '.id' <<< "$att_entry")"
      att_name="$(jq -er '.fileName' <<< "$att_entry")"
      att_dest="${item_att_dir}/${att_name}"
      if [[ -e "$att_dest" ]]
      then
        echo_warning "Attachment already exists: $att_dest. Skipping."
        continue
      fi

      printf "%s\t%s\t%s\0" "$item_id" "$att_id" "$att_name" >> "$download_list"
      total_attachments=$((total_attachments + 1))
    done
  done

  if [[ "$total_attachments" -eq 0 ]]
  then
    rm -f "$download_list"
    return 0
  fi

  echo_info "Downloading ${total_attachments} attachments (parallel=${jobs})."
  export BW_SESSION="$session"

  export ATT_DEST_ROOT="$dest_root"
  export -f echo_info echo_warning
  # shellcheck disable=SC2016
  xargs -0 -P "$jobs" -I{} bash -c '
    set -euo pipefail
    IFS=$'"'"'\t'"'"' read -r item_id att_id att_name <<< "$1"
    dest="${ATT_DEST_ROOT}/${item_id}/${att_name}"
    echo_info "Downloading attachment: $att_name"
    if [[ -e "$dest" ]]
    then
      echo_warning "Attachment already exists: $dest"
      exit 0
    fi
    if ! bw --session "$BW_SESSION" get attachment "$att_id" --itemid "$item_id" --output "$dest" &>/dev/null
    then
      echo_warning "Download of $att_name failed (item id: $item_id)"
      exit 1
    fi
  ' _ {} < "$download_list"

  rm -f "$download_list"
}

healthcheck_ping() {
  if [[ -z "$HEALTHCHECK_URL" ]]
  then
    return 0
  fi

  local suffix="${1:-}"
  local message="${2:-}"
  local url="${HEALTHCHECK_URL%/}"
  if [[ -n "$suffix" ]]
  then
    url="${url}/${suffix#/}"
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
