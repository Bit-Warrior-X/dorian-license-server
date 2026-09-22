#!/usr/bin/env bash
# Run on the target server from the directory that contains the uploaded artifacts
# (license.tar.gz, deploy.sh, dorian-ddos-firewall-*.tar.gz).
# GeoIP is NOT uploaded via SCP — deploy.sh downloads it from
# http://192.142.44.204/geodb/dbip-full-2026-02.mmdb.tar.gz (override with GEODB_DOWNLOAD_URL).
#
# Usage:
#   ./deploy.sh [--all | --license-only | --version-only]
#
# Default: --all
#   --all            Extract dorian, license, GeoIP; then angelos venv + systemd units
#   --license-only   Extract only license.tar.gz to /usr/local/share/dorian/
#                    (no GeoIP, no dorian tarball, no venv, no systemd — extract only)
#   --version-only   Extract only dorian-ddos-firewall-*.tar.gz; then venv + systemd units
#
# Targets:
#   dorian-ddos-firewall-*.tar.gz  -> /usr/local/share/dorian/
#   license.tar.gz                 -> /usr/local/share/dorian/
#   GeoIP (downloaded)             -> /usr/local/share/dorian/athens/nginx/lua/geoip2
#
# After a dorian payload extract (--all or --version-only):
#   - Install athens-luajit.conf to /etc/ld.so.conf.d/ and run ldconfig
#   - Python venv under /usr/local/share/dorian/angelos/venv + pip install -r requirements.txt
#   - Install systemd units to /etc/systemd/system/, daemon-reload, enable + restart:
#       angelos.service, athens.service, sparta.service
#   Requires sudo (or run as root) for /etc/systemd/system and venv under /usr/local/share/dorian.
#
# On success, if this script lives under /tmp/dorian_deploy_* (deploy_license staging), that directory
# is removed so upgrades do not accumulate multiple tarballs and /tmp stays tidy.

set -euo pipefail

# Persist deploy traces on the target for later analysis (also echoed to stdout for SSH capture).
# Prefer /var/dorian/logs so logs survive staging-dir cleanup under /tmp/dorian_deploy_*.
DEPLOY_LOG_DIR="${DEPLOY_LOG_DIR:-/var/dorian/logs}"
DEPLOY_RUN_ID="${DEPLOY_RUN_ID:-$(date -u +"%Y%m%dT%H%M%SZ")-$$}"
DEPLOY_LOG_FILE="${DEPLOY_LOG_FILE:-}"

_ensure_deploy_log() {
  if [[ -n "${DEPLOY_LOG_FILE}" ]]; then
    return 0
  fi
  if mkdir -p "${DEPLOY_LOG_DIR}" 2>/dev/null && touch "${DEPLOY_LOG_DIR}/.write_test" 2>/dev/null; then
    rm -f "${DEPLOY_LOG_DIR}/.write_test" 2>/dev/null || true
    DEPLOY_LOG_FILE="${DEPLOY_LOG_DIR}/deploy-${DEPLOY_RUN_ID}.log"
  else
    # Fallback outside staging when possible
    if mkdir -p /var/dorian/logs 2>/dev/null; then
      DEPLOY_LOG_FILE="/var/dorian/logs/deploy-${DEPLOY_RUN_ID}.log"
    elif mkdir -p /tmp/dorian-deploy-logs 2>/dev/null; then
      DEPLOY_LOG_FILE="/tmp/dorian-deploy-logs/deploy-${DEPLOY_RUN_ID}.log"
    else
      DEPLOY_LOG_FILE="${SCRIPT_DIR}/deploy-${DEPLOY_RUN_ID}.log"
    fi
  fi
  : > "${DEPLOY_LOG_FILE}" || true
}

# Structured key=value log line (human + machine greppable).
log_msg() {
  local ts component msg
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  component="${LOG_COMPONENT:-deploy.sh}"
  msg="$*"
  _ensure_deploy_log
  local line="ts=${ts} component=${component} run_id=${DEPLOY_RUN_ID} pid=$$ ${msg}"
  echo "[${ts}] deploy.sh[pid=$$]: ${msg}"
  echo "${line}" >> "${DEPLOY_LOG_FILE}" 2>/dev/null || true
}

log_kv() {
  # usage: log_kv event=phase_start phase=extract_geodb key=value ...
  log_msg "$*"
}

