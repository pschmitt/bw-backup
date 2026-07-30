#!/usr/bin/env bash

if [[ -n "$DEBUG" ]]
then
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

SRC_ACCOUNT="${SRC_ACCOUNT:-source}"
DEST_ACCOUNT="${DEST_ACCOUNT:-destination}"

# "personal": mirror the source account's entire vault 1:1 into the
# destination account's personal vault.
# "collections": mirror the source account's entire vault into one or more
# existing (or auto-created) collections in a destination organization, each
# collection getting its own full, independent mirror.
BW_SYNC_MODE="${BW_SYNC_MODE:-personal}"
BW_SYNC_ATTACHMENTS="${BW_SYNC_ATTACHMENTS:-1}"
BW_SYNC_OVERWRITE="${BW_SYNC_OVERWRITE:-1}"

TMPDIR="${TMPDIR:-/tmp}"
WORKDIR="${WORKDIR:-${TMPDIR}/bw-sync}"

is_temp_workdir() {
  case "$WORKDIR" in
    /tmp/*)
      return 0
      ;;
    "${TMPDIR:-/tmp}"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

write_last_sync() {
  date '+%s' > "${WORKDIR}/LAST_SYNC"
}

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
}

# Trims only leading/trailing whitespace, preserving internal spaces (e.g.
# a collection named "Some Other Collection" must round-trip unchanged).
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

cleanup() {
  rbw_cleanup_account "$SRC_ACCOUNT"
  rbw_cleanup_account "$DEST_ACCOUNT"

  if is_temp_workdir
  then
    rm -rf "$WORKDIR"
  fi
}

mirror_flags() {
  local -n _out="$1"
  _out=()
  if [[ "$BW_SYNC_ATTACHMENTS" == "1" ]]
  then
    _out+=(--attachments)
  fi
  if [[ "$BW_SYNC_OVERWRITE" == "1" ]]
  then
    _out+=(--overwrite)
  fi
}

# 1:1 mirror: source vault -> destination account's personal vault.
# DEST_BW_PURGE_VAULT (if set) wipes the destination's whole personal vault
# first, via rbw mirror's own --purge-dest (server-side purge, same endpoint
# `rbw purge-vault` uses) -- entries assigned to an org collection are
# untouched either way.
mirror_personal() {
  local -a flags
  mirror_flags flags

  if [[ -n "${DEST_BW_PURGE_VAULT:-}" ]]
  then
    echo_info "Purging destination vault before mirroring (DEST_BW_PURGE_VAULT is set)."
    printf '%s\n' "$DEST_BW_PASSWORD" |
      rbw mirror --from "$SRC_ACCOUNT" --to "$DEST_ACCOUNT" --yes \
        --purge-dest --stdin "${flags[@]}"
  else
    rbw mirror --from "$SRC_ACCOUNT" --to "$DEST_ACCOUNT" --yes "${flags[@]}"
  fi
}

# Mirror into one or more org collections. Each configured name is handled
# one of two ways, decided by whether the SOURCE account has a collection
# with that exact name:
#   - match found: scoped 1:1 mirror of just that source collection into the
#     same-named destination collection (--collection --dest-collection
#     --overwrite). rbw mirror refuses --purge-dest together with a
#     source-side --collection scope, so stale destination entries are left
#     in place rather than purged.
#   - no match: full mirror of the entire source vault into that destination
#     collection (--dest-collection --purge-dest), same as before -- this is
#     how a collection can hold a full copy of the vault (e.g. a personal
#     vault mirrored into a dedicated collection) rather than a 1:1 copy of
#     an equally-named source collection.
# The org and each destination collection are created if they don't already
# exist. The source account/vault is only ever read, never modified.
mirror_collections() {
  if [[ -z "${DEST_BW_ORG:-}" ]]
  then
    echo_error "DEST_BW_ORG is required when BW_SYNC_MODE=collections"
    return 1
  fi
  if [[ -z "${DEST_BW_COLLECTIONS:-}" ]]
  then
    echo_error "DEST_BW_COLLECTIONS (comma-separated) is required when BW_SYNC_MODE=collections"
    return 1
  fi

  local org_id
  org_id=$(rbw_ensure_org "$DEST_ACCOUNT" "$DEST_BW_ORG") || return 1

  local -a flags
  mirror_flags flags

  local -a collections
  IFS=',' read -ra collections <<< "$DEST_BW_COLLECTIONS"

  local raw_name name src_id rc=0
  for raw_name in "${collections[@]}"
  do
    name="$(trim "$raw_name")"
    [[ -z "$name" ]] && continue

    rbw_ensure_collection "$DEST_ACCOUNT" "$org_id" "$name" >/dev/null || {
      rc=1
      continue
    }

    src_id=$(rbw_find_collection_id "$SRC_ACCOUNT" "$name")

    if [[ -n "$src_id" ]]
    then
      echo_info "Mirroring source collection '$name' -> destination collection '$name'"
      if ! rbw mirror --from "$SRC_ACCOUNT" --to "$DEST_ACCOUNT" --yes \
        --collection "$src_id" --dest-collection "$name" "${flags[@]}"
      then
        echo_error "Mirror of collection '$name' failed."
        rc=1
      fi
    else
      echo_info "Mirroring entire vault -> destination collection: $name"
      if ! rbw mirror --from "$SRC_ACCOUNT" --to "$DEST_ACCOUNT" --yes \
        --dest-collection "$name" --purge-dest "${flags[@]}"
      then
        echo_error "Mirror into collection '$name' failed."
        rc=1
      fi
    fi
  done

  return "$rc"
}

main() {
  require_vars SRC_ACCOUNT DEST_ACCOUNT SRC_BW_PASSWORD DEST_BW_PASSWORD

  healthcheck_ping start "Starting bw-sync (mode: $BW_SYNC_MODE)"

  mkdir -p "$WORKDIR"
  trap cleanup EXIT INT TERM

  if ! rbw_prepare_account "$SRC_ACCOUNT" "$SRC_BW_PASSWORD" "${SRC_BW_TOTP_SECRET:-}"
  then
    healthcheck_ping fail "bw-sync source login failed"
    return 1
  fi

  if ! rbw_prepare_account "$DEST_ACCOUNT" "$DEST_BW_PASSWORD" "${DEST_BW_TOTP_SECRET:-}"
  then
    healthcheck_ping fail "bw-sync destination login failed"
    return 1
  fi

  local rc=0
  case "$BW_SYNC_MODE" in
    personal)
      mirror_personal || rc=1
      ;;
    collections)
      mirror_collections || rc=1
      ;;
    *)
      echo_error "Unknown BW_SYNC_MODE: $BW_SYNC_MODE (expected 'personal' or 'collections')"
      rc=1
      ;;
  esac

  if [[ "$rc" -ne 0 ]]
  then
    healthcheck_ping fail "bw-sync failed"
    return 1
  fi

  echo_info "Sync complete."
  write_last_sync
  healthcheck_ping "" "bw-sync successful"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi
