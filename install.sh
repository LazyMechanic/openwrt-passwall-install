#!/bin/sh

# Exit on error and undefined variables
set -eu

VERBOSE=0
TMP_DIR=""
FEED_FILE="/etc/opkg/customfeeds.conf"

# Safety Buffer in Bytes (approx 200KB).
# We add this because 'Size' in opkg is the compressed .ipk size,
# but installation takes more space, plus dependencies.
BUFFER=204800

#===============================================================================
# Color Setup (TTY-aware)
#===============================================================================
if [ -t 1 ]; then
  COLOR_RED="$(printf '\033[0;31m')"
  COLOR_YELLOW="$(printf '\033[0;33m')"
  COLOR_GREEN="$(printf '\033[0;32m')"
  COLOR_BLUE="$(printf '\033[0;34m')"
  COLOR_RESET="$(printf '\033[0m')"
else
  COLOR_RED=''
  COLOR_YELLOW=''
  COLOR_GREEN=''
  COLOR_BLUE=''
  COLOR_RESET=''
fi

#===============================================================================
# Logging Functions
#===============================================================================
log_info() {
  printf '%s[INFO]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

log_warn() {
  printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

log_error() {
  printf '%s[ERRO]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

log_debug() {
  [ "$VERBOSE" -eq 1 ] || return 0
  printf '%s[DEBG]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

#===============================================================================
# Cleanup & Signal Handling
#===============================================================================
cleanup_tmp_dir() {
  if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
    log_debug "Removing temp directory '${TMP_DIR}'"
    rm -rf "${TMP_DIR}"
  fi
}

cleanup_feeds() {
  if [ -f "${FEED_FILE}.bak" ]; then
    log_info "Restoring original feed file from backup '${FEED_FILE}.bak' -> '${FEED_FILE}'"
    mv -f "${FEED_FILE}.bak" "${FEED_FILE}"
  fi
}

cleanup() {
  rc=$?

  log_debug "Running cleanup (exit code: ${rc})"

  cleanup_tmp_dir

  if [ "${rc}" -ne 0 ]; then
    log_error "Script exited with error (code ${rc})"
    cleanup_feeds
  fi

  exit "${rc}"
}

# Run cleanup on exit and common termination signals
trap cleanup EXIT INT TERM

#===============================================================================
# Helper Functions
#===============================================================================
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -v, --verbose   Enable verbose output
  -h, --help      Show this help message
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
    -v | --verbose)
      VERBOSE=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
    esac
    shift
  done
}

# Function: yes_no
# Description: Prompts user with a yes/no question and returns 0 for yes, 1 for no
# Parameters:
#   $1 - question
#   $2 - optional default: Y/N (empty = no default)
# Usage:
#   if yes_no "Do you want to continue?" Y; then
#     echo "User answered yes"
#   else
#     echo "User answered no"
#   fi
yes_no() {
  question="$1"
  default="${2:-}" # Optional default: Y/N (empty = no default)

  while true; do
    if [ -n "${default}" ]; then
      printf "%s [%s/%s]: " "${question}" "${default%?}" "${default#?}"
    else
      printf "%s [y/n]: " "${question}"
    fi
    read answer || return 1 # Ctrl+D or read failure counts as no

    # If empty and default provided
    if [ -z "${answer}" ] && [ -n "${default}" ]; then
      answer="${default}"
    fi

    case "${answer}" in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    [Nn] | [Nn][Oo]) return 1 ;;
    *) printf "Please answer yes or no.\n" ;;
    esac
  done
}

# Function: prettify_list
# Description: returns a formatted string from a space-separated list
# Parameters:
#   $1 - space-separated list
#   $2 - optional mode: "numbered", "inline", default = plain list with '-'
# Usage:
#   result=$(prettify_list "$packages" inline)
prettify_list() {
  list="$1"
  mode="${2:-}"

  result=""

  case "$mode" in
  numbered)
    i=1
    for item in $list; do
      result="${result}${i}. ${item}\n"
      i=$((i + 1))
    done
    ;;
  inline)
    result="["
    sep=""
    for item in $list; do
      result="${result}${sep}${item}"
      sep=", "
    done
    result="${result}]"
    ;;
  *)
    for item in $list; do
      result="${result}- ${item}\n"
    done
    ;;
  esac

  # Return string via stdout
  printf "%b" "$result"
}

