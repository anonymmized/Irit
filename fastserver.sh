#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="Irit"
APP_TAGLINE="Fast VLESS + REALITY provisioning over SSH"
SCRIPT_NAME="${IRIT_ENTRYPOINT:-$(basename "$0")}"
SCRIPT_VERSION="0.7.0"

SSH_USER=""
SSH_HOST=""
SSH_PASSWORD=""
SUDO_PASSWORD=""
SSH_PORT="22"
IDENTITY_FILE=""

MODE="auto"
SELECTED_MODE=""
FORCE_SETUP=0
ASSUME_YES=0
NO_COLOR=0
DOWNLOAD_EXPORTS=1
COPY_URI=0
PRINT_QR=1

LISTEN_PORT="443"
API_PORT="10085"
DEST_TLS="www.cloudflare.com:443"
SERVER_NAMES=""
CLIENT_EMAIL="client-1@irit.local"
PUBLIC_HOST=""
REPORT_SAMPLE_SECONDS="2"
ARTIFACT_DIR=""
REMOTE_STATE_ROOT="/var/lib/irit-orchestrator"

LOCAL_TMP_DIR=""
LOCAL_HELPER_PATH=""
LOCAL_ENV_PATH=""
REMOTE_HELPER_PATH=""
REMOTE_ENV_PATH=""
LOCAL_ARTIFACT_DIR=""

REMOTE_IS_ROOT=0
REMOTE_SUDO_NEEDS_PASSWORD=0
BANNER_SHOWN=0

SSH_BASE_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=15
  -o ServerAliveInterval=20
  -o ServerAliveCountMax=3
)

COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""
COLOR_CYAN=""
COLOR_BOLD=""
COLOR_RESET=""

setup_colors() {
  if [[ "${NO_COLOR}" -eq 0 && -t 1 ]]; then
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_BLUE=$'\033[34m'
    COLOR_CYAN=$'\033[36m'
    COLOR_BOLD=$'\033[1m'
    COLOR_RESET=$'\033[0m'
  fi
}

log_plain() {
  printf '%b\n' "$1"
}

log_info() {
  log_plain "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_step() {
  log_plain "${COLOR_CYAN}[STEP]${COLOR_RESET} $*"
}

log_warn() {
  log_plain "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

log_error() {
  log_plain "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_success() {
  log_plain "${COLOR_GREEN}[OK]${COLOR_RESET} $*"
}

log_section() {
  log_plain ""
  log_plain "${COLOR_CYAN}${COLOR_BOLD}== $* ==${COLOR_RESET}"
}

die() {
  log_error "$*"
  exit 1
}

repeat_char() {
  local char="$1"
  local count="$2"
  local buffer
  printf -v buffer '%*s' "${count}" ''
  printf '%s' "${buffer// /${char}}"
}

render_box() {
  local title="$1"
  shift
  local width=74
  local inner_width=$((width - 4))
  local border
  border="+$(repeat_char "-" $((width - 2)))+"
  printf '%s\n' "${border}"
  printf '| %-*.*s |\n' "${inner_width}" "${inner_width}" "${title}"
  printf '%s\n' "${border}"
  local line
  for line in "$@"; do
    printf '| %-*.*s |\n' "${inner_width}" "${inner_width}" "${line}"
  done
  printf '%s\n' "${border}"
}

print_banner() {
  [[ "${BANNER_SHOWN}" -eq 0 ]] || return 0
  BANNER_SHOWN=1
  log_plain "${COLOR_CYAN}  ___      _ _   ${COLOR_RESET}"
  log_plain "${COLOR_CYAN} |_ _|_ __(_) |_ ${COLOR_RESET}"
  log_plain "${COLOR_CYAN}  | || '__| | __|${COLOR_RESET}"
  log_plain "${COLOR_CYAN}  | || |  | | |_ ${COLOR_RESET}"
  log_plain "${COLOR_CYAN} |___|_|  |_|\\__|${COLOR_RESET}"
  log_plain "${COLOR_BOLD}${APP_NAME}${COLOR_RESET} ${SCRIPT_VERSION}  ${APP_TAGLINE}"
  log_plain ""
}

usage() {
  cat <<EOF
${APP_NAME} ${SCRIPT_VERSION}

${APP_TAGLINE}

Entry point:
  bash ${SCRIPT_NAME}

Modes:
  auto         Detect the current server state and suggest the safest next action
  doctor       Inspect prerequisites, ports, bundle status and Xray health without changing the server
  setup        Install or fully replace Xray with an ${APP_NAME}-managed VLESS + REALITY config
  reconfigure  Rebuild an existing ${APP_NAME}-managed configuration
  report       Print a detailed report for the current server and Xray service
  access       Rebuild and print the saved VLESS access bundle
  rollback     Restore the latest checkpoint created by ${APP_NAME}

Connection options:
  --user USER
  --host HOST
  --password PASSWORD
  --sudo-password PASSWORD
  --identity-file PATH
  --port SSH_PORT

Deployment options:
  --listen-port PORT
  --api-port PORT
  --dest HOST:PORT
  --server-names CSV
  --client-email EMAIL
  --public-host HOST
  --sample-seconds N
  --artifact-dir DIR
  --state-root DIR
  --no-download
  --copy-uri
  --no-qr
  --force-setup
  --yes
  --no-color
  --version
  --help

Examples:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} --mode setup --user root --host 203.0.113.10 --password 'secret' --copy-uri
  bash ${SCRIPT_NAME} --mode access --user root --host 203.0.113.10 --identity-file ~/.ssh/id_ed25519
  bash ${SCRIPT_NAME} --mode doctor --user root --host 203.0.113.10 --identity-file ~/.ssh/id_ed25519

Local requirements:
  - bash, ssh, scp, tar, mktemp
  - sshpass (only when using password-based SSH)

Remote requirements:
  - Ubuntu or Debian
  - root or sudo
  - internet access for the official Xray installer
EOF
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

shell_quote() {
  printf '%q' "$1"
}

trim_spaces() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

prompt_value() {
  local prompt="$1"
  local default_value="${2:-}"
  local result=""
  if [[ -n "${default_value}" ]]; then
    read -r -p "${prompt} [${default_value}]: " result
    result="${result:-$default_value}"
  else
    read -r -p "${prompt}: " result
  fi
  printf '%s' "${result}"
}

sanitize_path_component() {
  local value="$1"
  value="$(printf '%s' "${value}" | tr -cs '[:alnum:]._-@' '_')"
  value="${value##_}"
  value="${value%%_}"
  printf '%s' "${value:-session}"
}

cleanup() {
  local rc=$?
  if [[ -n "${SSH_USER}" && -n "${SSH_HOST}" && -n "${REMOTE_HELPER_PATH}" ]]; then
    ssh_run "rm -f $(shell_quote "${REMOTE_HELPER_PATH}") $(shell_quote "${REMOTE_ENV_PATH}")" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LOCAL_TMP_DIR}" && -d "${LOCAL_TMP_DIR}" ]]; then
    rm -rf "${LOCAL_TMP_DIR}"
  fi
  exit "${rc}"
}

trap cleanup EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --user)
        SSH_USER="${2:-}"
        shift 2
        ;;
      --host)
        SSH_HOST="${2:-}"
        shift 2
        ;;
      --password)
        SSH_PASSWORD="${2:-}"
        shift 2
        ;;
      --sudo-password)
        SUDO_PASSWORD="${2:-}"
        shift 2
        ;;
      --identity-file|--ssh-key)
        IDENTITY_FILE="${2:-}"
        shift 2
        ;;
      --port)
        SSH_PORT="${2:-}"
        shift 2
        ;;
      --listen-port)
        LISTEN_PORT="${2:-}"
        shift 2
        ;;
      --api-port)
        API_PORT="${2:-}"
        shift 2
        ;;
      --dest)
        DEST_TLS="${2:-}"
        shift 2
        ;;
      --server-names)
        SERVER_NAMES="${2:-}"
        shift 2
        ;;
      --client-email)
        CLIENT_EMAIL="${2:-}"
        shift 2
        ;;
      --public-host)
        PUBLIC_HOST="${2:-}"
        shift 2
        ;;
      --sample-seconds)
        REPORT_SAMPLE_SECONDS="${2:-}"
        shift 2
        ;;
      --artifact-dir)
        ARTIFACT_DIR="${2:-}"
        shift 2
        ;;
      --state-root)
        REMOTE_STATE_ROOT="${2:-}"
        shift 2
        ;;
      --no-download)
        DOWNLOAD_EXPORTS=0
        shift
        ;;
      --copy-uri)
        COPY_URI=1
        shift
        ;;
      --no-qr)
        PRINT_QR=0
        shift
        ;;
      --force-setup)
        FORCE_SETUP=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --no-color)
        NO_COLOR=1
        shift
        ;;
      --version)
        printf '%s\n' "${SCRIPT_VERSION}"
        exit 0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

validate_integer() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be numeric"
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  validate_integer "${name}" "${value}"
  (( value > 0 )) || die "${name} must be greater than zero"
}

validate_port() {
  local name="$1"
  local value="$2"
  validate_positive_int "${name}" "${value}"
  (( value <= 65535 )) || die "${name} must be between 1 and 65535"
}

validate_mode() {
  case "${MODE}" in
    auto|doctor|setup|reconfigure|report|access|rollback) ;;
    *) die "Unsupported mode: ${MODE}" ;;
  esac
}

