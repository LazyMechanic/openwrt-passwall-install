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

    # Disable the traps immediately to prevent recursion
    trap - EXIT INT TERM

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

# Prompts user with a yes/no question and returns 0 for yes, 1 for no
# Parameters:
#   $1 - question
#   $2 - optional default: Y/N (empty = no default)
# Usage:
#   if prompt_yes_no "Do you want to continue?" Y; then
#     echo "User answered yes"
#   else
#     echo "User answered no"
#   fi
prompt_yes_no() {
    prompt="${1}"
    default="${2}"
    answer=""

    printf '%s%s%s\n' "${COLOR_GREEN}" "${prompt}" "${COLOR_RESET}"

    while true; do
        # Build prompt
        if [ -n "${default}" ]; then
            if [ "${default}" = "Y" ] || [ "${default}" = "y" ]; then
                prompt_next="> [Y/n] "
            else
                prompt_next="> [y/N] "
            fi
        else
            prompt_next="> [y/n] "
        fi

        # Prompt user
        printf "%s" "${prompt_next}"
        read answer || return 1 # Ctrl+D counts as no

        # Use default if input is empty
        if [ -z "${answer}" ] && [ -n "${default}" ]; then
            answer="${default}"
        fi

        # Check answer
        case "${answer}" in
        y | Y | yes | YES | Yes)
            return 0
            ;;
        n | N | no | NO | No)
            return 1
            ;;
        *)
            log_error "Please answer yes or no"
            ;;
        esac
    done
}


# Prompts the user with a question and a list of variants.
# If a default is provided and the user presses Enter, the default is returned.
#
# Parameters:
#   $1 - Destination variable
#   $2 - Prompt text
#   $3 - Default value (empty = no default)
#   $4..$N - Variants. Consist of pairs ('<variant>:[<mapped value>]' '<description>')
#
# Usage:
#   prompt_select \
#       VAR1
#       'Question?' 'ABC' \
#       '1' 'Variant 1' '' \
#       '2' 'Variant 2' '' \
#       'ABC:CBD' 'Variant ABC')"
#
#   case "${VAR1}" in
#       '1') echo "1 selected" ;;
#       '2') echo "2 selected" ;;
#       'CBD') echo "ABC selected" ;;
#   esac
#
#   prompt_select \
#       VAR2
#       'noitseuQ?' '' \
#       '1' 'Variant 1' '' \
#       '2' 'Variant 2' '' \
#       'ABC' 'Variant ABC')"
#
#   case "${VAR2}" in
#       '1') echo "1 selected" ;;
#       '2') echo "2 selected" ;;
#       'ABC') echo "ABC selected" ;;
#   esac
#
# Display:
#   Question?
#     [1] Variant 1
#     [2] Variant 2
#     [ABC] Variant ABC
#   > [ABC]
#   
#   noitseuQ?
#     [1] Variant 1
#     [2] Variant 2
#     [ABC] Variant ABC
#   > 
prompt_select() {
    destvar="${1}"
    prompt="${2}"
    default="${3}"
    shift 3

    validate_destvar "${destvar}"

    # Newline character for string splitting
    nl='
'

    # Build variants list and print menu
    # Each entry stored as "input:mapped" separated by newlines
    variants=""

    log_debug3 "destvar: ${destvar}"
    log_debug3 "prompt:  ${prompt}"
    log_debug3 "default: ${default}"

    printf '%s%s%s\n' "${COLOR_GREEN}" "${prompt}" "${COLOR_RESET}"

    while [ $# -ge 2 ]; do
        varspec="$1"
        vardesc="$2"
        shift 2

        # Parse variant:mapped format
        case "${varspec}" in
            *:*)
                varinput="${varspec%%:*}"
                varmapped="${varspec#*:}"
                ;;
            *)
                varinput="${varspec}"
                varmapped="${varspec}"
                ;;
        esac

        log_debug3 "variant: ${varinput} -> ${varmapped} (${vardesc})"

        # Store for later validation
        if [ -z "${variants}" ]; then
            variants="${varinput}:${varmapped}"
        else
            variants="${variants}${nl}${varinput}:${varmapped}"
        fi

        # Print menu item
        printf '  %s) %s\n' "${varinput}" "${vardesc}"
    done

    ans=""

    while :; do
        if [ -n "${default}" ]; then
            printf '> [%s] ' "${default}"
        else
            printf '> '
        fi

        read ans || return 1

        # Empty input → use default
        if [ -z "${ans}" ]; then
            if [ -n "${default}" ]; then
                ans="${default}"
            else
                log_error "Input required"
                continue
            fi
        fi

        # Validate and find mapped value
        mapped=""
        found=0
        remaining="${variants}"

        while [ -n "${remaining}" ]; do
            # Extract line and update remaining
            case "${remaining}" in
                *"${nl}"*)
                    line="${remaining%%${nl}*}"
                    remaining="${remaining#*${nl}}"
                    ;;
                *)
                    line="${remaining}"
                    remaining=""
                    ;;
            esac

            [ -z "${line}" ] && continue

            # Parse input:mapped
            entryinput="${line%%:*}"
            entrymapped="${line#*:}"

            if [ "${ans}" = "${entryinput}" ]; then
                mapped="${entrymapped}"
                found=1
                break
            fi
        done

        if [ "${found}" = "1" ]; then
            log_debug3 "input: ${mapped}"
            eval "${destvar}=\${mapped}"
            return 0
        fi

        log_error "Invalid answer, try again."
    done
}

