# shellcheck shell=bash

echo_info() {
  echo -e "\e[1;34mNFO\e[0m ${*}" >&2
}

echo_warning() {
  echo -e "\e[1;33mWRN\e[0m ${*}" >&2
}

echo_error() {
  echo -e "\e[1;31mERR\e[0m ${*}" >&2
}
