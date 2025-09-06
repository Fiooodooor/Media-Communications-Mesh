#!/bin/bash

# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2023-2025 Intel Corporation

# common.sh - Utility functions for Media-Communications-Mesh (MCM) scripts
# Version: 1.0.0
# Purpose: Provides shared environment setup, logging, file manipulation, and system utilities for MCM scripts

# Resolve and set repository directory
REPO_DIR="$(readlink -f "$(dirname -- "${BASH_SOURCE[0]}")/..")" || {
    log_error "Failed to resolve REPO_DIR with readlink"
    exit 1
}

# Load versions file if it exists
MCM_VERSIONS_FILE_PATH="${MCM_VERSIONS_FILE_PATH:-${REPO_DIR}/versions.env}"
if [[ -f "${MCM_VERSIONS_FILE_PATH}" && -r "${MCM_VERSIONS_FILE_PATH}" ]]; then
    # shellcheck source=versions.env
    . "${MCM_VERSIONS_FILE_PATH}"
else
    log_warning "Versions file ${MCM_VERSIONS_FILE_PATH} not found or unreadable"
fi

# Set default package manager and number of processors
PM="${PM:-apt-get}"
NPROC="${NPROC:-$(nproc 2>/dev/null || echo 4)}"

# Update PATH and PKG_CONFIG_PATH if needed
if ! grep -q "/root/.local/bin" <<< "${PATH}" 2>/dev/null; then
    for path in "/root/.local/bin" "/root/bin" "/root/usr/bin"; do
        [ -d "$path" ] && export PATH="${path}:${PATH}"
    done
    for pkg_path in "/usr/lib/pkgconfig" "/usr/local/lib/pkgconfig" \
                    "/usr/lib64/pkgconfig" "/usr/local/lib/x86_64-linux-gnu/pkgconfig"; do
        [ -d "$pkg_path" ] && export PKG_CONFIG_PATH="${pkg_path}:${PKG_CONFIG_PATH:-}"
    done
fi

# Setup logging basic variables as directories
function log_initialise_logger() {

    check_dir "${MCM_LOGS_DIR}"
    timestamp=$(date +%Y%m%d_%H%M%S)
    export MCM_LOGS_DIR="${MCM_LOGS_DIR:-${REPO_DIR}/_logs}"
    export MCM_LOG_FILE_PATH=${MCM_LOG:-${MCM_LOGS_DIR}/mcm_${timestamp}.log}
    
    # Check if terminal supports colors
    if command -v tput >/dev/null 2>&1 && [ "$(tput colors)" -ge 8 ]; then
        BOLD="\e[1;"
        REGULAR="\e[0;"
        RED="31m"
        GREEN="32m"
        YELLOW="33m"
        BLUE="34m"
        EndCl='\e[m'
    else
        BOLD=""
        REGULAR=""
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        EndCl=""
        export DISABLE_COLOR_PRINT=1
    fi
}

# Logging function with colorized output as default
function log_message() {
    local type="${1}"
    shift
    local HEADER="${type}: "
    local FOOTER=""
    if [ -z "${DISABLE_COLOR_PRINT}" ]; then
        FOOTER='\e[0m'
        case "${type,,}" in
            error)        HEADER="${REGULAR}${RED}${type}:  ${BOLD}${RED}" ;;
            warn|warning) HEADER="${REGULAR}${BLUE}${type}: ${BOLD}${YELLOW}" ;;
            succ|success) HEADER="${REGULAR}${BLUE}${type}: ${BOLD}${GREEN}" ;;
            info|*)       HEADER="${REGULAR}${BLUE}${type}: ${BOLD}${BLUE}" ;;
        esac
    fi
    echo -e "${HEADER}$*${FOOTER}" >&2
}

function log_info()    { log_message "INFO" "$*"; }
function log_success() { log_message "SUCCESS" "$*"; }
function log_warning() { log_message "WARNING" "$*"; }
function log_error()   { log_message "ERROR" "$*"; }