#===============================================================================
# Main Logic
#===============================================================================

check_dependencies() {
  for cmd in wget opkg grep awk; do
    log_debug "Checking dependency: '${cmd}'"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log_error "Missing dependency: '${cmd}'"
      exit 1
    fi
  done
}

check_snapshot() {
  /sbin/reload_config

  snapshot=$(grep -o SNAPSHOT /etc/openwrt_release | sed -n '1p')

  if [ "${snapshot}" == "SNAPSHOT" ]; then
    log_error "SNAPSHOT version not supported"
    exit 1
  fi
}

create_temp_workspace() {
  TMP_DIR="$(mktemp -d /tmp/passwall.XXXXXX)"
  cd "${TMP_DIR}"
}

install_passwall_feeds() {
  opkg update
  log_debug "Downloading passwall feed public key"
  wget -O passwall.pub https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub
  log_debug "Installing passwall feed public key"
  opkg-key add passwall.pub

  # Backup existing feed file
  if [ -f "${FEED_FILE}" ]; then
    log_info "Backing up old feed file '${FEED_FILE}' -> '${FEED_FILE}.bak'"
    cp "${FEED_FILE}" "${FEED_FILE}.bak"
  fi

  # Create feed file
  if [ ! -f "${FEED_FILE}" ]; then
    log_debug "Creating feed file: ${FEED_FILE}"
    touch "${FEED_FILE}"
  fi

  # Load OpenWrt release info
  . /etc/openwrt_release
  release="${DISTRIB_RELEASE%.*}"
  arch="${DISTRIB_ARCH}"

  if [ -z "${release}" ] || [ -z "${arch}" ]; then
    log_error "Failed to determine OpenWrt release or architecture"
    exit 1
  fi

  log_info "Distributive release: ${release}"
  log_info "Distributive architecture: ${arch}"

  for feed in passwall_luci passwall_packages passwall2; do
    url="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${release}/${arch}/${feed}"

    # Check if line already exists
    if grep -qF "${url}" "${FEED_FILE}"; then
      log_warn "Feed '${feed}' already exists in ${FEED_FILE}"
    else
      log_info "Adding feed '${feed}' to ${FEED_FILE}"
      echo "src/gz ${feed} ${url}" >>"${FEED_FILE}"
    fi
  done

  log_info "Passwall feed setup completed"
}