prompt_connection() {
  [[ -n "${SSH_USER}" ]] || SSH_USER="$(prompt_value "SSH user" "root")"
  [[ -n "${SSH_HOST}" ]] || SSH_HOST="$(prompt_value "Server IP or hostname")"

  if [[ -z "${IDENTITY_FILE}" && -z "${SSH_PASSWORD}" ]]; then
    read -r -s -p "SSH password: " SSH_PASSWORD
    printf '\n'
  fi

  validate_port "SSH port" "${SSH_PORT}"
  if [[ -n "${IDENTITY_FILE}" ]]; then
    [[ -r "${IDENTITY_FILE}" ]] || die "Identity file was not found or is not readable: ${IDENTITY_FILE}"
  fi
}

ensure_local_deps() {
  have_cmd ssh || die "ssh was not found"
  have_cmd scp || die "scp was not found"
  have_cmd tar || die "tar was not found"
  have_cmd mktemp || die "mktemp was not found"
  if [[ -z "${IDENTITY_FILE}" ]]; then
    have_cmd sshpass || die "sshpass was not found. Install it locally or use --identity-file."
  fi
}

ssh_cmd_base() {
  local -a cmd=(ssh -p "${SSH_PORT}" "${SSH_BASE_OPTS[@]}")
  if [[ -n "${IDENTITY_FILE}" ]]; then
    cmd+=(-i "${IDENTITY_FILE}")
    "${cmd[@]}" "$@"
  else
    SSHPASS="${SSH_PASSWORD}" sshpass -e "${cmd[@]}" "$@"
  fi
}

scp_cmd_base() {
  local -a cmd=(scp -P "${SSH_PORT}" "${SSH_BASE_OPTS[@]}")
  if [[ -n "${IDENTITY_FILE}" ]]; then
    cmd+=(-i "${IDENTITY_FILE}")
    "${cmd[@]}" "$@"
  else
    SSHPASS="${SSH_PASSWORD}" sshpass -e "${cmd[@]}" "$@"
  fi
}

ssh_run() {
  local remote_command="$1"
  ssh_cmd_base "${SSH_USER}@${SSH_HOST}" "${remote_command}"
}

ssh_tty_run() {
  local remote_command="$1"
  if [[ -n "${IDENTITY_FILE}" ]]; then
    ssh -tt -p "${SSH_PORT}" "${SSH_BASE_OPTS[@]}" -i "${IDENTITY_FILE}" "${SSH_USER}@${SSH_HOST}" "${remote_command}"
  else
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh -tt -p "${SSH_PORT}" "${SSH_BASE_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "${remote_command}"
  fi
}

scp_upload() {
  local src="$1"
  local dst="$2"
  scp_cmd_base "${src}" "${SSH_USER}@${SSH_HOST}:${dst}"
}

sudo_secret() {
  if [[ -n "${SUDO_PASSWORD}" ]]; then
    printf '%s' "${SUDO_PASSWORD}"
  else
    printf '%s' "${SSH_PASSWORD}"
  fi
}

build_root_wrapper() {
  local inner="$1"
  if [[ "${REMOTE_IS_ROOT}" -eq 1 ]]; then
    printf 'bash -lc %q' "${inner}"
    return
  fi

  if [[ "${REMOTE_SUDO_NEEDS_PASSWORD}" -eq 1 ]]; then
    printf "printf '%%s\\n' %q | sudo -S -p '' bash -lc %q" "$(sudo_secret)" "${inner}"
  else
    printf 'sudo -n bash -lc %q' "${inner}"
  fi
}

create_local_files() {
  LOCAL_TMP_DIR="$(mktemp -d)"
  LOCAL_HELPER_PATH="${LOCAL_TMP_DIR}/irit-remote-helper.sh"
  LOCAL_ENV_PATH="${LOCAL_TMP_DIR}/irit-remote.env"
  REMOTE_HELPER_PATH="/tmp/.irit-helper-$$.sh"
  REMOTE_ENV_PATH="/tmp/.irit-env-$$.env"
  write_remote_helper
}

sync_remote_helper() {
  scp_upload "${LOCAL_HELPER_PATH}" "${REMOTE_HELPER_PATH}"
  ssh_run "chmod 700 $(shell_quote "${REMOTE_HELPER_PATH}")"
}

write_env_line() {
  local key="$1"
  local value="$2"
  printf '%s=%q\n' "${key}" "${value}" >>"${LOCAL_ENV_PATH}"
}

write_remote_env() {
  : >"${LOCAL_ENV_PATH}"
  chmod 600 "${LOCAL_ENV_PATH}"
  write_env_line "IRIT_FORCE_COLOR" "$([[ "${NO_COLOR}" -eq 0 ]] && printf '1' || printf '0')"
  write_env_line "IRIT_APP_NAME" "${APP_NAME}"
  write_env_line "IRIT_APP_VERSION" "${SCRIPT_VERSION}"
  write_env_line "IRIT_REPORT_SAMPLE_SECONDS" "${REPORT_SAMPLE_SECONDS}"
  write_env_line "IRIT_PUBLIC_HOST" "${PUBLIC_HOST:-$SSH_HOST}"
  write_env_line "IRIT_LISTEN_PORT" "${LISTEN_PORT}"
  write_env_line "IRIT_API_PORT" "${API_PORT}"
  write_env_line "IRIT_DEST" "${DEST_TLS}"
  write_env_line "IRIT_SERVER_NAMES" "${SERVER_NAMES}"
  write_env_line "IRIT_CLIENT_EMAIL" "${CLIENT_EMAIL}"
  write_env_line "IRIT_STATE_ROOT" "${REMOTE_STATE_ROOT}"
  write_env_line "IRIT_ENABLE_QR" "$([[ "${PRINT_QR}" -eq 1 ]] && printf '1' || printf '0')"
  scp_upload "${LOCAL_ENV_PATH}" "${REMOTE_ENV_PATH}"
  ssh_run "chmod 600 $(shell_quote "${REMOTE_ENV_PATH}")"
}

detect_remote_privileges() {
  log_step "Checking root or sudo access on the server"
  local uid
  uid="$(ssh_run "id -u")"
  if [[ "${uid}" == "0" ]]; then
    REMOTE_IS_ROOT=1
    REMOTE_SUDO_NEEDS_PASSWORD=0
    log_success "Connected as root"
    return
  fi

  if ssh_run "sudo -n true" >/dev/null 2>&1; then
    REMOTE_SUDO_NEEDS_PASSWORD=0
    log_success "Passwordless sudo is available"
    return
  fi

  local secret
  secret="$(sudo_secret)"
  if [[ -z "${secret}" && "${ASSUME_YES}" -eq 0 ]]; then
    read -r -s -p "Remote sudo password: " SUDO_PASSWORD
    printf '\n'
    secret="$(sudo_secret)"
  fi

  if [[ -n "${secret}" ]] && ssh_run "printf '%s\n' $(shell_quote "${secret}") | sudo -S -p '' true" >/dev/null 2>&1; then
    REMOTE_SUDO_NEEDS_PASSWORD=1
    SUDO_PASSWORD="${secret}"
    log_success "Password-based sudo is available"
    return
  fi

  die "No root access and sudo did not work. Root or sudo is required."
}

run_remote_helper() {
  local action="$1"
  local with_tty="${2:-0}"
  local inner
  inner="set -a; . $(shell_quote "${REMOTE_ENV_PATH}"); set +a; $(shell_quote "${REMOTE_HELPER_PATH}") $(shell_quote "${action}")"
  local wrapped
  wrapped="$(build_root_wrapper "${inner}")"
  if [[ "${with_tty}" -eq 1 ]]; then
    ssh_tty_run "${wrapped}"
  else
    ssh_run "${wrapped}"
  fi
}

prompt_setup_options() {
  local default_server_name
  default_server_name="${SERVER_NAMES:-${DEST_TLS%%:*}}"
  [[ -n "${SERVER_NAMES}" ]] || SERVER_NAMES="${default_server_name}"
  [[ -n "${PUBLIC_HOST}" ]] || PUBLIC_HOST="${SSH_HOST}"

  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return
  fi

  LISTEN_PORT="$(prompt_value "VLESS/REALITY listen port" "${LISTEN_PORT}")"
  API_PORT="$(prompt_value "Local Xray API port" "${API_PORT}")"
  DEST_TLS="$(prompt_value "REALITY cover destination (host:port)" "${DEST_TLS}")"
  SERVER_NAMES="$(prompt_value "REALITY serverNames (CSV allowed)" "${SERVER_NAMES}")"
  CLIENT_EMAIL="$(prompt_value "Primary client label" "${CLIENT_EMAIL}")"
  PUBLIC_HOST="$(prompt_value "Public host for the client URI" "${PUBLIC_HOST}")"
}

validate_setup_values() {
  validate_port "listen-port" "${LISTEN_PORT}"
  validate_port "api-port" "${API_PORT}"
  validate_positive_int "sample-seconds" "${REPORT_SAMPLE_SECONDS}"
  [[ "${LISTEN_PORT}" != "${API_PORT}" ]] || die "--listen-port and --api-port must be different"
  [[ "${DEST_TLS}" == *:* ]] || die "--dest must use the form host:port"
  [[ -n "${SERVER_NAMES}" ]] || die "--server-names must not be empty"
  [[ -n "${CLIENT_EMAIL}" ]] || die "--client-email must not be empty"
  [[ -n "${PUBLIC_HOST}" ]] || die "--public-host must not be empty"
}