phase_start() {
  local name="$1"
  shift || true
  PHASE_NAME="${name}"
  PHASE_T0="$(date +%s)"
  log_kv "event=phase_start phase=${name} $*"
}

phase_end() {
  local name="${1:-${PHASE_NAME:-unknown}}"
  local status="${2:-ok}"
  local t0="${PHASE_T0:-$(date +%s)}"
  local now duration
  now="$(date +%s)"
  duration=$((now - t0))
  log_kv "event=phase_end phase=${name} status=${status} duration_sec=${duration}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DORIAN_ROOT="/usr/local/share/dorian"
GEODB_DIR="${DORIAN_ROOT}/athens/nginx/lua/geoip2"
ANGELOS_DIR="${DORIAN_ROOT}/angelos"
ANGELOS_VENV="${ANGELOS_DIR}/venv"

LICENSE_TAR="${SCRIPT_DIR}/license.tar.gz"
GEODB_TAR="${SCRIPT_DIR}/dbip-full-2026-02.mmdb.tar.gz"
# Targets download GeoIP from the control-plane mirror (not SCP'd with other artifacts).
GEODB_DOWNLOAD_URL="${GEODB_DOWNLOAD_URL:-http://192.142.44.204/geodb/dbip-full-2026-02.mmdb.tar.gz}"
# When set to 1, skip download/extract here (license-server installs GeoIP in background).
GEODB_DEFER="${GEODB_DEFER:-0}"

usage() {
  echo "Usage: $(basename "$0") [--all | --license-only | --version-only]" >&2
  echo "  --all (default)   full extract + angelos venv + systemd enable" >&2
  echo "  --license-only    only unpack license.tar.gz (no venv, no systemd)" >&2
  echo "  --version-only    only unpack dorian tarball + venv + systemd" >&2
}

fail() {
  log_kv "event=error status=fail message=$(printf '%q' "$*")"
  phase_end "${PHASE_NAME:-main}" "fail" || true
  echo "error: $*" >&2
  exit 1
}

maybe_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

setup_angelos_venv() {
  phase_start "angelos_venv"
  [[ -d "${ANGELOS_DIR}" ]] || fail "missing angelos directory: ${ANGELOS_DIR}"
  [[ -f "${ANGELOS_DIR}/requirements.txt" ]] || fail "missing ${ANGELOS_DIR}/requirements.txt"

  if [[ ! -d "${ANGELOS_VENV}" ]]; then
    maybe_sudo python3 -m venv "${ANGELOS_VENV}"
    log_kv "event=venv_created path=${ANGELOS_VENV}"
  else
    log_kv "event=venv_reuse path=${ANGELOS_VENV}"
  fi

  maybe_sudo "${ANGELOS_VENV}/bin/python" -m pip install --upgrade pip
  maybe_sudo "${ANGELOS_VENV}/bin/pip" install -r "${ANGELOS_DIR}/requirements.txt"
  log_kv "event=pip_install_ok requirements=${ANGELOS_DIR}/requirements.txt"
  phase_end "angelos_venv" "ok"
}

setup_athens_ldconfig() {
  phase_start "athens_ldconfig"
  local conf_src="${DORIAN_ROOT}/athens/athens-luajit.conf"
  local conf_dest="/etc/ld.so.conf.d/athens-luajit.conf"
  [[ -f "${conf_src}" ]] || fail "missing athens ld config: ${conf_src}"
  maybe_sudo install -m 644 "${conf_src}" "${conf_dest}"
  maybe_sudo ldconfig
  log_kv "event=ldconfig_ok conf=${conf_dest}"
  phase_end "athens_ldconfig" "ok"
}

install_systemd_units() {
  phase_start "systemd_units"
  local -a units=(
    "${DORIAN_ROOT}/angelos/angelos.service"
    "${DORIAN_ROOT}/athens/athens.service"
    "${DORIAN_ROOT}/sparta/service/sparta.service"
  )
  local u dest_name
  for u in "${units[@]}"; do
    [[ -f "${u}" ]] || fail "missing unit file: ${u}"
    dest_name="$(basename "${u}")"
    maybe_sudo install -m 644 "${u}" "/etc/systemd/system/${dest_name}"
    log_kv "event=unit_installed unit=${dest_name}"
  done

  maybe_sudo systemctl daemon-reload

  # enable for boot; restart so package updates stop old processes and load new binaries
  for dest_name in angelos.service athens.service sparta.service; do
    maybe_sudo systemctl enable "${dest_name}"
    log_kv "event=unit_enable_ok unit=${dest_name}"
    maybe_sudo systemctl restart "${dest_name}"
    log_kv "event=unit_restart_ok unit=${dest_name} active=$(maybe_sudo systemctl is-active "${dest_name}" 2>/dev/null || echo unknown)"
  done
  phase_end "systemd_units" "ok"
}

post_install_after_dorian_extract() {
  setup_athens_ldconfig
  setup_angelos_venv
  install_systemd_units
}

# deploy_license uploads to /tmp/dorian_deploy_<token>/; remove it after artifacts are installed.
cleanup_remote_staging_dir() {
  case "${SCRIPT_DIR}" in
    /tmp/dorian_deploy_*)
      log_msg "removing staging directory ${SCRIPT_DIR}"
      if ! ( cd / && rm -rf -- "${SCRIPT_DIR}" ); then
        log_msg "warning: could not remove staging directory ${SCRIPT_DIR}"
      fi
      ;;
  esac
}

