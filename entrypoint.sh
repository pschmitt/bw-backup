#!/usr/bin/env bash

# oneshot mode
if [[ -z "$CRON" ]]
then
  /usr/local/bin/bw-backup "$@"
  exit $?
fi

forward_signal() {
  echo "Caught signal, forwarding..."
  kill -s "$1" "$CHILD" 2>/dev/null
}

# Trap termination signals and forward them to the child process
trap 'forward_signal SIGTERM' SIGTERM
trap 'forward_signal SIGINT' SIGINT

# shellcheck source=./bw-backup.sh
source /usr/local/bin/bw-backup

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

echo_info "Starting cron"
cron -f -l 2 &
CHILD=$!

wait "$CHILD"