print_connection_summary() {
  local auth_line="password"
  if [[ -n "${IDENTITY_FILE}" ]]; then
    auth_line="ssh key (${IDENTITY_FILE})"
  fi
  render_box "Connection" \
    "Target      ${SSH_USER}@${SSH_HOST}:${SSH_PORT}" \
    "Auth        ${auth_line}" \
    "Mode        ${MODE}" \
    "State root  ${REMOTE_STATE_ROOT}"
}

print_setup_summary() {
  render_box "Deployment Plan" \
    "Action      ${SELECTED_MODE}" \
    "Listen port ${LISTEN_PORT}" \
    "API port    ${API_PORT}" \
    "Dest        ${DEST_TLS}" \
    "Names       ${SERVER_NAMES}" \
    "Client      ${CLIENT_EMAIL}" \
    "Public host ${PUBLIC_HOST}"
}

confirm_step() {
  local prompt="$1"
  [[ "${ASSUME_YES}" -eq 1 ]] && return 0
  local answer
  read -r -p "${prompt} [Y/n]: " answer
  answer="$(trim_spaces "${answer}")"
  case "${answer:-Y}" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    *) die "Unknown answer: ${answer}" ;;
  esac
}

probe_remote_state() {
  log_step "Detecting remote server state" >&2
  local probe_output
  probe_output="$(run_remote_helper probe 0)"
  local key value
  local xray_present="0"
  while IFS='=' read -r key value; do
    case "${key}" in
      xray_present) xray_present="${value}" ;;
      *) : ;;
    esac
  done <<<"${probe_output}"
  if [[ "${xray_present}" == "1" ]]; then
    log_info "Xray is already present on the server" >&2
  else
    log_info "Xray was not found, the server looks fresh" >&2
  fi
  printf '%s' "${probe_output}"
}

resolve_mode() {
  local probe_output="$1"
  local xray_present="0"
  local managed="0"
  local key value
  while IFS='=' read -r key value; do
    case "${key}" in
      xray_present) xray_present="${value}" ;;
      managed) managed="${value}" ;;
      *) : ;;
    esac
  done <<<"${probe_output}"
  case "${MODE}" in
    doctor|setup|reconfigure|report|access|rollback)
      SELECTED_MODE="${MODE}"
      ;;
    auto)
      if [[ "${xray_present}" == "0" ]]; then
        SELECTED_MODE="setup"
        return
      fi
      if [[ "${FORCE_SETUP}" -eq 1 ]]; then
        SELECTED_MODE="reconfigure"
        return
      fi
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        SELECTED_MODE="report"
        return
      fi
      log_warn "Xray already exists on the server."
      if [[ "${managed}" == "1" ]]; then
        log_info "An ${APP_NAME}-managed configuration was detected."
      fi
      local answer
      read -r -p "Choose action: [r]eport / [a]ccess / [d]octor / [c]onfigure / [b]ack rollback / [q]uit (default: r): " answer
      answer="$(trim_spaces "${answer}")"
      case "${answer:-r}" in
        r|R) SELECTED_MODE="report" ;;
        a|A) SELECTED_MODE="access" ;;
        d|D) SELECTED_MODE="doctor" ;;
        c|C) SELECTED_MODE="reconfigure" ;;
        b|B) SELECTED_MODE="rollback" ;;
        q|Q) die "Operation aborted by user" ;;
        *) die "Unknown choice: ${answer}" ;;
      esac
      ;;
  esac
}

prepare_local_artifact_dir() {
  [[ -n "${LOCAL_ARTIFACT_DIR}" ]] && return 0
  local root="${ARTIFACT_DIR:-${PWD}/artifacts}"
  local stamp host_tag
  stamp="$(date +%Y%m%d-%H%M%S)"
  host_tag="$(sanitize_path_component "${SSH_HOST:-server}")"
  LOCAL_ARTIFACT_DIR="${root}/${host_tag}-${stamp}"
  mkdir -p "${LOCAL_ARTIFACT_DIR}"
}

remote_exports_available() {
  local wrapped
  wrapped="$(build_root_wrapper "[[ -d $(shell_quote "${REMOTE_STATE_ROOT}/exports") && -f $(shell_quote "${REMOTE_STATE_ROOT}/exports/client-access.txt") ]]")"
  ssh_run "${wrapped}" >/dev/null 2>&1
}

write_local_session_note() {
  prepare_local_artifact_dir
  cat >"${LOCAL_ARTIFACT_DIR}/session.txt" <<EOF
${APP_NAME} session
Timestamp: $(date -Is)
Server: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}
Mode: ${SELECTED_MODE}
Remote state root: ${REMOTE_STATE_ROOT}
EOF
}

find_local_uri_file() {
  [[ -n "${LOCAL_ARTIFACT_DIR}" ]] || return 1
  if [[ -f "${LOCAL_ARTIFACT_DIR}/vless-uri.txt" ]]; then
    printf '%s' "${LOCAL_ARTIFACT_DIR}/vless-uri.txt"
    return 0
  fi
  if [[ -f "${LOCAL_ARTIFACT_DIR}/client-access.txt" ]]; then
    printf '%s' "${LOCAL_ARTIFACT_DIR}/client-access.txt"
    return 0
  fi
  return 1
}

read_local_uri() {
  local uri_file
  uri_file="$(find_local_uri_file)" || return 1
  if [[ "${uri_file}" == *"/vless-uri.txt" ]]; then
    head -n 1 "${uri_file}"
    return 0
  fi
  awk '/^VLESS URI:/{getline; print; exit}' "${uri_file}"
}

copy_uri_to_clipboard() {
  local uri="$1"
  if have_cmd pbcopy; then
    printf '%s' "${uri}" | pbcopy
  elif have_cmd wl-copy; then
    printf '%s' "${uri}" | wl-copy
  elif have_cmd xclip; then
    printf '%s' "${uri}" | xclip -selection clipboard
  else
    log_warn "Clipboard copy was requested, but pbcopy, wl-copy or xclip was not found."
    return 1
  fi
  log_success "The VLESS URI was copied to the clipboard"
}

maybe_copy_uri_from_bundle() {
  [[ "${COPY_URI}" -eq 1 ]] || return 0
  local uri
  uri="$(read_local_uri 2>/dev/null || true)"
  [[ -n "${uri}" ]] || {
    log_warn "The local bundle does not contain a readable VLESS URI."
    return 0
  }
  copy_uri_to_clipboard "${uri}" || true
}

download_remote_exports() {
  if [[ "${DOWNLOAD_EXPORTS}" -eq 0 && "${COPY_URI}" -eq 0 ]]; then
    return 0
  fi
  if ! remote_exports_available; then
    log_warn "The remote client bundle is not available yet."
    return 0
  fi
  prepare_local_artifact_dir
  log_step "Downloading the client bundle to ${LOCAL_ARTIFACT_DIR}"
  local wrapped
  wrapped="$(build_root_wrapper "tar -C $(shell_quote "${REMOTE_STATE_ROOT}/exports") -cf - .")"
  if ssh_run "${wrapped}" | tar -xf - -C "${LOCAL_ARTIFACT_DIR}"; then
    write_local_session_note
    log_success "Local client bundle saved"
    local file
    while IFS= read -r file; do
      [[ -n "${file}" ]] || continue
      log_plain "  ${LOCAL_ARTIFACT_DIR}/${file}"
    done < <(find "${LOCAL_ARTIFACT_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort)
    maybe_copy_uri_from_bundle
  else
    log_warn "Failed to download the client bundle from the server."
  fi
}

setup_or_reconfigure() {
  prompt_setup_options
  validate_setup_values
  print_setup_summary
  confirm_step "Apply this configuration to ${SSH_HOST}" || die "Operation aborted by user"
  write_remote_env

  local attempt=1
  local max_attempts=2
  while [[ "${attempt}" -le "${max_attempts}" ]]; do
    if [[ "${SELECTED_MODE}" == "reconfigure" ]]; then
      log_step "Starting server reconfiguration, attempt ${attempt}/${max_attempts}"
      if run_remote_helper reconfigure 1; then
        log_success "Reconfiguration completed"
        run_remote_helper report 1 || true
        download_remote_exports
        return
      fi
    else
      log_step "Starting server setup, attempt ${attempt}/${max_attempts}"
      if run_remote_helper setup 1; then
        log_success "Setup completed"
        run_remote_helper report 1 || true
        download_remote_exports
        return
      fi
    fi
    log_warn "The remote step failed."
    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      log_warn "Trying rollback to the latest checkpoint and retrying."
      run_remote_helper rollback 1 || log_warn "Rollback did not complete cleanly."
    fi
    attempt=$((attempt + 1))
  done
  log_warn "The retry failed again. Running a final rollback."
  run_remote_helper rollback 1 || true
  die "Setup or reconfiguration did not finish successfully."
}

run_doctor() {
  write_remote_env
  log_step "Running server diagnostics"
  run_remote_helper doctor 1
}

run_report() {
  write_remote_env
  log_step "Building a detailed report for the server"
  run_remote_helper report 1
  download_remote_exports
}

run_access() {
  write_remote_env
  log_step "Refreshing the client access bundle"
  run_remote_helper access 1
  download_remote_exports
}

run_rollback() {
  write_remote_env
  log_step "Rolling back to the latest checkpoint"
  run_remote_helper rollback 1
}

main() {
  parse_args "$@"
  setup_colors
  validate_mode
  print_banner
  prompt_connection
  ensure_local_deps
  print_connection_summary
  create_local_files
  sync_remote_helper
  detect_remote_privileges
  write_remote_env

  local probe_output
  probe_output="$(probe_remote_state)"
  resolve_mode "${probe_output}"
  log_info "Selected mode: ${SELECTED_MODE}"

  case "${SELECTED_MODE}" in
    doctor)
      run_doctor
      ;;
    setup|reconfigure)
      setup_or_reconfigure
      ;;
    report)
      run_report
      ;;
    access)
      run_access
      ;;
    rollback)
      run_rollback
      ;;
    *)
      die "Internal mode selection error: ${SELECTED_MODE}"
      ;;
  esac
}

