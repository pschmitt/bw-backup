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
