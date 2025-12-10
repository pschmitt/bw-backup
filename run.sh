#!/usr/bin/env bash

usage() {
  echo "Usage: $(basename "$0") ACTION"
  echo
  echo "Actions:"
  echo "  backup    Run the backup service (default)"
  echo "  sync      Run the sync service"
}

main() {
  local compose_service="bw-backup" debug

  while [[ -n "$*" ]]
  do
    case "$1" in
      help|h|-h|--help)
        usage
        exit 0
        ;;
      -d|--debug)
        debug=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  case "$1" in
    backup|bak|--back*|--bak*)
      compose_service="bw-backup"
      shift
      ;;
    sync|s|--sync)
      compose_service="bw-backup-sync"
      shift
      ;;
    *)
      echo "Unrecognized option: $1"
      return 2
      ;;
  esac

  local -a extra_args=()
  if [[ -n $debug ]]
  then
    extra_args+=(--env DEBUG=1)
  fi

  docker compose up --build "${extra_args[@]}" "$compose_service" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  cd "$(cd "$(dirname "$0")" >/dev/null 2>&1; pwd -P)" || exit 9

  main "$@"
fi