write_remote_helper() {
  cat >"${LOCAL_HELPER_PATH}" <<'REMOTE_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="${IRIT_APP_NAME:-Irit}"
APP_VERSION="${IRIT_APP_VERSION:-unknown}"
ACTION="${1:-}"

STATE_ROOT="${IRIT_STATE_ROOT:-/var/lib/irit-orchestrator}"
CHECKPOINT_ROOT="${STATE_ROOT}/checkpoints"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_META="/usr/local/etc/xray/irit-meta.env"
XRAY_EXPORT_DIR="${STATE_ROOT}/exports"
XRAY_SERVICE="xray"
MANAGED_SYSCTL="/etc/sysctl.d/99-irit-xray.conf"
REPORT_SAMPLE_SECONDS="${IRIT_REPORT_SAMPLE_SECONDS:-2}"
ENABLE_QR="${IRIT_ENABLE_QR:-1}"

COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""
COLOR_CYAN=""
COLOR_BOLD=""
COLOR_RESET=""

setup_colors() {
  if [[ "${IRIT_FORCE_COLOR:-0}" == "1" || -t 1 ]]; then
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_BLUE=$'\033[34m'
    COLOR_CYAN=$'\033[36m'
    COLOR_BOLD=$'\033[1m'
    COLOR_RESET=$'\033[0m'
  fi
}

log_line() { printf '%b\n' "$1"; }
log_info() { log_line "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_step() { log_line "${COLOR_CYAN}[STEP]${COLOR_RESET} $*"; }
log_warn() { log_line "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_error() { log_line "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }
log_success() { log_line "${COLOR_GREEN}[OK]${COLOR_RESET} $*"; }
log_section() { log_line ""; log_line "${COLOR_CYAN}${COLOR_BOLD}== $* ==${COLOR_RESET}"; }

paint_status() {
  local status="${1:-unknown}"
  case "${status}" in
    active|enabled|running|ok|connected|yes|present|managed|ready|available|free)
      printf '%b' "${COLOR_GREEN}${status}${COLOR_RESET}"
      ;;
    inactive|failed|dead|disabled|error|missing|no|in-use)
      printf '%b' "${COLOR_RED}${status}${COLOR_RESET}"
      ;;
    *)
      printf '%b' "${COLOR_YELLOW}${status}${COLOR_RESET}"
      ;;
  esac
}

die() { log_error "$*"; exit 1; }
require_root() { [[ "$(id -u)" == "0" ]] || die "This step must run as root"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
cmd_flag() { if "$@" >/dev/null 2>&1; then printf '1'; else printf '0'; fi; }

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "${value}"
}

trim_spaces() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

human_bytes() {
  local bytes="${1:-0}"
  if have_cmd numfmt; then
    numfmt --to=iec-i --suffix=B "${bytes}" 2>/dev/null || printf '%sB' "${bytes}"
  else
    printf '%sB' "${bytes}"
  fi
}

human_rate() { local value="${1:-0}"; printf '%s/s' "$(human_bytes "${value}")"; }

urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe='-._~'))
PY
}

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release was not found"
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Only Ubuntu or Debian are supported. Detected: ${ID:-unknown}" ;;
  esac
}

service_exists() { systemctl cat "${XRAY_SERVICE}" >/dev/null 2>&1; }
xray_present() { [[ -x "${XRAY_BIN}" ]]; }
service_is_active() { systemctl is-active --quiet "${XRAY_SERVICE}"; }
service_is_enabled() { systemctl is-enabled --quiet "${XRAY_SERVICE}"; }
detect_default_iface() { ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; ++i) if ($i=="dev") {print $(i+1); exit}}'; }

get_service_user() {
  local service_user
  service_user="$(systemctl cat "${XRAY_SERVICE}" 2>/dev/null | awk -F= '/^User=/{print $2; exit}')"
  if [[ -z "${service_user}" ]]; then printf 'root'; else printf '%s' "${service_user}"; fi
}

get_service_group() {
  local user
  user="$(get_service_user)"
  id -gn "${user}" 2>/dev/null || printf '%s' "${user}"
}

ensure_base_packages() {
  log_step "Installing base packages on the server"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates coreutils curl iproute2 jq lsof net-tools openssl procps python3 qrencode tar unzip
}

