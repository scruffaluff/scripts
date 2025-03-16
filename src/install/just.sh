#!/usr/bin/env sh
#
# Install Just for MacOS and Linux systems. This script differs from
# https://just.systems/install.sh by using the Homebrew API to avoid GitHub API
# rate limits.

# Exit immediately if a command exits with non-zero return code.
#
# Flags:
#   -e: Exit immediately when a command pipeline fails.
#   -u: Throw an error when an unset variable is encountered.
set -eu

#######################################
# Show CLI help information.
# Outputs:
#   Writes help information to stdout.
#######################################
usage() {
  cat 1>&2 << EOF
Installer script for Just.

Usage: install-just [OPTIONS]

Options:
      --debug               Show shell debug traces
  -d, --dest <PATH>         Directory to install Just
  -g, --global              Install Just for all users
  -h, --help                Print help information
  -q, --quiet               Print only error messages
  -v, --version <VERSION>   Version of Just to install
EOF
}

#######################################
# Perform network request.
#######################################
fetch() {
  local url='' dst_dir='' dst_file='-' mode='' super=''

  # Parse command line arguments.
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      -d | --dest)
        dst_file="${2}"
        shift 2
        ;;
      -m | --mode)
        mode="${2}"
        shift 2
        ;;
      -s | --super)
        super="${2}"
        shift 2
        ;;
      *)
        url="${1}"
        shift 1
        ;;
    esac
  done

  # Create parent directory if it does not exist.
  #
  # Flags:
  #   -d: Check if path exists and is a directory.
  if [ "${dst_file}" != '-' ]; then
    dst_dir="$(dirname "${dst_file}")"
    if [ ! -d "${dst_dir}" ]; then
      ${super:+"${super}"} mkdir -p "${dst_dir}"
    fi
  fi

  # Download with Curl or Wget.
  #
  # Flags:
  #   -O <PATH>: Save download to path.
  #   -q: Hide log output.
  #   -v: Only show file path of command.
  #   -x: Check if file exists and execute permission is granted.
  if [ -x "$(command -v curl)" ]; then
    ${super:+"${super}"} curl --fail --location --show-error --silent --output \
      "${dst_file}" "${url}"
  elif [ -x "$(command -v wget)" ]; then
    ${super:+"${super}"} wget -q -O "${dst_file}" "${url}"
  else
    log --stderr 'error: Unable to find a network file downloader.'
    log --stderr 'Install curl, https://curl.se, manually before continuing.'
    exit 1
  fi

  # Change file permissions if chmod parameter was passed.
  #
  # Flags:
  #   -n: Check if string has nonzero length.
  if [ -n "${mode:-}" ]; then
    ${super:+"${super}"} chmod "${mode}" "${dst_file}"
  fi
}

#######################################
# Find or download Jq JSON parser.
# Outputs:
#   Path to Jq binary.
#######################################
find_jq() {
  local jq_bin='' tmp_dir=''

  # Do not use long form flags for uname. They are not supported on some
  # systems.
  #
  # Flags:
  #   -s: Show operating system kernel name.
  #   -v: Only show file path of command.
  #   -x: Check if file exists and execute permission is granted.
  jq_bin="$(command -v jq || echo '')"
  if [ -x "${jq_bin}" ]; then
    echo "${jq_bin}"
  else
    response="$(fetch 'https://scruffaluff.github.io/scripts/install/jq.sh')"
    tmp_dir="$(mktemp -d)"
    echo "${response}" | sh -s -- --quiet --dest "${tmp_dir}"
    echo "${tmp_dir}/jq"
  fi
}

#######################################
# Find latest Just version.
#######################################
find_latest() {
  local jq_bin='' response=''
  response="$(fetch 'https://formulae.brew.sh/api/formula/just.json')"
  jq_bin="$(find_jq)"
  printf "%s" "${response}" | "${jq_bin}" --exit-status --raw-output \
    '.versions.stable'
}