# Prompt user for yes/no input with customizable default
function get_user_input_confirm() {
    local confirm
    local confirm_string
    local confirm_default="${1:-0}"
    confirm_string=( "(N)o" "(Y)es" )

    echo -en "${REGULAR}${BLUE}CHOOSE:${BOLD}${BLUE} (Y)es/(N)o [default: ${confirm_string[$confirm_default]}]: ${EndCl}" >&2
    read -r confirm
    if [[ -z "$confirm" ]]; then
        confirm="$confirm_default"
    else
        [[ $confirm =~ ^[yY]([eE][sS])?$ ]] && confirm="1" || confirm="0"
    fi
    echo "${confirm}"
}

function get_user_input_def_yes() { get_user_input_confirm 1; }
function get_user_input_def_no() { get_user_input_confirm 0; }

# File and path manipulation utilities
function get_filename() { echo "${1##*/}"; }
function get_dirname() { echo "${1%/*}/"; }
function get_extension() { echo "$(get_filename "${1}")" | cut -d'.' -f2-; }
function check_extension() {
    local filename="$1"
    local extension="$2"
    [[ "${filename}" == "${filename%${extension}}" ]] && echo "0" || echo "1"
}
function get_basename() { echo "$(get_filename "${1}")" | cut -d'.' -f1; }

# Parse GitHub URL into namespace and repository
function get_github_elements() {
    local path_part="${1#*://github.com/}"
    local path_elements
    if ! command -v mapfile >/dev/null 2>&1; then
        log_error "mapfile command not found. Please install bash 4.0 or higher."
    fi
    mapfile -t -d'/' path_elements <<< "${path_part}"
    if [[ "${#path_elements[@]}" -lt 2 ]]; then
        log_error "Invalid GitHub URL: $1"
    fi
    echo "${path_elements[0]} ${path_elements[1]}"
}

function get_github_namespace() { cut -d' ' -f1 <<< "$(get_github_elements "$1")"; }
function get_github_repo() { cut -d' ' -f2 <<< "$(get_github_elements "$1")"; }

# Add suffix to filename base
function get_filepath_add_sufix() {
    local dir_path="$(get_dirname "${2}")"
    local file_base="$(get_basename "${2}")"
    local file_ext="$(get_extension "${2}")"
    echo "${dir_path}${file_base}${1}.${file_ext}"
}

# Check if a command exists
function command_exists() { command -v "$@" >/dev/null 2>&1; }

# Run command as root
function as_root() {
    local CMD_TO_EVALUATE="$*"
    local CURRENT_USER_ID="$(id -u 2>/dev/null || echo "${EUID:-0}")"
    local AS_ROOT="/bin/bash -c"

    if [ "${CURRENT_USER_ID}" -ne 0 ]; then
        if command_exists sudo; then
            AS_ROOT="sudo -E /bin/bash -c"
        elif command_exists su; then
            AS_ROOT="su -c"
        else
            log_error "Command requires root. Neither sudo nor su found in PATH."
        fi
    fi
    $AS_ROOT "${CMD_TO_EVALUATE[*]}" || log_error "Failed to execute as root: ${CMD_TO_EVALUATE[*]}"
}