# $1: when "newest" and multiple tarballs exist (reused upgrade staging dir), pick newest mtime instead of failing.
find_dorian_tarball() {
  local ambiguous_policy="${1:-strict}"
  shopt -s nullglob
  local -a candidates=( "${SCRIPT_DIR}"/dorian-ddos-firewall-*.tar.gz )
  shopt -u nullglob
  if ((${#candidates[@]} == 0)); then
    echo "error: no dorian-ddos-firewall-*.tar.gz found in ${SCRIPT_DIR}" >&2
    return 1
  fi
  if ((${#candidates[@]} > 1)); then
    if [[ "${ambiguous_policy}" != "newest" ]]; then
      echo "error: expected exactly one dorian-ddos-firewall-*.tar.gz in ${SCRIPT_DIR}, found ${#candidates[@]}" >&2
      return 1
    fi
    local best="${candidates[0]}"
    local best_time=0
    local c t
    for c in "${candidates[@]}"; do
      t=$(stat -c '%Y' "$c" 2>/dev/null) || t=0
      if (( t > best_time )); then
        best_time=$t
        best=$c
      elif (( t == best_time )) && [[ "$(basename "$c")" > "$(basename "$best")" ]]; then
        best=$c
      fi
    done
    printf '%s' "${best}"
    return 0
  fi
  printf '%s' "${candidates[0]}"
}

extract_dorian_version() {
  phase_start "extract_dorian"
  local tar_path
  local ambiguous_policy="strict"
  if [[ "${DEPLOY_MODE}" == "version" ]]; then
    ambiguous_policy="newest"
  fi
  if ! tar_path="$(find_dorian_tarball "${ambiguous_policy}")"; then
    fail "dorian tarball resolution failed"
  fi
  [[ -f "$tar_path" ]] || fail "missing dorian tarball: ${tar_path}"
  local bytes
  bytes="$(stat -c '%s' "${tar_path}" 2>/dev/null || echo 0)"
  log_kv "event=extract_start archive=$(basename "${tar_path}") bytes=${bytes} dest=${DORIAN_ROOT}"
  mkdir -p "${DORIAN_ROOT}"
  tar -xzf "${tar_path}" -C "${DORIAN_ROOT}"
  log_kv "event=extract_ok archive=$(basename "${tar_path}") dest=${DORIAN_ROOT}"
  phase_end "extract_dorian" "ok"
}

extract_license() {
  phase_start "extract_license"
  [[ -f "${LICENSE_TAR}" ]] || fail "missing ${LICENSE_TAR}"
  local bytes
  bytes="$(stat -c '%s' "${LICENSE_TAR}" 2>/dev/null || echo 0)"
  log_kv "event=extract_start archive=$(basename "${LICENSE_TAR}") bytes=${bytes} dest=${DORIAN_ROOT}"
  mkdir -p "${DORIAN_ROOT}"
  tar -xzf "${LICENSE_TAR}" -C "${DORIAN_ROOT}"
  log_kv "event=extract_ok archive=$(basename "${LICENSE_TAR}") dest=${DORIAN_ROOT}"
  phase_end "extract_license" "ok"
}

extract_geodb() {
  phase_start "extract_geodb"
  mkdir -p "${GEODB_DIR}"
  # Soft-skip when MMDB already installed (avoids re-downloading ~480MB).
  if compgen -G "${GEODB_DIR}/*.mmdb" > /dev/null; then
    local count
    count="$(find "${GEODB_DIR}" -type f -name '*.mmdb' 2>/dev/null | wc -l | tr -d ' ')"
    log_kv "event=geodb_skip reason=already_present mmdb_count=${count} dir=${GEODB_DIR}"
    phase_end "extract_geodb" "skipped"
    return 0
  fi
  if [[ "${GEODB_DEFER}" == "1" ]]; then
    log_kv "event=geodb_skip reason=deferred url=${GEODB_DOWNLOAD_URL}"
    phase_end "extract_geodb" "deferred"
    return 0
  fi
  if [[ ! -f "${GEODB_TAR}" ]]; then
    log_kv "event=geodb_download_start url=${GEODB_DOWNLOAD_URL} dest=${GEODB_TAR}"
    local dl_t0 dl_t1 dl_sec
    dl_t0="$(date +%s)"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 20 --retry 3 -o "${GEODB_TAR}" "${GEODB_DOWNLOAD_URL}"
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "${GEODB_TAR}" "${GEODB_DOWNLOAD_URL}"
    else
      fail "missing ${GEODB_TAR} and neither curl nor wget is available to fetch ${GEODB_DOWNLOAD_URL}"
    fi
    dl_t1="$(date +%s)"
    dl_sec=$((dl_t1 - dl_t0))
    local bytes
    bytes="$(stat -c '%s' "${GEODB_TAR}" 2>/dev/null || echo 0)"
    log_kv "event=geodb_download_ok bytes=${bytes} duration_sec=${dl_sec} url=${GEODB_DOWNLOAD_URL}"
  else
    local bytes
    bytes="$(stat -c '%s' "${GEODB_TAR}" 2>/dev/null || echo 0)"
    log_kv "event=geodb_local_archive bytes=${bytes} path=${GEODB_TAR}"
  fi
  [[ -f "${GEODB_TAR}" ]] || fail "GeoIP archive missing after download: ${GEODB_TAR}"
  tar -xzf "${GEODB_TAR}" -C "${GEODB_DIR}"
  local mmdb_count
  mmdb_count="$(find "${GEODB_DIR}" -type f -name '*.mmdb' 2>/dev/null | wc -l | tr -d ' ')"
  log_kv "event=geodb_extract_ok mmdb_count=${mmdb_count} dir=${GEODB_DIR}"
  phase_end "extract_geodb" "ok"
}

DEPLOY_MODE="all"
if [[ $# -eq 0 ]]; then
  DEPLOY_MODE="all"
elif [[ $# -eq 1 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all) DEPLOY_MODE="all" ;;
    --license-only) DEPLOY_MODE="license" ;;
    --version-only) DEPLOY_MODE="version" ;;
    *) fail "unknown option: $1 (use --help)" ;;
  esac
else
  fail "too many arguments; pass at most one of --all, --license-only, --version-only"
fi

log_msg "starting deploy mode=${DEPLOY_MODE} script_dir=${SCRIPT_DIR} log_file=${DEPLOY_LOG_FILE:-pending} geodb_defer=${GEODB_DEFER} geodb_url=${GEODB_DOWNLOAD_URL}"
log_kv "event=deploy_start mode=${DEPLOY_MODE} script_dir=${SCRIPT_DIR} hostname=$(hostname 2>/dev/null || echo unknown)"

case "${DEPLOY_MODE}" in
  all)
    log_kv "event=phase=all detail=dorian+license+geodb+venv+systemd"
    extract_dorian_version
    extract_license
    extract_geodb
    post_install_after_dorian_extract
    ;;
  license)
    log_kv "event=phase=license-only detail=license.tar.gz"
    extract_license
    ;;
  version)
    log_kv "event=phase=version-only detail=dorian+venv+systemd"
    extract_dorian_version
    post_install_after_dorian_extract
    ;;
  *)
    fail "internal error: invalid DEPLOY_MODE=${DEPLOY_MODE}"
    ;;
esac

cleanup_remote_staging_dir
# If the deploy log lived under staging, it is gone with the dir; prefer /var/dorian/logs from the start.
log_kv "event=deploy_finished status=ok mode=${DEPLOY_MODE} log_file=${DEPLOY_LOG_FILE:-none}"
log_msg "finished successfully mode=${DEPLOY_MODE} log_file=${DEPLOY_LOG_FILE:-none}"