ensure_xray_installed() {
  if xray_present && service_exists; then
    log_info "Xray is already installed, skipping installation"
    return
  fi
  log_step "Installing Xray with the official install-release.sh"
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

ensure_xray_paths() {
  local user group
  user="$(get_service_user)"
  group="$(get_service_group)"
  install -d -m 750 -o "${user}" -g "${group}" /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log
  chown "${user}:${group}" /var/log/xray/access.log /var/log/xray/error.log
  install -d -m 750 /usr/local/etc/xray
  install -d -m 700 "${STATE_ROOT}" "${CHECKPOINT_ROOT}" "${XRAY_EXPORT_DIR}"
}

backup_item() {
  local checkpoint_dir="$1"
  local src="$2"
  [[ -e "${src}" ]] || return 0
  local parent="${checkpoint_dir}/files$(dirname "${src}")"
  mkdir -p "${parent}"
  cp -a "${src}" "${parent}/"
}

set_checkpoint_kv() {
  local checkpoint_dir="$1" key="$2" value="$3" meta="${checkpoint_dir}/meta.env"
  if grep -q "^${key}=" "${meta}" 2>/dev/null; then
    sed -i "s#^${key}=.*#${key}=$(printf '%q' "${value}")#" "${meta}"
  else
    printf '%s=%q\n' "${key}" "${value}" >>"${meta}"
  fi
}

create_checkpoint() {
  require_root
  mkdir -p "${CHECKPOINT_ROOT}"
  local name checkpoint_dir
  name="$(date +%Y%m%d-%H%M%S)"
  checkpoint_dir="${CHECKPOINT_ROOT}/${name}"
  mkdir -p "${checkpoint_dir}/files"
  {
    printf 'CHECKPOINT_CREATED_AT=%q\n' "$(date -Is)"
    printf 'XRAY_WAS_PRESENT=%q\n' "$([[ -x "${XRAY_BIN}" ]] && printf '1' || printf '0')"
    printf 'XRAY_SERVICE_WAS_ACTIVE=%q\n' "$(cmd_flag service_is_active)"
    printf 'XRAY_SERVICE_WAS_ENABLED=%q\n' "$(cmd_flag service_is_enabled)"
    printf 'UFW_RULE_ADDED=%q\n' "0"
  } >"${checkpoint_dir}/meta.env"
  backup_item "${checkpoint_dir}" /usr/local/etc/xray
  backup_item "${checkpoint_dir}" /etc/systemd/system/xray.service
  backup_item "${checkpoint_dir}" /etc/systemd/system/xray@.service
  backup_item "${checkpoint_dir}" "${MANAGED_SYSCTL}"
  backup_item "${checkpoint_dir}" "${XRAY_EXPORT_DIR}"
  ln -sfn "${checkpoint_dir}" "${CHECKPOINT_ROOT}/latest"
  printf '%s' "${checkpoint_dir}"
}

remove_managed_ufw_rule() {
  have_cmd ufw || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  local line
  while read -r line; do
    [[ -n "${line}" ]] || continue
    ufw --force delete "${line}" >/dev/null 2>&1 || true
  done < <(ufw status numbered 2>/dev/null | awk '/irit-xray/ {gsub(/\[|\]/, "", $1); print $1}' | sort -rn)
}

restore_item_or_remove() {
  local checkpoint_dir="$1" path="$2" backup="${checkpoint_dir}/files${path}"
  rm -rf "${path}" 2>/dev/null || true
  if [[ -e "${backup}" ]]; then
    mkdir -p "$(dirname "${path}")"
    cp -a "${backup}" "$(dirname "${path}")/"
  fi
}

rollback_latest() {
  require_root
  local checkpoint_dir="${CHECKPOINT_ROOT}/latest"
  [[ -e "${checkpoint_dir}" ]] || die "Latest checkpoint was not found"
  [[ -f "${checkpoint_dir}/meta.env" ]] || die "Checkpoint meta.env is missing"
  # shellcheck disable=SC1090
  . "${checkpoint_dir}/meta.env"

  log_step "Rolling the server back to the latest checkpoint"
  [[ -n "${CHECKPOINT_CREATED_AT:-}" ]] && log_info "Checkpoint timestamp: ${CHECKPOINT_CREATED_AT}"
  systemctl stop "${XRAY_SERVICE}" >/dev/null 2>&1 || true

  if [[ "${XRAY_WAS_PRESENT:-0}" == "0" ]]; then
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    restore_item_or_remove "${checkpoint_dir}" /usr/local/etc/xray
    restore_item_or_remove "${checkpoint_dir}" /etc/systemd/system/xray.service
    restore_item_or_remove "${checkpoint_dir}" /etc/systemd/system/xray@.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  restore_item_or_remove "${checkpoint_dir}" "${MANAGED_SYSCTL}"
  restore_item_or_remove "${checkpoint_dir}" "${XRAY_EXPORT_DIR}"
  if [[ -f "${MANAGED_SYSCTL}" ]]; then
    sysctl -p "${MANAGED_SYSCTL}" >/dev/null 2>&1 || true
  fi
  if [[ "${UFW_RULE_ADDED:-0}" == "1" ]]; then
    remove_managed_ufw_rule
  fi
  if [[ "${XRAY_SERVICE_WAS_ENABLED:-0}" == "1" && "${XRAY_WAS_PRESENT:-0}" == "1" ]]; then
    systemctl enable "${XRAY_SERVICE}" >/dev/null 2>&1 || true
  else
    systemctl disable "${XRAY_SERVICE}" >/dev/null 2>&1 || true
  fi
  if [[ "${XRAY_SERVICE_WAS_ACTIVE:-0}" == "1" && "${XRAY_WAS_PRESENT:-0}" == "1" ]]; then
    systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
  else
    systemctl stop "${XRAY_SERVICE}" >/dev/null 2>&1 || true
  fi
  log_success "Rollback completed"
}

generate_uuid() {
  if [[ -n "${UUID_OVERRIDE:-}" ]]; then printf '%s' "${UUID_OVERRIDE}"; return; fi
  "${XRAY_BIN}" uuid
}

generate_x25519_keys() {
  local output
  output="$("${XRAY_BIN}" x25519)"
  PRIVATE_KEY="$(printf '%s\n' "${output}" | awk -F': ' '/Private key/ {print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "${output}" | awk -F': ' '/Public key/ {print $2; exit}')"
  [[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]] || die "Failed to generate x25519 keys"
}

load_existing_managed_metadata() { if [[ -f "${XRAY_META}" ]]; then . "${XRAY_META}"; fi; }

hydrate_managed_values_from_meta() {
  load_existing_managed_metadata
  [[ -f "${XRAY_META}" ]] || die "${APP_NAME} metadata was not found on the server"
  UUID_VALUE="${UUID:-}"
  PRIVATE_KEY="${PRIVATE_KEY:-}"
  PUBLIC_KEY="${PUBLIC_KEY:-}"
  SHORT_ID="${SHORT_ID:-}"
  IRIT_CLIENT_EMAIL="${CLIENT_EMAIL:-${IRIT_CLIENT_EMAIL:-}}"
  IRIT_SERVER_NAMES="${SERVER_NAMES:-${IRIT_SERVER_NAMES:-}}"
  IRIT_DEST="${DEST:-${IRIT_DEST:-}}"
  IRIT_LISTEN_PORT="${LISTEN_PORT:-${IRIT_LISTEN_PORT:-}}"
  IRIT_API_PORT="${API_PORT:-${IRIT_API_PORT:-}}"
  IRIT_PUBLIC_HOST="${PUBLIC_HOST:-${IRIT_PUBLIC_HOST:-}}"
  [[ -n "${UUID_VALUE}" && -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" && -n "${SHORT_ID}" && -n "${IRIT_SERVER_NAMES}" && -n "${IRIT_CLIENT_EMAIL}" && -n "${IRIT_PUBLIC_HOST}" ]] || die "Managed metadata is incomplete"
}

primary_server_name() {
  local name="${IRIT_SERVER_NAMES%%,*}"
  trim_spaces "${name}"
}

build_client_uri() {
  local primary encoded_sni encoded_key encoded_sid encoded_label
  primary="$(primary_server_name)"
  encoded_sni="$(urlencode "${primary}")"
  encoded_key="$(urlencode "${PUBLIC_KEY}")"
  encoded_sid="$(urlencode "${SHORT_ID}")"
  encoded_label="$(urlencode "${IRIT_CLIENT_EMAIL}")"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "${UUID_VALUE}" "${IRIT_PUBLIC_HOST}" "${IRIT_LISTEN_PORT}" "${encoded_sni}" "${encoded_key}" "${encoded_sid}" "${encoded_label}"
}

csv_to_json_array() {
  local csv="$1" result="" item trimmed escaped oldifs="${IFS}"
  IFS=','
  set -f
  for item in ${csv}; do
    trimmed="$(trim_spaces "${item}")"
    [[ -n "${trimmed}" ]] || continue
    escaped="$(json_escape "${trimmed}")"
    if [[ -n "${result}" ]]; then result="${result}, "; fi
    result="${result}\"${escaped}\""
  done
  set +f
  IFS="${oldifs}"
  [[ -n "${result}" ]] || result="\"$(json_escape "${csv}")\""
  printf '[%s]' "${result}"
}

write_sysctl_profile() {
  cat >"${MANAGED_SYSCTL}" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
EOF
  sysctl -p "${MANAGED_SYSCTL}" >/dev/null 2>&1 || log_warn "Failed to apply the BBR sysctl profile immediately, continuing"
}

configure_firewall() {
  local checkpoint_dir="$1"
  have_cmd ufw || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  if ufw status 2>/dev/null | grep -E -q "^${IRIT_LISTEN_PORT}/tcp[[:space:]]+ALLOW"; then
    log_info "UFW already allows ${IRIT_LISTEN_PORT}/tcp"
    return
  fi
  log_step "Opening ${IRIT_LISTEN_PORT}/tcp in UFW"
  ufw allow "${IRIT_LISTEN_PORT}/tcp" comment 'irit-xray' >/dev/null 2>&1 || log_warn "Failed to add the UFW rule"
  set_checkpoint_kv "${checkpoint_dir}" "UFW_RULE_ADDED" "1"
}

show_port_listener() {
  local port="$1"
  lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print "  " $1 " (pid " $2 "): " $9}'
}

warn_if_port_busy() {
  local port="$1" label="$2"
  local listeners
  listeners="$(show_port_listener "${port}" || true)"
  if [[ -n "${listeners}" ]]; then
    log_warn "${label} port ${port} already has listeners:"
    printf '%s\n' "${listeners}"
  fi
}

port_status_text() {
  local port="$1"
  if ss -ltn "( sport = :${port} )" 2>/dev/null | awk 'NR>1 {found=1} END {exit(found?0:1)}'; then
    printf 'in-use'
  else
    printf 'free'
  fi
}

discover_xray_execstart() { systemctl cat "${XRAY_SERVICE}" 2>/dev/null | awk -F= '/^ExecStart=/{print substr($0, 11); exit}'; }

discover_xray_config_spec() {
  local exec_line mode path
  exec_line="$(discover_xray_execstart)"
  if [[ -n "${exec_line}" ]]; then
    set -- ${exec_line}
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -config|-c) mode="config"; path="${2:-}"; shift 2 ;;
        -config=*|-c=*) mode="config"; path="${1#*=}"; shift ;;
        -confdir) mode="confdir"; path="${2:-}"; shift 2 ;;
        -confdir=*) mode="confdir"; path="${1#*=}"; shift ;;
        *) shift ;;
      esac
    done
  fi
  if [[ -n "${mode:-}" && -n "${path:-}" ]]; then printf '%s::%s' "${mode}" "${path}"; return; fi
  if [[ -f "${XRAY_CONFIG}" ]]; then printf 'config::%s' "${XRAY_CONFIG}"; return; fi
  if [[ -d /usr/local/etc/xray ]]; then printf 'confdir::%s' "/usr/local/etc/xray"; return; fi
  if [[ -f /etc/xray/config.json ]]; then printf 'config::%s' "/etc/xray/config.json"; return; fi
  return 1
}

dump_xray_config_to() {
  local out_file="$1" spec mode path
  spec="$(discover_xray_config_spec)" || return 1
  mode="${spec%%::*}"
  path="${spec#*::}"
  if [[ "${mode}" == "confdir" ]]; then
    "${XRAY_BIN}" run -dump -confdir "${path}" >"${out_file}" 2>/dev/null
  else
    "${XRAY_BIN}" run -dump -c "${path}" >"${out_file}" 2>/dev/null
  fi
}

extract_report_facts() {
  local config_file="$1"
  python3 - "${config_file}" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], 'r'))
listen_port = ""
dest = ""
server_names = []
api_port = ""
users = []
for inbound in cfg.get("inbounds", []):
    proto = inbound.get("protocol", "")
    if proto == "vless" and not listen_port:
        listen_port = str(inbound.get("port", ""))
        reality = inbound.get("streamSettings", {}).get("realitySettings", {})
        dest = reality.get("dest", "")
        server_names = reality.get("serverNames", []) or []
        for client in inbound.get("settings", {}).get("clients", []):
            users.append({
                "email": client.get("email", ""),
                "id": client.get("id", ""),
                "flow": client.get("flow", "")
            })
    if inbound.get("tag") == "api" and not api_port:
        api_port = str(inbound.get("port", ""))
