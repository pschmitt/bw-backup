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

# Logs a configured rbw account in and unlocks it, both non-interactively via
# --stdin, then refreshes its local db cache. Requires the account to already
# be present in rbw's config.json (email/base_url etc) -- only the master
# password is supplied here.
rbw_prepare_account() {
  local account="$1"
  local password="$2"

  echo_info "[$account] Logging in."
  if ! printf '%s\n' "$password" | rbw --account "$account" login --stdin
  then
    echo_error "[$account] Login failed. Verify the account's email/base_url in config.json (and, for bitwarden.com, that 'rbw register' has been run)."
    return 1
  fi

  echo_info "[$account] Unlocking."
  if ! printf '%s\n' "$password" | rbw --account "$account" unlock --stdin
  then
    echo_error "[$account] Unlock failed. Verify the master password."
    return 1
  fi

  echo_info "[$account] Syncing vault."
  rbw --account "$account" sync
}

# Best-effort teardown: lock the account and drop its local db cache. Safe to
# call even if the account was never successfully unlocked.
rbw_cleanup_account() {
  local account="$1"
  rbw --account "$account" lock &>/dev/null || true
  rbw --account "$account" purge &>/dev/null || true
}

# Idempotent: looks up an organization by name, creating it if missing.
# Prints its id on stdout.
rbw_ensure_org() {
  local account="$1"
  local org_name="$2"
  local id

  id=$(rbw --account "$account" org list --raw 2>/dev/null |
    jq -r --arg n "$org_name" '(map(select(.name == $n)) | .[0].id) // empty')

  if [[ -z "$id" ]]
  then
    echo_info "[$account] Creating organization: $org_name"
    rbw --account "$account" org create "$org_name" >/dev/null || return 1
    id=$(rbw --account "$account" org list --raw |
      jq -r --arg n "$org_name" '(map(select(.name == $n)) | .[0].id) // empty')
  fi

  if [[ -z "$id" ]]
  then
    echo_error "[$account] Failed to find or create organization: $org_name"
    return 1
  fi

  printf '%s\n' "$id"
}

# Idempotent: looks up a collection by name within an org, creating it if
# missing. Prints its id on stdout.
rbw_ensure_collection() {
  local account="$1"
  local org_id="$2"
  local collection_name="$3"
  local id

  id=$(rbw --account "$account" collection list --raw 2>/dev/null |
    jq -r --arg n "$collection_name" '(map(select(.name == $n)) | .[0].id) // empty')

  if [[ -z "$id" ]]
  then
    echo_info "[$account] Creating collection: $collection_name"
    rbw --account "$account" collection create "$collection_name" --org-id "$org_id" >/dev/null || return 1
    id=$(rbw --account "$account" collection list --raw |
      jq -r --arg n "$collection_name" '(map(select(.name == $n)) | .[0].id) // empty')
  fi

  if [[ -z "$id" ]]
  then
    echo_error "[$account] Failed to find or create collection: $collection_name"
    return 1
  fi

  printf '%s\n' "$id"
}