# Prompts the user for private (non-echoed) input, e.g. a password.
# Returns the entered value via stdout.
# If a default is provided and the user presses Enter, the default is returned.
#
# Parameters:
#   $1 - Destination variable
#   $2 - Prompt text
#   $3 - Optional default value (empty = no default)
#
# Usage:
#   prompt_hidden_input password 'Enter password'
#   [ "${password}" -eq "..." ] || exit 1
#
#   prompt_hidden_input secret 'Enter secret' 'changeme'
#   [ "${secret}" -eq "changeme" ] || exit 1
#
# Display:
#   Enter password
#   > 
#   Enter secret
#   > [changeme] 
prompt_hidden_input() {
    destvar="${1}"
    prompt="${2}"
    default="${3:-}"
    inputval=""

    validate_destvar "${destvar}"
    
    log_debug3 "destvar: ${destvar}"
    log_debug3 "prompt:  ${prompt}"
    log_debug3 "default: ${default}"

    # Print the prompt
    printf '%s%s%s\n' "${COLOR_GREEN}" "${prompt}" "${COLOR_RESET}"

    # Print the input line with optional default
    if [ -n "${default}" ]; then
        printf '> [%s] ' "${default}"
    else
        printf '> '
    fi

    # Save terminal settings and disable echo
    savedstty=$(stty -g 2>/dev/null)
    stty -echo 2>/dev/null

    # Read the input
    read inputval

    # Restore terminal settings
    if [ -n "${savedstty}" ]; then
        stty "${savedstty}" 2>/dev/null
    else
        stty echo 2>/dev/null
    fi

    # Print newline since echo was disabled during input
    printf '\n'

    # Use default if input is empty and default is provided
    if [ -z "${inputval}" ] && [ -n "${default}" ]; then
        inputval="${default}"
    fi

    log_debug3 "input: ${inputval}"

    # Set the destination variable
    eval "${destvar}=\${inputval}"
}