#######################################
# Find command to elevate as super user.
# Outputs:
#   Super user command.
#######################################
find_super() {
  # Do not use long form flags for id. They are not supported on some systems.
  #
  # Flags:
  #   -v: Only show file path of command.
  #   -x: Check if file exists and execute permission is granted.
  if [ "$(id -u)" -eq 0 ]; then
    echo ''
  elif [ -x "$(command -v sudo)" ]; then
    echo 'sudo'
  elif [ -x "$(command -v doas)" ]; then
    echo 'doas'
  else
    log --stderr 'error: Unable to find a command for super user elevation'
    exit 1
  fi
}

#######################################
# Download and install Just.
# Arguments:
#   Super user command for installation.
#   Just version.
#   Destination path.
#######################################
install_just() {
  local super="${1}" version="${2}" dst_dir="${3}"
  local arch='' dst_file="${dst_dir}/just" os='' target='' tmp_dir=''

  # Parse Just build target.
  #
  # Do not use long form flags for uname. They are not supported on some
  # systems.
  #
  # Flags:
  #   -m: Show system architecture name.
  #   -s: Show operating system kernel name.
  arch="$(uname -m | sed s/amd64/x86_64/ | sed s/x64/x86_64/ |
    sed s/arm64/aarch64/)"
  os="$(uname -s)"
  case "${os}" in
    Darwin)
      target="${arch}-apple-darwin"
      ;;
    Linux)
      target="${arch}-unknown-linux-musl"
      ;;
    *)
      log --stderr "error: Unsupported operating system '${os}'."
      exit 1
      ;;
  esac

  # Create installation directories.
  #
  # Flags:
  #   -d: Check if path exists and is a directory.
  tmp_dir="$(mktemp -d)"
  if [ ! -d "${dst_dir}" ]; then
    ${super:+"${super}"} mkdir -p "${dst_dir}"
  fi

  log "Installing Just to '${dst_file}'."
  fetch --dest "${tmp_dir}/just.tar.gz" \
    "https://github.com/casey/just/releases/download/${version}/just-${version}-${target}.tar.gz"
  tar fx "${tmp_dir}/just.tar.gz" -C "${tmp_dir}"
  ${super:+"${super}"} mv "${tmp_dir}/just" "${dst_file}"

  export PATH="${dst_dir}:${PATH}"
  log "Installed $(just --version)."
}

#######################################
# Print message if error or logging is enabled.
# Arguments:
#   Message to print.
# Globals:
#   SCRIPTS_NOLOG
# Outputs:
#   Message argument.
#######################################
log() {
  local file='1' newline="\n" text=''

  # Parse command line arguments.
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      -e | --stderr)
        file='2'
        shift 1
        ;;
      -n | --no-newline)
        newline=''
        shift 1
        ;;
      *)
        text="${1}"
        shift 1
        ;;
    esac
  done

  # Print if error or using quiet configuration.
  #
  # Flags:
  #   -z: Check if string has nonzero length.
  if [ -z "${SCRIPTS_NOLOG:-}" ] || [ "${file}" = '2' ]; then
    printf "%s${newline}" "${text}" >&"${file}"
  fi
}

#######################################
# Script entrypoint.
#######################################
main() {
  local dst_dir='' super='' version=''

  # Parse command line arguments.
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --debug)
        set -o xtrace
        shift 1
        ;;
      -d | --dest)
        dst_dir="${2}"
        shift 2
        ;;
      -g | --global)
        dst_dir="${dst_dir:-/usr/local/bin}"
        shift 1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -q | --quiet)
        export SCRIPTS_NOLOG='true'
        shift 1
        ;;
      -v | --version)
        version="${2}"
        shift 2
        ;;
      *)
        log --stderr "error: No such option '${1}'."
        log --stderr "Run 'install-just --help' for usage."
        exit 2
        ;;
    esac
  done

  # Find super user command if destination is not writable.
  #
  # Flags:
  #   -w: Check if file exists and is writable.
  dst_dir="${dst_dir:-"${HOME}/.local/bin"}"
  if ! mkdir -p "${dst_dir}" > /dev/null 2>&1 || [ ! -w "${dst_dir}" ]; then
    super="$(find_super)"
  fi

  if [ -z "${version}" ]; then
    version="$(find_latest)"
  fi
  install_just "${super}" "${version}" "${dst_dir}"
}

# Add ability to selectively skip main function during test suite.
if [ -z "${BATS_SOURCE_ONLY:-}" ]; then
  main "$@"
fi