print(f"listen_port={listen_port}")
print(f"dest={dest}")
print(f"server_names={','.join(server_names)}")
print(f"api_port={api_port}")
for user in users:
    email = user["email"].replace("\t", " ")
    uuid = user["id"].replace("\t", " ")
    flow = user["flow"].replace("\t", " ")
    print(f"user={email}\t{uuid}\t{flow}")
PY
}

stats_snapshot_to_tsv() {
  local api_port="$1" snapshot_file
  snapshot_file="$(mktemp)"
  if ! "${XRAY_BIN}" api statsquery --server="127.0.0.1:${api_port}" >"${snapshot_file}" 2>/dev/null; then
    rm -f "${snapshot_file}"
    return 1
  fi
  if ! python3 - "${snapshot_file}" <<'PY'; then
import json, sys
try:
    data = json.load(open(sys.argv[1], 'r'))
except Exception:
    sys.exit(1)
stats = {}
for item in data.get("stat", []):
    name = item.get("name", "")
    if not name.startswith("user>>>"):
        continue
    parts = name.split(">>>")
    if len(parts) < 4:
        continue
    email = parts[1]
    direction = parts[3]
    stats.setdefault(email, {"uplink": 0, "downlink": 0})
    stats[email][direction] = int(item.get("value", "0"))
for email in sorted(stats):
    print(f"{email}\t{stats[email]['uplink']}\t{stats[email]['downlink']}")
PY
    rm -f "${snapshot_file}"
    return 1
  fi
  rm -f "${snapshot_file}"
}

sample_iface_rate() {
  local iface="$1" seconds="$2" rx1 tx1 rx2 tx2
  [[ -n "${iface}" ]] || return 1
  [[ -r "/sys/class/net/${iface}/statistics/rx_bytes" ]] || return 1
  rx1="$(cat "/sys/class/net/${iface}/statistics/rx_bytes")"
  tx1="$(cat "/sys/class/net/${iface}/statistics/tx_bytes")"
  sleep "${seconds}"
  rx2="$(cat "/sys/class/net/${iface}/statistics/rx_bytes")"
  tx2="$(cat "/sys/class/net/${iface}/statistics/tx_bytes")"
  printf '%s\t%s\n' "$(((rx2 - rx1) / seconds))" "$(((tx2 - tx1) / seconds))"
}

build_user_speed_report() {
  local api_port="$1" seconds="$2" first second
  first="$(mktemp)"
  second="$(mktemp)"
  if ! stats_snapshot_to_tsv "${api_port}" >"${first}"; then rm -f "${first}" "${second}"; return 1; fi
  sleep "${seconds}"
  if ! stats_snapshot_to_tsv "${api_port}" >"${second}"; then rm -f "${first}" "${second}"; return 1; fi
  awk -F'\t' -v seconds="${seconds}" '
    FNR==NR { up[$1]=$2; down[$1]=$3; next }
    {
      du=$2-up[$1]; dd=$3-down[$1]
      if (du < 0) du=0
      if (dd < 0) dd=0
      print $1 "\t" $2 "\t" $3 "\t" int(du/seconds) "\t" int(dd/seconds)
      seen[$1]=1
    }
    END {
      for (key in up) {
        if (!(key in seen)) {
          print key "\t" up[key] "\t" down[key] "\t0\t0"
        }
      }
    }
  ' "${first}" "${second}"
  rm -f "${first}" "${second}"
}

active_client_ips() { local port="$1"; ss -Htn state established 2>/dev/null | awk -v port=":"port '$4 ~ port"$" {print $5}' | sort | uniq -c | sort -nr; }

checkpoint_count() {
  if [[ -d "${CHECKPOINT_ROOT}" ]]; then
    find "${CHECKPOINT_ROOT}" -mindepth 1 -maxdepth 1 -type d ! -name latest | wc -l | awk '{print $1}'
  else
    printf '0'
  fi
}

show_recent_checkpoints() {
  local found=0
  if [[ -d "${CHECKPOINT_ROOT}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      log_line "- ${line}"
      found=1
    done < <(find "${CHECKPOINT_ROOT}" -mindepth 1 -maxdepth 1 -type d ! -name latest -printf '%f\n' 2>/dev/null | sort | tail -n 5)
  fi
  if [[ "${found}" -eq 0 ]]; then log_line "No checkpoints found"; fi
}

write_meta_file() {
  local uri="$1"
  cat >"${XRAY_META}" <<EOF
IRIT_MANAGED=1
APP_NAME=$(printf '%q' "${APP_NAME}")
APP_VERSION=$(printf '%q' "${APP_VERSION}")
GENERATED_AT=$(printf '%q' "$(date -Is)")
UUID=$(printf '%q' "${UUID_VALUE}")
PRIVATE_KEY=$(printf '%q' "${PRIVATE_KEY}")
PUBLIC_KEY=$(printf '%q' "${PUBLIC_KEY}")
SHORT_ID=$(printf '%q' "${SHORT_ID}")
CLIENT_EMAIL=$(printf '%q' "${IRIT_CLIENT_EMAIL}")
SERVER_NAMES=$(printf '%q' "${IRIT_SERVER_NAMES}")
DEST=$(printf '%q' "${IRIT_DEST}")
LISTEN_PORT=$(printf '%q' "${IRIT_LISTEN_PORT}")
API_PORT=$(printf '%q' "${IRIT_API_PORT}")
PUBLIC_HOST=$(printf '%q' "${IRIT_PUBLIC_HOST}")
CLIENT_URI=$(printf '%q' "${uri}")
EOF
  chmod 600 "${XRAY_META}"
}

write_qr_files() {
  local uri="$1"
  if [[ "${ENABLE_QR}" != "1" || ! -d "${XRAY_EXPORT_DIR}" ]]; then return 0; fi
  if ! have_cmd qrencode; then return 0; fi
  qrencode -t UTF8 "${uri}" >"${XRAY_EXPORT_DIR}/vless-uri-qr.txt" 2>/dev/null || true
  qrencode -t SVG -o "${XRAY_EXPORT_DIR}/vless-uri-qr.svg" "${uri}" 2>/dev/null || true
  qrencode -o "${XRAY_EXPORT_DIR}/vless-uri-qr.png" -s 8 -m 2 "${uri}" 2>/dev/null || true
  chmod 600 "${XRAY_EXPORT_DIR}/vless-uri-qr.txt" "${XRAY_EXPORT_DIR}/vless-uri-qr.svg" "${XRAY_EXPORT_DIR}/vless-uri-qr.png" 2>/dev/null || true
}

write_mihomo_profile() {
  local file="$1" primary
  primary="$(primary_server_name)"
  cat >"${file}" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

proxies:
  - name: "Irit VLESS"
    type: vless
    server: ${IRIT_PUBLIC_HOST}
    port: ${IRIT_LISTEN_PORT}
    uuid: ${UUID_VALUE}
    network: tcp
    tls: true
    udp: true
    servername: ${primary}
    flow: xtls-rprx-vision
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "Irit VLESS"

rules:
  - MATCH,Proxy
EOF
}

write_singbox_profile() {
  local file="$1" primary
  primary="$(primary_server_name)"
  cat >"${file}" <<EOF
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "irit-vless",
      "server": "$(json_escape "${IRIT_PUBLIC_HOST}")",
      "server_port": ${IRIT_LISTEN_PORT},
      "uuid": "$(json_escape "${UUID_VALUE}")",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$(json_escape "${primary}")",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$(json_escape "${PUBLIC_KEY}")",
          "short_id": "$(json_escape "${SHORT_ID}")"
        }
      }
    }
  ]
}
EOF
}

write_manifest_json() {
  local file="$1" uri="$2" qr_txt="0" qr_svg="0" qr_png="0"
  [[ -f "${XRAY_EXPORT_DIR}/vless-uri-qr.txt" ]] && qr_txt="1"
  [[ -f "${XRAY_EXPORT_DIR}/vless-uri-qr.svg" ]] && qr_svg="1"
  [[ -f "${XRAY_EXPORT_DIR}/vless-uri-qr.png" ]] && qr_png="1"
  cat >"${file}" <<EOF
{
  "app": "$(json_escape "${APP_NAME}")",
  "version": "$(json_escape "${APP_VERSION}")",
  "generatedAt": "$(json_escape "$(date -Is)")",
  "publicHost": "$(json_escape "${IRIT_PUBLIC_HOST}")",
  "listenPort": ${IRIT_LISTEN_PORT},
  "apiPort": ${IRIT_API_PORT},
  "destination": "$(json_escape "${IRIT_DEST}")",
  "serverNames": $(csv_to_json_array "${IRIT_SERVER_NAMES}"),
  "clientEmail": "$(json_escape "${IRIT_CLIENT_EMAIL}")",
  "uuid": "$(json_escape "${UUID_VALUE}")",
  "publicKey": "$(json_escape "${PUBLIC_KEY}")",
  "shortId": "$(json_escape "${SHORT_ID}")",
  "vlessUri": "$(json_escape "${uri}")",
  "qr": {
    "text": ${qr_txt},
    "svg": ${qr_svg},
    "png": ${qr_png}
  }
}
EOF
}