install_passwall_pkgs() {
  opkg update

  packages="dnsmasq-full wget-ssl unzip luci-app-passwall2 kmod-nft-socket kmod-nft-tproxy ca-bundle kmod-inet-diag kernel kmod-netlink-diag kmod-tun ipset xray-core"

  to_install=""
  total_size_needed=0
  for pkg in ${packages}; do
    # 1. Get Installed Version
    # usage: opkg list-installed returns "pkg - version"
    installed_pkg_version=$(opkg list-installed "${pkg}" | awk '{print $3}')

    # 2. Get Candidate Version and Size using AWK
    # We parse the output of 'opkg info'. We look for the first occurrence
    # of Version and Size.
    # Output format expected from awk: "VERSION SIZE"
    pkg_info=$(opkg info "${pkg}" | awk '
        /^Version:/ && !v { v=$2 }
        /^Size:/    && !s { s=$2 }
        END { 
            if (v) print v, (s ? s : 0) 
            else print "NOTFOUND 0"
        }
    ')
    pkg_version=$(echo "${pkg_info}" | awk '{print $1}')
    pkg_size=$(echo "${pkg_info}" | awk '{print $2}')

    log_debug "   ${pkg} version: ${pkg_version}"
    log_debug "   ${pkg} size: ${pkg_size}"
    log_debug "   ${pkg} installed version: ${installed_pkg_version}"

    # Check if package exists in repo
    if [ "${pkg_version}" = "NOTFOUND" ]; then
      log_error "Package '${pkg}' not found in repository"
      exit 1
    fi

    # 3. Compare Versions
    if [ "${installed_pkg_version}" = "${pkg_version}" ]; then
      log_info " - ${pkg}: Up to date (${installed_pkg_version}), skipping"
      continue
    elif [ -n "${installed_pkg_version}" ]; then
      log_info " + ${pkg}: Update found (${installed_pkg_version} -> ${pkg_version}) | Size: ${pkg_size} bytes"
    else
      log_info " + ${pkg}: Queued for install (${pkg_version}) | Size: ${pkg_size} bytes"
    fi

    # Add to list and sum size
    to_install="${to_install} ${pkg}"
    total_size_needed=$((total_size_needed + pkg_size))
  done

  log_debug "Packages to install: $(prettify_list "${to_install}" inline)"

  if [ -z "${to_install}" ]; then
    log_info "Nothing to do. All packages installed and current."
    return 0
  fi

  # 4. Check Storage
  # We check /overlay usually, or / if overlay isn't distinct.
  # df output column 4 is usually 'Available' in 1K blocks
  available_blocks=$(df /overlay | awk '/overlay/ {print $4}')
  # Fallback to root if overlay line not found
  if [ -z "${available_blocks}" ]; then
    available_blocks=$(df / | awk '/\/$/ {print $4}')
  fi

  # Convert 1K blocks to bytes
  available_bytes=$((available_blocks * 1024))
  total_required=$((total_size_needed + BUFFER))

  log_info "Download size: $total_size_needed bytes"
  log_info "Est. required: $total_required bytes"
  log_info "Free space:    $available_bytes bytes"

  if [ "${total_required}" -gt "${available_bytes}" ]; then
    log_error "Insufficient space. Missing approx $((total_required - available_bytes)) bytes."
    exit 1
  fi

  # 5. Download and Install
  # On OpenWrt, 'opkg install' streams the download and installs immediately.
  # Separate 'opkg download' is risky as it fills RAM/Storage with installers
  # before installation even begins.
  log_info "Space check passed"

  if ! yes_no "Do you want to continue installing packages?" Y; then
    log_info "Packages not installed"
    exit 0
  fi

  for pkg in ${to_install}; do
    if [ "$pkg" = "dnsmasq-full" ]; then
      opkg download dnsmasq-full

      if opkg list-installed dnsmasq >/dev/null 2>&1; then
        log_info "Backing up old DHCP config '/etc/config/dhcp' -> '/etc/config/dhcp.bak'"
        cp /etc/config/dhcp /etc/config/dhcp.bak

        log_info "Removing old dnsmasq package..."
        opkg remove dnsmasq
      else
        log_debug "dnsmasq not installed, skipping remove"
      fi

      log_info "Installing dnsmasq-full..."
      opkg install dnsmasq-full --cache "${TMP_DIR}"

      # Restore config if opkg created a temporary one
      if [ -f "/etc/config/dhcp-opkg" ]; then
        mv /etc/config/dhcp-opkg /etc/config/dhcp
      fi

      continue
    else
      log_info "Installing ${pkg}..."
      opkg install "${pkg}"
    fi
  done
}

check_installed() {
  if [ -f "/etc/init.d/passwall2" ]; then
    log_debug "luci-app-passwall2 installed successfully!"
  else
    log_error "Package luci-app-passwall2 not installed!"
    exit 1
  fi

  if [ -f "/usr/lib/opkg/info/dnsmasq-full.control" ]; then
    log_debug "dnsmaq-full installed successfully!"
  else
    log_error "Package dnsmasq-full not installed!"
    exit 1
  fi

  if [ -f "/usr/bin/xray" ]; then
    log_debug "xray-core installed successfully!"
  else
    log_error "Package xray-core not installed!"
    exit 1
  fi

  log_info "All packages installed. It is recommended to reboot the device"
}

main() {
  parse_args "$@"

  [ "$VERBOSE" -eq 1 ] && log_debug "Verbose mode enabled"

  check_dependencies
  check_snapshot
  create_temp_workspace

  install_passwall_feeds
  install_passwall_pkgs
  check_installed
}

main "$@"