# Prompt user for input with optional validation
#
# Parameters:
#   $1 - Destination variable
#   $2 - Prompt message (required)
#   $3 - Default value (optional)
#   $4 - Validation type (optional, default: any)
#   $5.. - Validation arguments (optional, type-specific)
#
# Usage:
#   prompt_input VAR "prompt" [default] [type] [args]
#
# Validation types:
#   any     - Accept any input (default)
#   number  - Positive integer only (0, 1, 42, ...)
#   string  - Non-empty string, $5 = max length (optional)
#   enum    - Enumeration, $5..$N variants 
#   ipv4    - Valid IPv4 address (0-255 per octet)
#   port    - Valid port number (1-65535)
#   range   - Integer in range $5..=$6
#
# Usage:
#   prompt_input NAME     "Enter name:"
#   prompt_input TAG      "Enter tag:"   "default"
#   prompt_input COUNT    "Enter count:" "10"          "number")
#   prompt_input USERNAME "Username:"    ""            "string" "32")
#   prompt_input IP       "Server IP:"   "192.168.1.1" "ipv4")
#   prompt_input PORT     "Port:"        "8080"        "port")
#   prompt_input PERCENT  "Percent:"     "50"          "range"  "0"   "100")
#   prompt_input TEMP     "Temperature:" "20"          "range"  "-40" "50")
prompt_input() {
    destvar="${1}"
    prompt="${2}"
    shift 2
    
    default=""
    if [ $# -gt 0 ]; then 
        default="${1}"
        shift
    fi

    vtype="any"
    if [ $# -gt 0 ]; then 
        vtype="${1}"
        shift
    fi
    
    vargs="$*"

    validate_destvar "${destvar}"

    ans=""
    err=""

    log_debug3 "destvar: ${destvar}"
    log_debug3 "prompt:  ${prompt}"
    log_debug3 "default: ${default}"
    log_debug3 "vtype:   ${vtype}"
    log_debug3 "vargs:   ${vargs}"
    
    printf '%s%s%s\n' "${COLOR_GREEN}" "${prompt}" "${COLOR_RESET}"
    
    while :; do
        if [ -n "${default}" ]; then
            printf '> [%s] ' "${default}"
        else
            printf '> '
        fi
        
        read ans || return 1
        
        # Use default if empty
        [ -z "${ans}" ] && ans="${default}"
        
        # Still empty and validation required?
        if [ -z "${ans}" ] && [ "${vtype}" != "any" ]; then
            log_error "Input required"
            continue
        fi
        
        # Validate
        err=""
        case "${vtype}" in
            any)
                ;;
            number)
                validate_number "${ans}" ${vargs} || err="Enter a valid number"
                ;;
            string)
                validate_string "${ans}" ${vargs} || err="Invalid string"
                ;;
            enum)
                validate_enum "${ans}" ${vargs} || err="Must be one of: $(prettify_list "${vargs}" inline)"
                ;;
            ipv4)
                validate_ipv4 "${ans}" ${vargs} || err="Invalid IPv4 (e.g., 192.168.1.1)"
                ;;
            port)
                validate_port "${ans}" ${vargs} || err="Port must be 1-65535"
                ;;
            range)
                validate_range "${ans}" ${vargs} || err="Must be between ${1}-${2}"
                ;;
            *)
                log_error "Unknown type '${vtype}'"
                return 2
                ;;
        esac
        
        if [ -n "${err}" ]; then
            log_error "${err}"
            continue
        fi

        log_debug3 "input: ${ans}"

        # Set the destination variable and exit loop
        eval "${destvar}=\${ans}"
        break
    done
}

# Validate variable name to prevent command injection
validate_destvar() {
    destvar="${1}"
    case "${destvar}" in
        ''|*[!a-zA-Z0-9_]*|[0-9]*)
            log_error "Invalid variable name: ${destvar}"
            exit 1
            ;;
    esac
}

validate_number() {
    [ $# -ne 1 ] && {
        log_error "'number' takes no additional arguments (got $(($# - 1)))"
        return 2
    }
    
    case "${1}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

validate_string() {
    [ $# -lt 1 ] && {
        log_error "'string' requires value"
        return 2
    }
    [ $# -gt 3 ] && {
        log_error "'string' takes at most 2 arguments (got $(($# - 1)))"
        return 2
    }

    val="${1}"
    minlen="${2:-}"
    maxlen="${3:-}"

    len="${#val}"

    # Validate min length
    if [ -n "${minlen}" ]; then
        case "${minlen}" in
            ''|*[!0-9]*) log_error "'string' min length must be a number"; return 2 ;;
        esac
        [ "${len}" -lt "${minlen}" ] && return 1
    fi

    # Validate max length
    if [ -n "${maxlen}" ]; then
        case "${maxlen}" in
            ''|*[!0-9]*) log_error "'string' max length must be a number"; return 2 ;;
        esac
        [ "${len}" -gt "${maxlen}" ] && return 1
    fi

    return 0
}