write_client_exports() {
  local quiet="${1:-0}"
  install -d -m 700 "${XRAY_EXPORT_DIR}"
  local uri primary
  primary="$(primary_server_name)"
  uri="$(build_client_uri)"
  write_meta_file "${uri}"
  printf '%s\n' "${uri}" >"${XRAY_EXPORT_DIR}/vless-uri.txt"

  cat >"${XRAY_EXPORT_DIR}/client-template.json" <<EOF
{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${IRIT_PUBLIC_HOST}",
            "port": ${IRIT_LISTEN_PORT},
            "users": [
              {
                "id": "${UUID_VALUE}",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "${primary}",
          "publicKey": "${PUBLIC_KEY}",
          "shortId": "${SHORT_ID}",
          "spiderX": "/"
        }
      }
    }
  ]
}
EOF

  write_singbox_profile "${XRAY_EXPORT_DIR}/sing-box-client.json"
  write_mihomo_profile "${XRAY_EXPORT_DIR}/mihomo-profile.yaml"

  {
    printf 'Application: %s\n' "${APP_NAME}"
    printf 'Version: %s\n' "${APP_VERSION}"
    printf 'Generated at: %s\n' "$(date -Is)"
    printf 'Public host: %s\n' "${IRIT_PUBLIC_HOST}"
    printf 'Listen port: %s\n' "${IRIT_LISTEN_PORT}"
    printf 'REALITY destination: %s\n' "${IRIT_DEST}"
    printf 'Server name: %s\n' "${primary}"
    printf 'Client label: %s\n' "${IRIT_CLIENT_EMAIL}"
    printf 'UUID: %s\n' "${UUID_VALUE}"
    printf 'Public key: %s\n' "${PUBLIC_KEY}"
    printf 'Short ID: %s\n' "${SHORT_ID}"
    printf '\nVLESS URI:\n%s\n' "${uri}"
  } >"${XRAY_EXPORT_DIR}/connection-summary.txt"

  {
    printf 'Irit access bundle\n'
    printf 'Server: %s\n' "${IRIT_PUBLIC_HOST}"
    printf 'Port: %s\n' "${IRIT_LISTEN_PORT}"
    printf 'Client label: %s\n' "${IRIT_CLIENT_EMAIL}"
    printf '\nVLESS URI:\n%s\n' "${uri}"
    printf '\nFiles:\n'
    printf '  %s\n' "${XRAY_EXPORT_DIR}/vless-uri.txt"
    printf '  %s\n' "${XRAY_EXPORT_DIR}/client-template.json"
    printf '  %s\n' "${XRAY_EXPORT_DIR}/sing-box-client.json"
    printf '  %s\n' "${XRAY_EXPORT_DIR}/mihomo-profile.yaml"
    printf '  %s\n' "${XRAY_EXPORT_DIR}/manifest.json"
  } >"${XRAY_EXPORT_DIR}/client-access.txt"

  {
    printf 'Quick import hints\n'
    printf '- Xray clients: use client-template.json\n'
    printf '- sing-box: use sing-box-client.json\n'
    printf '- Mihomo/Clash Meta: use mihomo-profile.yaml\n'
    printf '- Direct URI import: use vless-uri.txt\n'
  } >"${XRAY_EXPORT_DIR}/import-hints.txt"

  write_qr_files "${uri}"
  write_manifest_json "${XRAY_EXPORT_DIR}/manifest.json" "${uri}"
  chmod 600 \
    "${XRAY_EXPORT_DIR}/vless-uri.txt" \
    "${XRAY_EXPORT_DIR}/client-template.json" \
    "${XRAY_EXPORT_DIR}/sing-box-client.json" \
    "${XRAY_EXPORT_DIR}/mihomo-profile.yaml" \
    "${XRAY_EXPORT_DIR}/manifest.json" \
    "${XRAY_EXPORT_DIR}/connection-summary.txt" \
    "${XRAY_EXPORT_DIR}/client-access.txt" \
    "${XRAY_EXPORT_DIR}/import-hints.txt" 2>/dev/null || true

  if [[ "${quiet}" -eq 0 ]]; then
    log_success "Client access data was saved:"
    local file
    while IFS= read -r file; do
      [[ -n "${file}" ]] || continue
      log_line "  ${XRAY_EXPORT_DIR}/${file}"
    done < <(find "${XRAY_EXPORT_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort)
    log_line "  ${uri}"
  fi
}

print_terminal_qr() {
  if [[ "${ENABLE_QR}" == "1" && -t 1 && -f "${XRAY_EXPORT_DIR}/vless-uri-qr.txt" ]]; then
    log_section "QR"
    sed 's/^/  /' "${XRAY_EXPORT_DIR}/vless-uri-qr.txt"
  fi
}

print_access_summary() {
  local uri="$1" primary
  primary="$(primary_server_name)"
  log_section "Client Access"
  log_line "Managed by ${APP_NAME}: $(paint_status managed)"
  log_line "Public host: ${IRIT_PUBLIC_HOST}"
  log_line "Listen port: ${IRIT_LISTEN_PORT}"
  log_line "Server name: ${primary}"
  log_line "Client label: ${IRIT_CLIENT_EMAIL}"
  log_line "Public key: ${PUBLIC_KEY}"
  log_line "Short ID: ${SHORT_ID}"
  log_line "Export dir: ${XRAY_EXPORT_DIR}"
  log_line "VLESS URI:"
  log_line "${uri}"
  print_terminal_qr
}

render_xray_config() {
  local tmp_file="$1" server_names_json
  server_names_json="$(csv_to_json_array "${IRIT_SERVER_NAMES}")"
  cat >"${tmp_file}" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "api": {
    "tag": "api",
    "services": [
      "StatsService",
      "LoggerService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${IRIT_LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(json_escape "${UUID_VALUE}")",
            "email": "$(json_escape "${IRIT_CLIENT_EMAIL}")",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$(json_escape "${IRIT_DEST}")",
          "xver": 0,
          "serverNames": ${server_names_json},
          "privateKey": "$(json_escape "${PRIVATE_KEY}")",
          "shortIds": [
            "$(json_escape "${SHORT_ID}")"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    },
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": ${IRIT_API_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
    {
      "tag": "api",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      }
    ]
  }
}
EOF
}

doctor_server() {
  local hostname os_name kernel xray_state xray_enabled managed
  hostname="$(hostname -f 2>/dev/null || hostname)"
  os_name="$(. /etc/os-release && printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}")"
  kernel="$(uname -r)"
  managed="$([[ -f "${XRAY_META}" ]] && printf 'managed' || printf 'no')"
  xray_state="$([[ -x "${XRAY_BIN}" ]] && printf 'present' || printf 'missing')"
  xray_enabled="$(systemctl is-enabled "${XRAY_SERVICE}" 2>/dev/null || printf 'unknown')"

  log_section "${APP_NAME} Doctor"
  log_line "Host: ${hostname}"
  log_line "OS: ${os_name}"
  log_line "Kernel: ${kernel}"
  log_line "Managed metadata: $(paint_status "${managed}")"

  log_section "Toolchain"
  local tool
  for tool in curl jq openssl python3 qrencode ss lsof tar; do
    if have_cmd "${tool}"; then log_line "- ${tool}: $(paint_status present)"; else log_line "- ${tool}: $(paint_status missing)"; fi
  done

  log_section "Xray"
  log_line "Binary: $(paint_status "${xray_state}")"
  if xray_present; then log_line "Version: $("${XRAY_BIN}" version 2>/dev/null | head -n 1 || printf 'unknown')"; fi
  log_line "Service active: $(paint_status "$(systemctl is-active "${XRAY_SERVICE}" 2>/dev/null || printf 'unknown')")"
  log_line "Service enabled: $(paint_status "${xray_enabled}")"

  log_section "Desired Ports"
  log_line "Client port ${IRIT_LISTEN_PORT}: $(paint_status "$(port_status_text "${IRIT_LISTEN_PORT}")")"
  log_line "API port ${IRIT_API_PORT}: $(paint_status "$(port_status_text "${IRIT_API_PORT}")")"

  local dest_host="${IRIT_DEST%%:*}"
  log_section "DNS"
  if getent ahosts "${dest_host}" >/dev/null 2>&1; then
    log_line "Destination host ${dest_host}: $(paint_status ready)"
  else
    log_line "Destination host ${dest_host}: $(paint_status missing)"
  fi

  log_section "State"
  log_line "Checkpoint count: $(checkpoint_count)"
  log_line "Exports dir: $([[ -d "${XRAY_EXPORT_DIR}" ]] && printf '%s' "$(paint_status available)" || printf '%s' "$(paint_status missing)")"
  if [[ -d "${XRAY_EXPORT_DIR}" ]]; then
    local file
    while IFS= read -r file; do
      [[ -n "${file}" ]] || continue
      log_line "- ${file}"
    done < <(find "${XRAY_EXPORT_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort)
  fi
}