# Make GitHub API call
function github_api_call() {
    local url="$1"
    shift
    local GITHUB_API_URL="https://api.github.com"
    local INPUT_OWNER=$(echo "${url#"${GITHUB_API_URL}/repos/"}" | cut -f1 -d'/')
    local INPUT_REPO=$(echo "${url#"${GITHUB_API_URL}/repos/"}" | cut -f2 -d'/')
    local API_SUBPATH="${url#"${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/"}"
    if [ -z "${INPUT_GITHUB_TOKEN}" ]; then
        log_error "INPUT_GITHUB_TOKEN environment variable not set."
    fi
    if ! [[ "${INPUT_GITHUB_TOKEN}" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid INPUT_GITHUB_TOKEN format."
    fi

    log_info "Calling GitHub API: ${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/${API_SUBPATH}"
    if API_RESPONSE=$(curl --fail-with-body -sSL \
        "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/${API_SUBPATH}" \
        -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
        -H 'Accept: application/vnd.github.v3+json' \
        -H 'Content-Type: application/json' \
        "$@"); then
        echo "${API_RESPONSE}"
    else
        log_error "GitHub API call failed: ${API_RESPONSE}"
    fi
}

# Print ASCII logo with color
function print_logo() {
    local blue_code=( 26 27 20 19 20 20 21 04 27 26 32 12 33 06 39 38 44 45 )
    local IFS=$'\n\t'
    local logo_string
    logo_string="$(cat <<- EOF
    .-----------------------------------------------------------.
    |        *          .                    ..        .    *   |
    |       .                         .   .  .  .   .           |
    |                                    . .  *:. . .           |
    |                             .  .   . .. .         .       |
    |                    .     . .  . ...    .    .             |
    |  .              .  .  . .    . .  . .                     |
    |                   .    .     . ...   ..   .       .       |
    |            .  .    . *.   . .                             |
    |                   :.  .           .                       |
    |            .   .    .    .                                |
    |        .  .  .    . ^                                     |
    |       .  .. :.    . |             .               .       |
    |.   ... .            |                                     |
    | :.  . .   *.    We are here.              .               |
    |   .               .             *.                        |
    .©-Intel-Corporation--------------------ascii-author-unknown.
    =                                                           =
    =        88                                  88             =
    =        ""                ,d                88             =
    =        88                88                88             =
    =        88  8b,dPPYba,  MM88MMM  ,adPPYba,  88             =
    =        88  88P'   '"8a   88    a8P_____88  88             =
    =        88  88       88   88    8PP"""""""  88             =
    =        88  88       88   88,   "8b,   ,aa  88             =
    =        88  88       88   "Y888  '"Ybbd8"'  88             =
    =                                                           =
    =============================================================
EOF
)"

    local colorized_logo_string=""
    for (( i=0; i<${#logo_string}; i++ )); do
        colorized_logo_string+="\e[38;05;${blue_code[$(( (i-(i/64)*64)/4 ))]}m"
        colorized_logo_string+="${logo_string:$i:1}"
    done
    colorized_logo_string+='\e[m\n'
    echo -e "$colorized_logo_string" >&2
}

# Print animated logo sequence
function print_logo_sequence() {
    set +x
    local wait_between_frames="${1:-0}"
    local wait_cmd=""
    [ "${wait_between_frames}" != "0" ] && wait_cmd="sleep ${wait_between_frames}"

    local blue_code_fixed=( 26 27 20 19 20 20 21 04 27 26 32 12 33 06 39 38 44 45 )
    local size=${#blue_code_fixed[@]}
    for (( move=0; move<size; move++ )); do
        blue_code=()
        for (( i=move; i<size; i++ )); do
            blue_code+=("${blue_code_fixed[i]}")
        done
        for (( i=0; i<move; i++ )); do
            blue_code+=("${blue_code_fixed[i]}")
        done
        echo -en "\e[0;0H"
        print_logo
        ${wait_cmd}
    done
}

function print_logo_anim() {
    set +x
    local number_of_sequences="${1:-2}"
    local wait_between_frames="${2:-0.025}"
    command_exists clear || log_error "clear command not found"
    clear
    for (( pt=0; pt<number_of_sequences; pt++ )); do
        print_logo_sequence "${wait_between_frames}"
    done
}

# Error handling with debug output
function catch_error_print_debug() {
    local _last_command_height=""
    local -n _lineno="${1:-LINENO}"
    local -n _bash_lineno="${2:-BASH_LINENO}"
    local _last_command="${3:-${BASH_COMMAND}}"
    local _code="${4:-0}"
    local -a _output_array=()
    _last_command_height="$(wc -l <<<"${_last_command}")"

    _output_array+=(
        '---'
        "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        "lines_history: [${_lineno} ${_bash_lineno[*]}]"
        "function_trace: [${FUNCNAME[*]}]"
        "exit_code: ${_code}"
    )

    if [[ "${#BASH_SOURCE[@]}" -gt 1 ]]; then
        _output_array+=('source_trace:')
        for _item in "${BASH_SOURCE[@]}"; do
            _output_array+=("  - ${_item}")
        done
    else
        _output_array+=("source_trace: [${BASH_SOURCE[*]}]")
    fi

    if [[ "${_last_command_height}" -gt 1 ]]; then
        _output_array+=('last_command: ->')
        _output_array+=("${_last_command}")
    else
        _output_array+=("last_command: ${_last_command}")
    fi

    _output_array+=('---')
    log_error "${_output_array[*]}"
}

function trap_error_print_debug() {
    log_info "Setting trap for error handling"
    trap 'catch_error_print_debug "LINENO" "BASH_LINENO" "${BASH_COMMAND}" "${?}"; exit 1' SIGINT ERR
    log_info "Trap set successfully"
}

# Download and unpack GitHub archive
function git_download_strip_unpack() {
    local name="${1}"
    local version="${2}"
    local dest_dir="${3}"
    local filename="$(get_filename "${version}")"
    local creds=""
    [ -n "${GITHUB_CREDENTIALS}" ] && creds="${GITHUB_CREDENTIALS}@"

    mkdir -p "${dest_dir}" || log_error "Failed to create directory ${dest_dir}"
    curl -Lf "https://${creds}github.com/${name}/archive/${version}.tar.gz" -o "${dest_dir}/${filename}.tar.gz" || \
        log_error "Failed to download ${version} from ${name}"
    tar -zx --strip-components=1 -C "${dest_dir}" -f "${dest_dir}/${filename}.tar.gz" || \
        log_error "Failed to extract ${dest_dir}/${filename}.tar.gz"
    rm -f "${dest_dir}/${filename}.tar.gz" || log_warning "Failed to remove ${dest_dir}/${filename}.tar.gz"
}

# Download and unpack from URL
function wget_download_strip_unpack() {
    local source_url="${1}"
    local dest_dir="${2}"
    local filename="$(get_filename "${source_url}")"
    local creds=""
    [ -n "${GITHUB_CREDENTIALS}" ] && creds="${GITHUB_CREDENTIALS}@"

    mkdir -p "${dest_dir}" || log_error "Failed to create directory ${dest_dir}"
    curl -Lf "${source_url}" -o "${dest_dir}/${filename}.tar.gz" || \
        log_error "Failed to download ${source_url}"
    tar -zx --strip-components=1 -C "${dest_dir}" -f "${dest_dir}/${filename}.tar.gz" || \
        log_error "Failed to extract ${dest_dir}/${filename}.tar.gz"
    rm -f "${dest_dir}/${filename}.tar.gz" || log_warning "Failed to remove ${dest_dir}/${filename}.tar.gz"
}

# Setup package manager
function setup_package_manager() {
    local TIBER_USE_PM="${PM:-$1}"
    if command_exists "${TIBER_USE_PM}"; then
        export PM="${TIBER_USE_PM}"
    elif command_exists yum; then
        export PM='yum'
    elif command_exists dnf; then
        export PM='dnf'
    elif command_exists apt-get; then
        export PM='apt-get'
    elif command_exists apt; then
        export PM='apt'
    else
        log_error "No known package manager found. Set PM variable, e.g., 'export PM=apt'"
    fi
    log_info "Setting package manager to ${PM}"
    echo "${PM}"
}

# Setup FFmpeg directory and version
function lib_setup_ffmpeg_dir_and_version() {
    local FFMPEG_VER="${1:-${FFMPEG_VER:-7.0}}"
    local FFMPEG_7_0_DIR="${FFMPEG_7_0_DIR:-ffmpeg-7-0}"
    local FFMPEG_6_1_DIR="${FFMPEG_6_1_DIR:-ffmpeg-6-1}"
    local supported_versions=("6.1" "7.0")

    if [[ " ${supported_versions[*]} " =~ " ${FFMPEG_VER} " ]]; then
        case "${FFMPEG_VER}" in
            "7.0") FFMPEG_SUB_DIR="${FFMPEG_7_0_DIR}" ;;
            "6.1") FFMPEG_SUB_DIR="${FFMPEG_6_1_DIR}" ;;
        esac
    else
        log_error "Unsupported FFmpeg version '${FFMPEG_VER}'. Supported: ${supported_versions[*]}"
    fi
    export FFMPEG_VER FFMPEG_SUB_DIR
}

# Execute command locally or via SSH
function exec_command() {
    local SSH_STRICT_HOST_KEY_CHECKING="accept-new"
    local SSH_CMD="ssh -oStrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING} -t -o"
    local values_returned=""
    local user_at_address=""

    [[ "$#" -eq 2 ]] && user_at_address="${2}"
    [[ "$#" -eq 3 ]] && user_at_address="${3}@${2}"

    if [ "$#" -eq 1 ]; then
        values_returned="$($1 2>/dev/null)" || log_error "Failed to execute: $1"
    elif [[ "$#" -eq 2 || "$#" -eq 3 ]]; then
        values_returned="$($SSH_CMD "RemoteCommand=$1" "${user_at_address}" 2>/dev/null)" || \
            log_error "Failed to execute SSH command: $1 on ${user_at_address}"
    else
        log_error "Invalid arguments for exec_command(). Expected 1, 2, or 3 arguments, got $#"
    fi

    if [ -z "$values_returned" ]; then
        log_error "No results returned from command"
    fi
    echo "${values_returned}"
}

function get_hostname() {
    exec_command 'hostname' "$@"
}

function get_intel_nic_device() {
    exec_command "lspci | grep 'Intel Corporation.*\(810\|X722\)'" "$@"
}

function get_default_route_nic() {
    command_exists jq || log_error "jq command not found for get_default_route_nic"
    exec_command "ip -json r show default | jq '.[0].dev' -r" "$@"
}

# Function: get_cpu_arch
# Purpose: Check Intel CPU architecture and return short name
# Arguments: $1 - Directory path
function get_cpu_arch() {
    local arch
    arch="$(exec_command 'cat /sys/devices/cpu/caps/pmu_name' "$@")" || log_error "Failed to get CPU architecture: $arch"
    case $arch in
        icelake)        log_info "Xeon IceLake CPU (icx)" >&2; echo "icx" ;;
        sapphire_rapids) log_info "Xeon Sapphire Rapids CPU (spr)" >&2; echo "spr" ;;
        skylake)        log_info "Xeon SkyLake" >&2; echo "skl" ;;
        *)              log_error "Unsupported architecture: ${arch}" ;;
    esac
}

# Function: check_dir
# Purpose: Ensure a directory exists, creating it if necessary
# Arguments: $1 - Directory path
function check_dir() {
    local dir="$1"
    if [ -z "$dir" ]; then
        echo "Error: No directory path provided to check_dir"
        exit 1
    fi
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || {
            echo "Error: Failed to create directory $dir"
            exit 1
        }
    fi
}

# Function: check_file
# Purpose: Verify that a file exists
# Arguments: $1 - File path
function check_file() {
    local file="$1"
    if [ -z "$file" ]; then
        echo "Error: No file path provided to check_file"
        exit 1
    fi
    if [ ! -f "$file" ]; then
        echo "Error: File $file does not exist"
        exit 1
    fi
}

# Function: check_root
# Purpose: Ensure the script is run as root
function check_root() {
    local uid
    uid=$(id -u 2>/dev/null || echo "$EUID")
    if [ "$uid" != "0" ]; then
        echo "Error: This script must be run as root"
        exit 1
    fi
}