validate_enum() {
    [ $# -lt 2 ] && {
        log_error "'enum' requires at least one allowed value"
        return 2
    }

    val="${1}"
    shift

    for opt do
        [ "${val}" = "${opt}" ] && return 0
    done

    return 1
}

validate_ipv4() {
    [ $# -ne 1 ] && {
        log_error "'ipv4' takes no additional arguments (got $(($# - 1))"
        return 2
    }
    
    case "${1}" in
        *[!0-9.]*) return 1 ;;
        .*|*.|*..*) return 1 ;;
    esac
    
    oifs="${IFS}"
    IFS='.'
    set -- ${1}
    IFS="${oifs}"
    
    [ $# -eq 4 ] || return 1
    
    for octet do
        case "${octet}" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "${octet}" -gt 255 ] && return 1
    done
    
    return 0
}

validate_port() {
    [ $# -ne 1 ] && {
        log_error "'port' takes no additional arguments (got $(($# - 1)))"
        return 2
    }
    
    case "${1}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${1}" -ge 1 ] && [ "${1}" -le 65535 ]
}

validate_range() {
    [ $# -lt 3 ] && {
        log_error "'range' requires min and max arguments"
        return 2
    }
    [ $# -gt 3 ] && {
        log_error "'range' takes exactly 2 arguments (got $(($# - 1)))"
        return 2
    }
    
    val="${1}"
    min="${2}"
    max="${3}"
    
    case "${val#-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    
    [ "${val}" -ge "${min}" ] && [ "${val}" -le "${max}" ]
}

# Returns a formatted string from a space-separated list
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
    log_info "Checking the distributive version"
    /sbin/reload_config

    snapshot=$(grep -o SNAPSHOT /etc/openwrt_release | sed -n '1p')

    if [ "${snapshot}" = "SNAPSHOT" ]; then
        log_error "SNAPSHOT version not supported"
        exit 1
    fi

    log_info "Distributive version is not SNAPSHOT, ok!"
}

create_temp_workspace() {
    TMP_DIR="$(mktemp -d /tmp/passwall.XXXXXX)"
    cd "${TMP_DIR}"
}

install_passwall_feeds() {
    if ! prompt_yes_no 'Install passwall feeds?' Y; then return; fi

    repo="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
    pub_key="${repo}/passwall.pub"

    # Load OpenWrt release info
    # shellcheck source=/dev/null
    . /etc/openwrt_release
    release="${DISTRIB_RELEASE%.*}"
    arch="${DISTRIB_ARCH}"

    if [ -z "${release}" ] || [ -z "${arch}" ]; then
        log_error "Failed to determine OpenWrt release or architecture"
        exit 1
    fi

    feeds=""
    for feed in passwall_luci passwall_packages passwall2; do
        url="${repo}/releases/packages-${release}/${arch}/${feed}"
        if [ -z "${feeds}" ]; then 
            feeds="${feed} ${url}"
        else 
            feeds="${feeds}\n${feed} ${url}"
        fi
    done
    
    # Print
    log_info "Distributive release:      ${release}"
    log_info "Distributive architecture: ${arch}"
    log_info "Passwall feed public key:  ${pub_key}"
    printf '%b\n' "${feeds}" | while read -r feed url; do
        log_info "Feed ${feed} -> ${url}"
    done

    if ! prompt_yes_no 'Ready to install passwall feeds?' Y; then return; fi

    log_debug "Installing passwall feed public key"
    wget -O passwall.pub "${pub_key}"
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

    log_debug "Installing passwall feeds"
    printf '%b\n' "${feeds}" | while read -r feed url; do
        # Check if rtl already exists
        if grep -qF "${url}" "${FEED_FILE}"; then
            log_warn "Feed '${feed}' already exists in ${FEED_FILE}"
        else
            log_info "Adding feed '${feed}' to ${FEED_FILE}"
            echo "src/gz ${feed} ${url}" >>"${FEED_FILE}"
        fi
    done

    log_info "Passwall feeds installed!"
}