report_server() {
  local hostname os_name kernel uptime_text iface rate rx_rate tx_rate
  local xray_version active_status enabled_status
  local report_file listen_port="" dest="" server_names="" api_port=""
  local users_present=0 line managed="0" managed_uri=""

  hostname="$(hostname -f 2>/dev/null || hostname)"
  os_name="$(. /etc/os-release && printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}")"
  kernel="$(uname -r)"
  uptime_text="$(uptime -p 2>/dev/null || true)"
  iface="$(detect_default_iface)"

  log_section "${APP_NAME} Report"
  log_line "Host: ${hostname}"
  log_line "OS: ${os_name}"
  log_line "Kernel: ${kernel}"
  log_line "Uptime: ${uptime_text:-unknown}"
  log_line "Load: $(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"
  log_line "Memory: $(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}')"
  log_line "Disk /: $(df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " used (" $5 ")"}')"
  if [[ -n "${iface}" ]]; then
    log_step "Sampling interface throughput for ${REPORT_SAMPLE_SECONDS}s"
    rate="$(sample_iface_rate "${iface}" "${REPORT_SAMPLE_SECONDS}" 2>/dev/null || true)"
    rx_rate="$(printf '%s\n' "${rate}" | awk -F'\t' 'NR==1 {print $1}')"
    tx_rate="$(printf '%s\n' "${rate}" | awk -F'\t' 'NR==1 {print $2}')"
    if [[ -n "${rx_rate}" && -n "${tx_rate}" ]]; then
      log_line "Network ${iface}: RX $(human_rate "${rx_rate}") | TX $(human_rate "${tx_rate}")"
    else
      log_line "Network ${iface}: throughput sample unavailable"
    fi
  fi

  log_section "Irit State"
  log_line "State root: ${STATE_ROOT}"
  log_line "Checkpoint count: $(checkpoint_count)"
  log_line "Recent checkpoints:"
  show_recent_checkpoints

  if ! xray_present || ! service_exists; then
    log_section "Xray"
    log_line "Status: $(paint_status missing)"
    return 0
  fi

  xray_version="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || true)"
  active_status="$(systemctl is-active "${XRAY_SERVICE}" 2>/dev/null || true)"
  enabled_status="$(systemctl is-enabled "${XRAY_SERVICE}" 2>/dev/null || true)"
  log_section "Xray"
  log_line "Version: ${xray_version:-unknown}"
  log_line "Service state: $(paint_status "${active_status:-unknown}") / $(paint_status "${enabled_status:-unknown}")"

  report_file="$(mktemp)"
  log_step "Inspecting the merged Xray configuration"
  if dump_xray_config_to "${report_file}"; then
    while IFS= read -r line; do
      case "${line}" in
        listen_port=*) listen_port="${line#*=}" ;;
        dest=*) dest="${line#*=}" ;;
        server_names=*) server_names="${line#*=}" ;;
        api_port=*) api_port="${line#*=}" ;;
        user=*) users_present=1 ;;
      esac
    done < <(extract_report_facts "${report_file}")
    log_line "Listen port: ${listen_port:-unknown}"
    log_line "REALITY destination: ${dest:-unknown}"
    log_line "REALITY serverNames: ${server_names:-unknown}"
    log_line "Stats API: 127.0.0.1:${api_port:-unknown}"
  else
    log_warn "Failed to read the merged Xray configuration"
  fi

  if [[ -f "${XRAY_META}" ]]; then
    managed="1"
    hydrate_managed_values_from_meta
    write_client_exports 1
    managed_uri="$(build_client_uri)"
    log_section "Managed Access"
    log_line "Managed by ${APP_NAME}: $(paint_status managed)"
    log_line "Client label: ${IRIT_CLIENT_EMAIL}"
    log_line "Public host: ${IRIT_PUBLIC_HOST}"
    log_line "Export dir: ${XRAY_EXPORT_DIR}"
    log_line "VLESS URI:"
    log_line "${managed_uri}"
  fi

  log_section "Ports"
  log_line "Desired client port ${IRIT_LISTEN_PORT}: $(paint_status "$(port_status_text "${IRIT_LISTEN_PORT}")")"
  log_line "Desired API port ${IRIT_API_PORT}: $(paint_status "$(port_status_text "${IRIT_API_PORT}")")"

  if [[ -n "${listen_port}" ]]; then
    log_section "Active Client Connections"
    local active_ips
    active_ips="$(active_client_ips "${listen_port}" || true)"
    if [[ -n "${active_ips}" ]]; then
      printf '%s\n' "${active_ips}"
    else
      log_line "No active TCP sessions on port ${listen_port}"
    fi
  fi

  if [[ "${users_present}" -eq 1 ]]; then
    log_section "Configured Users"
    while IFS= read -r line; do
      [[ "${line}" == user=* ]] || continue
      local payload email uuid flow
      payload="${line#user=}"
      email="$(printf '%s' "${payload}" | awk -F'\t' '{print $1}')"
      uuid="$(printf '%s' "${payload}" | awk -F'\t' '{print $2}')"
      flow="$(printf '%s' "${payload}" | awk -F'\t' '{print $3}')"
      log_line "- ${email:-no-email} | ${uuid:-no-uuid} | ${flow:-no-flow}"
    done < <(extract_report_facts "${report_file}")
  fi

  if [[ -n "${api_port}" ]]; then
    log_section "User Traffic"
    log_step "Sampling per-user throughput for ${REPORT_SAMPLE_SECONDS}s"
    if build_user_speed_report "${api_port}" "${REPORT_SAMPLE_SECONDS}" >"${report_file}.stats" 2>/dev/null; then
      local any_active=0
      while IFS=$'\t' read -r email up down up_rate down_rate; do
        [[ -n "${email}" ]] || continue
        local total rate_total
        total=$((up + down))
        rate_total=$((up_rate + down_rate))
        if [[ "${rate_total}" -gt 0 ]]; then
          log_line "${COLOR_GREEN}- ${email}: total $(human_bytes "${total}") | up $(human_bytes "${up}") | down $(human_bytes "${down}") | speed $(human_rate "${rate_total}")${COLOR_RESET}"
          any_active=1
        else
          log_line "${COLOR_YELLOW}- ${email}: total $(human_bytes "${total}") | up $(human_bytes "${up}") | down $(human_bytes "${down}") | speed $(human_rate "${rate_total}")${COLOR_RESET}"
        fi
      done <"${report_file}.stats"
      if [[ "${any_active}" -eq 0 ]]; then
        log_line "No active users were detected in the current stats delta"
      fi
    else
      log_line "User traffic stats are unavailable: the API did not answer or client emails are missing"
    fi
  fi

  log_section "SSH Sessions"
  who 2>/dev/null || log_line "No active SSH session list available"

  log_section "Recent Xray Warnings"
  journalctl -u "${XRAY_SERVICE}" -n 20 --no-pager -p warning..alert 2>/dev/null || log_line "No warnings found or the journal is unavailable"

  rm -f "${report_file}" "${report_file}.stats"
  if [[ "${managed}" == "0" ]]; then
    log_warn "This server is not managed by ${APP_NAME}, so no saved VLESS bundle was found."
  fi
}

access_server() {
  hydrate_managed_values_from_meta
  write_client_exports 0
  print_access_summary "$(build_client_uri)"
}

setup_server() {
  require_root
  detect_os
  ensure_base_packages
  warn_if_port_busy "${IRIT_LISTEN_PORT}" "VLESS inbound"
  warn_if_port_busy "${IRIT_API_PORT}" "Xray API"
  local checkpoint_dir tmp_config group
  checkpoint_dir="$(create_checkpoint)"
  log_info "Created checkpoint: ${checkpoint_dir}"

  ensure_xray_installed
  ensure_xray_paths
  load_existing_managed_metadata

  UUID_VALUE="${UUID:-}"
  SHORT_ID="${SHORT_ID:-}"
  PUBLIC_KEY="${PUBLIC_KEY:-}"
  PRIVATE_KEY="${PRIVATE_KEY:-}"
  [[ -n "${UUID_VALUE}" ]] || UUID_VALUE="$(generate_uuid)"
  [[ -n "${SHORT_ID}" ]] || SHORT_ID="$(openssl rand -hex 8)"
  if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
    generate_x25519_keys
  fi

  tmp_config="$(mktemp)"
  render_xray_config "${tmp_config}"
  "${XRAY_BIN}" run -test -config "${tmp_config}"

  group="$(get_service_group)"
  install -d -m 750 -o root -g "${group}" /usr/local/etc/xray
  install -m 640 -o root -g "${group}" "${tmp_config}" "${XRAY_CONFIG}"
  rm -f "${tmp_config}"

  write_sysctl_profile
  configure_firewall "${checkpoint_dir}"
  systemctl daemon-reload
  systemctl enable "${XRAY_SERVICE}"
  systemctl restart "${XRAY_SERVICE}"
  sleep 2
  service_is_active || die "The xray service did not start after restart"
  if ! ss -ltn "( sport = :${IRIT_LISTEN_PORT} )" 2>/dev/null | awk 'NR>1 {found=1} END {exit(found?0:1)}'; then
    die "Xray started, but no listener was detected on port ${IRIT_LISTEN_PORT}"
  fi
  write_client_exports 0
  print_access_summary "$(build_client_uri)"
  log_success "Server setup finished"
}

probe_server() {
  local managed="0"
  [[ -f "${XRAY_META}" ]] && managed="1"
  printf 'os_id=%s\n' "$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
  printf 'xray_present=%s\n' "$([[ -x "${XRAY_BIN}" ]] && printf '1' || printf '0')"
  printf 'service_active=%s\n' "$(cmd_flag service_is_active)"
  printf 'managed=%s\n' "${managed}"
}

main() {
  setup_colors
  case "${ACTION}" in
    probe) probe_server ;;
    doctor) doctor_server ;;
    setup|reconfigure) setup_server ;;
    report) report_server ;;
    access) access_server ;;
    rollback) rollback_latest ;;
    *) die "Unsupported action: ${ACTION}" ;;
  esac
}

main "$@"
REMOTE_HELPER
  chmod 700 "${LOCAL_HELPER_PATH}"
}

main "$@"
