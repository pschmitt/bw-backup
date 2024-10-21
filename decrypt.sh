#!/usr/bin/env bash

usage() {
  echo "Usage: $0 FILE PASSPHRASE [OUTPUT]"
}

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

FILE="$1"
PASSPHRASE="$2"
OUTPUT="${3:-decrypted.tar.gz}"

if [[ -z "$FILE" || -z "$PASSPHRASE" ]]
then
  usage >&2
  exit 2
fi

FILE=$(realpath "$FILE")
OUTPUT=$(realpath "$OUTPUT")

echo -e "Decrypting \e[1;35m${FILE}\e[0m to \e[1;36m${OUTPUT}\e[0m" >&2

gpg --batch --yes --passphrase "$PASSPHRASE" \
  --decrypt --output "$OUTPUT" "$FILE"