bytes_to_human() {
    bytes="${1}"
    div=1
    unit="B"

    if [ "${bytes}" -ge 1099511627776 ]; then
        div=1099511627776
        unit="TB"
    elif [ "${bytes}" -ge 1073741824 ]; then
        div=1073741824
        unit="GB"
    elif [ "${bytes}" -ge 1048576 ]; then
        div=1048576
        unit="MB"
    elif [ "${bytes}" -ge 1024 ]; then
        div=1024
        unit="KB"
    fi

    if [ "${div}" -eq 1 ]; then
        printf '%d %s' "$bytes" "$unit"
    else
        whole=$((bytes / div))
        remainder=$((bytes % div))
        decimal=$(((remainder * 10) / div))
        printf '%d.%d %s' "${whole}" "${decimal}" "${unit}"
    fi
}

print_pkg_info() {
    pkg="${1}"
    action="${2}"
    version="${3}"
    installed_version="${4}"
    size="${5}"

    case "${action}" in
        install)
            log_info " + ${pkg}: Queued for install"
            ;;
        update)
            log_info " + ${pkg}: Update found"
            ;;
        skip)
            log_info " - ${pkg}: Up to date, skipping"
            ;;
        *)
            log_error "Unknown parameter"
            exit 1
            ;;
    esac
    
    log_info "   Version: ${version}"
    log_info "   Installed version: ${installed_version:--}"
    log_info "   Size: $(bytes_to_human "${size}") (${size} bytes)"
}

install_passwall_pkgs() {
    if ! prompt_yes_no 'Install passwall packages?' Y; then return; fi

    log_info "Update packages"
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

        # Check if package exists in repo
        if [ "${pkg_version}" = "NOTFOUND" ]; then
            log_error "Package '${pkg}' not found in repository"
            return
        fi

        # 3. Compare Versions
        if [ "${installed_pkg_version}" = "${pkg_version}" ]; then
            print_pkg_info "${pkg}" skip "${pkg_version}" "${installed_pkg_version}" "${pkg_size}"
            continue
        elif [ -n "${installed_pkg_version}" ]; then
            print_pkg_info "${pkg}" update "${pkg_version}" "${installed_pkg_version}" "${pkg_size}"
        else
            print_pkg_info "${pkg}" install "${pkg_version}" "${installed_pkg_version}" "${pkg_size}"
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

    log_info "Download size: $(bytes_to_human "${total_size_needed}") (${total_size_needed} bytes)"
    log_info "Est. required: $(bytes_to_human "${total_required}") (${total_required} bytes)"
    log_info "Free space:    $(bytes_to_human "${available_bytes}") (${available_bytes} bytes)"

    if [ "${total_required}" -gt "${available_bytes}" ]; then
        log_error "Insufficient space. Missing approx $((total_required - available_bytes)) bytes."
        exit 1
    fi

    log_info "Space check passed"

    if ! prompt_yes_no 'Ready to install passwall packages?' Y; then return; fi

    # 5. Download and Install
    for pkg in ${to_install}; do
        log_info "Installing ${pkg}..."
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

            opkg install dnsmasq-full --cache "${TMP_DIR}"

            # Restore config if opkg created a temporary one
            if [ -f "/etc/config/dhcp-opkg" ]; then
                dhcp_config=""
                prompt_select dhcp_config 'Which DHCP config should make the primary one?' '1' \
                    '1' 'dnsmasq (old)' \
                    '2' 'dnsmasq-full (new)'
                case "${dhcp_config}" in
                    1)
                        log_info "Move file '/etc/config/dhcp-opkg' -> '/etc/config/dhcp'"
                        mv /etc/config/dhcp-opkg /etc/config/dhcp
                        ;;
                    2)
                        log_info "Leave the configuration as it is"
                        ;;
                esac
            fi

            continue
        else
            opkg install "${pkg}"
        fi
    done
    
    log_info "Passwall packages installed!"
}

main() {
    parse_args "$@"

    [ "$VERBOSE" -eq 1 ] && log_debug "Verbose mode enabled"

    check_dependencies
    check_snapshot
    create_temp_workspace

    install_passwall_feeds
    install_passwall_pkgs

    if prompt_yes_no "Do you want to reboot device?" Y; then
        log_info "Rebooting..."
        reboot
    fi
}

main "$@"
