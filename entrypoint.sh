#!/usr/bin/env bash

cd "$(cd "$(dirname "$0")" >/dev/null 2>&1; pwd -P)" || exit 9
# shellcheck source=./lib.sh
source lib.sh

COMMAND="${1:-backup}"
if [[ "$COMMAND" == "sync" ]]
then
  shift
  exec /usr/local/bin/bw-sync "$@"
elif [[ "$COMMAND" == "backup" ]]
then
  shift
else
  echo_error "Unknown command: $COMMAND"
  exit 2
fi

# oneshot mode
if [[ -z "$CRON" ]]
then
  exec /usr/local/bin/bw-backup "$@"
fi

forward_signal() {
  echo "Caught signal, forwarding..." >&2
  kill -s "$1" "$CHILD" >&2
}

# Trap termination signals and forward them to the child process
trap 'forward_signal SIGTERM' SIGTERM
trap 'forward_signal SIGINT' SIGINT
# https://blog.thesparktree.com/cron-in-docker
echo_info "Running in cron mode: CRON='$CRON'"

USER=${USER:-$(whoami)}
# Save all environment variables to /etc/environment
export > /etc/environment

cat <<EOF > /etc/crontab
SHELL=/bin/bash
BASH_ENV=/etc/environment

$CRON $USER /usr/local/bin/bw-backup >/proc/1/fd/1 2>/proc/1/fd/2
EOF

if [[ -n "$START_RIGHT_NOW" ]]
then
  echo_info "Running backup right away! cron will take over after"
  /usr/local/bin/bw-backup "$@"
fi

echo_info "Starting cron"
cron -f -l 2 &
CHILD=$!
trap 'kill "$CHILD" 2>/dev/null' EXIT

wait "$CHILD"
