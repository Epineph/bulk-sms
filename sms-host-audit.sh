#!/usr/bin/env bash

set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# sms-host-audit.sh
#
# Host-side readiness audit for a local SMS setup using:
#   - USB modem / phone
#   - Gammu / Gammu SMSD
#   - ModemManager / mmcli
#
# Scope:
#   - Verifies the host can plausibly serve as a Linux SMS gateway host.
#   - Verifies installed tooling, services, permissions, and visible devices.
#   - Optionally verifies a specific Gammu config via "gammu identify".
#
# Limits:
#   - Cannot prove carrier/SIM plan allows SMS.
#   - Cannot guarantee a specific modem model is supported unless connected and
#     actually responding.
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="${0##*/}"

REQUIRE_MODEM="false"
GAMMU_CONFIG=""
TTY_DEVICE=""
NO_COLOR="false"

declare -a PASSED=()
declare -a WARNED=()
declare -a FAILED=()
declare -a INFO=()

# -----------------------------------------------------------------------------
# Presentation
# -----------------------------------------------------------------------------

function color() {
  local name="${1:-}"
  if [[ "$NO_COLOR" == "true" ]]; then
    return 0
  fi

  case "$name" in
    red)    printf '\033[1;31m' ;;
    green)  printf '\033[1;32m' ;;
    yellow) printf '\033[1;33m' ;;
    blue)   printf '\033[1;34m' ;;
    bold)   printf '\033[1m' ;;
    reset)  printf '\033[0m' ;;
    *)      ;;
  esac
}

function print_help() {
  cat <<'EOF'
Usage:
  sms-host-audit.sh [options]

Description:
  Audit whether this Linux host is a plausible control host for a local
  SMS setup based on a USB modem/phone plus Gammu/ModemManager.

Options:
  --require-modem
      Treat absence of a connected modem as a failure instead of a warning.

  --gammu-config <path>
      Run "gammu -c <path> identify" as part of the audit.

  --tty <device>
      Explicitly test a specific device node such as /dev/ttyUSB0 or
      /dev/ttyACM0.

  --no-color
      Disable ANSI colors.

  -h, --help
      Show this help.

Examples:
  sms-host-audit.sh

  sms-host-audit.sh --require-modem

  sms-host-audit.sh --tty /dev/ttyUSB0

  sms-host-audit.sh --gammu-config /etc/gammu-smsdrc --require-modem
EOF
}

function add_pass() {
  PASSED+=("$1")
}

function add_warn() {
  WARNED+=("$1")
}

function add_fail() {
  FAILED+=("$1")
}

function add_info() {
  INFO+=("$1")
}

function have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function print_section() {
  printf '\n'
  color bold
  printf '%s\n' "$1"
  color reset
}

function print_list() {
  local label="$1"
  shift
  local -a items=("$@")
  local item=""

  printf '%s\n' "$label"
  if ((${#items[@]} == 0)); then
    printf '  (none)\n'
    return 0
  fi

  for item in "${items[@]}"; do
    printf '  - %s\n' "$item"
  done
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function parse_args() {
  while (($# > 0)); do
    case "$1" in
      --require-modem)
        REQUIRE_MODEM="true"
        ;;
      --gammu-config)
        shift
        GAMMU_CONFIG="${1:-}"
        ;;
      --tty)
        shift
        TTY_DEVICE="${1:-}"
        ;;
      --no-color)
        NO_COLOR="true"
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        printf 'Unknown argument: %s\n' "$1" >&2
        print_help >&2
        exit 1
        ;;
    esac
    shift
  done
}

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------

function check_os() {
  if [[ "${OSTYPE:-}" == linux* ]]; then
    add_pass "Host OS is Linux."
  else
    add_fail "Host OS is not Linux. This audit is intended for Linux hosts."
  fi
}

function check_basic_host() {
  local kernel=""
  local arch=""

  kernel="$(uname -sr 2>/dev/null || true)"
  arch="$(uname -m 2>/dev/null || true)"

  [[ -n "$kernel" ]] && add_info "Kernel: $kernel"
  [[ -n "$arch"   ]] && add_info "Architecture: $arch"

  if [[ -r /proc/meminfo ]]; then
    local mem_mib=""
    mem_mib="$(
      awk '/MemTotal:/ { printf "%.0f", $2 / 1024 }' /proc/meminfo \
        2>/dev/null
    )"
    [[ -n "$mem_mib" ]] && add_info "Memory detected: ${mem_mib} MiB"
  fi
}

function check_systemd() {
  if have_cmd systemctl; then
    add_pass "systemctl is available."
  else
    add_warn "systemctl is not available; no native systemd timers here."
  fi

  if [[ -d /run/systemd/system ]]; then
    add_pass "systemd runtime directory exists."
  else
    add_warn "systemd runtime directory not detected."
  fi
}

function check_required_commands() {
  local cmd=""
  local -a recommended=(
    lsusb
    lspci
    udevadm
    systemctl
    journalctl
    mmcli
    gammu
    gammu-smsd
    gammu-smsd-inject
    usb_modeswitch
  )

  for cmd in "${recommended[@]}"; do
    if have_cmd "$cmd"; then
      add_pass "Command present: $cmd"
    else
      add_warn "Command missing: $cmd"
    fi
  done
}

function check_usb_stack() {
  if have_cmd lsusb; then
    local count=""
    count="$(lsusb 2>/dev/null | wc -l | awk '{print $1}')"
    add_pass "lsusb works; USB devices listed: $count"
  else
    add_warn "lsusb unavailable; install usbutils for USB inspection."
  fi

  if have_cmd lspci; then
    if lspci 2>/dev/null | grep -Ei 'usb|xhci|ehci|ohci|uhci' >/dev/null; then
      add_pass "USB controller(s) detected via lspci."
    else
      add_warn "No USB controller line detected via lspci output."
    fi
  else
    add_warn "lspci unavailable; install pciutils for PCI inspection."
  fi
}

function gather_candidate_devices() {
  local -a devices=()
  local dev=""

  shopt -s nullglob
  for dev in /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm*; do
    devices+=("$dev")
  done
  shopt -u nullglob

  if [[ -n "$TTY_DEVICE" ]]; then
    devices+=("$TTY_DEVICE")
  fi

  printf '%s\n' "${devices[@]}" | awk 'NF && !seen[$0]++'
}

function check_device_nodes() {
  local -a devices=()
  local dev=""

  mapfile -t devices < <(gather_candidate_devices)

  if ((${#devices[@]} == 0)); then
    if [[ "$REQUIRE_MODEM" == "true" ]]; then
      add_fail "No modem-like device nodes found (/dev/ttyUSB*, ttyACM*, cdc-wdm*)."
    else
      add_warn "No modem-like device nodes found."
    fi
    return 0
  fi

  add_pass "Candidate modem-related device nodes found: ${#devices[@]}"

  for dev in "${devices[@]}"; do
    if [[ -e "$dev" ]]; then
      if [[ -r "$dev" && -w "$dev" ]]; then
        add_pass "Readable and writable device node: $dev"
      else
        add_warn "Device node exists but permissions may be insufficient: $dev"
      fi
    fi
  done
}

function check_user_groups() {
  local groups_out=""
  groups_out="$(id -nG 2>/dev/null || true)"

  add_info "User groups: ${groups_out:-unknown}"

  if printf '%s\n' "$groups_out" | grep -Eq '(^| )(uucp|dialout|lock)( |$)'; then
    add_pass "User is in at least one common serial-device group."
  else
    add_warn \
      "User is not in common serial-device groups (uucp/dialout/lock)."
  fi
}

function check_modemmanager() {
  if ! have_cmd mmcli; then
    add_warn "mmcli is unavailable; cannot query ModemManager."
    return 0
  fi

  if have_cmd systemctl; then
    if systemctl is-active --quiet ModemManager.service 2>/dev/null; then
      add_pass "ModemManager.service is active."
    else
      add_warn "ModemManager.service is not active."
    fi
  fi

  local mm_out=""
  mm_out="$(mmcli -L 2>&1 || true)"

  if printf '%s\n' "$mm_out" | grep -q '/org/freedesktop/ModemManager1/Modem/'; then
    add_pass "ModemManager reports at least one modem."
    add_info "mmcli -L output: $(printf '%s' "$mm_out" | tr '\n' ' ' )"
  else
    if [[ "$REQUIRE_MODEM" == "true" ]]; then
      add_fail "mmcli did not report a modem."
    else
      add_warn "mmcli did not report a modem."
    fi
  fi
}

function check_udev_for_devices() {
  if ! have_cmd udevadm; then
    add_warn "udevadm unavailable; cannot inspect udev properties."
    return 0
  fi

  local -a devices=()
  local dev=""

  mapfile -t devices < <(gather_candidate_devices)

  for dev in "${devices[@]}"; do
    [[ -e "$dev" ]] || continue

    if udevadm info -q property -n "$dev" >/dev/null 2>&1; then
      add_pass "udevadm can read properties for $dev"
    else
      add_warn "udevadm could not read properties for $dev"
    fi
  done
}

function check_gammu() {
  if ! have_cmd gammu; then
    add_warn "gammu is unavailable; cannot run direct modem checks."
    return 0
  fi

  if [[ -n "$GAMMU_CONFIG" ]]; then
    if [[ ! -f "$GAMMU_CONFIG" ]]; then
      add_fail "Gammu config file not found: $GAMMU_CONFIG"
      return 0
    fi

    local out=""
    out="$(gammu -c "$GAMMU_CONFIG" identify 2>&1 || true)"

    if printf '%s\n' "$out" | grep -Eiq \
      'Manufacturer|Model|Firmware|IMEI'; then
      add_pass "gammu identify succeeded with config: $GAMMU_CONFIG"
      add_info "gammu identify output: $(printf '%s' "$out" | tr '\n' ' ' )"
    else
      add_fail "gammu identify did not succeed with config: $GAMMU_CONFIG"
      add_info "gammu identify output: $(printf '%s' "$out" | tr '\n' ' ' )"
    fi
  else
    add_warn "No --gammu-config supplied; skipped gammu identify test."
  fi
}

function check_dmesg_hint() {
  if have_cmd dmesg; then
    local hint=""
    hint="$(
      dmesg 2>/dev/null \
        | tail -n 200 \
        | grep -Ei 'tty(USB|ACM)|cdc-wdm|modem|qmi|mbim|gsm' \
        | tail -n 5 \
        | tr '\n' ' '
    )"
    if [[ -n "$hint" ]]; then
      add_info "Recent kernel hint(s): $hint"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

function print_summary() {
  local pass_count="${#PASSED[@]}"
  local warn_count="${#WARNED[@]}"
  local fail_count="${#FAILED[@]}"

  print_section "Host audit summary"

  color green
  printf 'PASS : %s\n' "$pass_count"
  color yellow
  printf 'WARN : %s\n' "$warn_count"
  color red
  printf 'FAIL : %s\n' "$fail_count"
  color reset

  printf '\n'
  print_list "Passed checks" "${PASSED[@]}"
  printf '\n'
  print_list "Warnings" "${WARNED[@]}"
  printf '\n'
  print_list "Failed checks" "${FAILED[@]}"
  printf '\n'
  print_list "Informational notes" "${INFO[@]}"

  printf '\n'
  if ((fail_count == 0)); then
    color green
    printf 'Overall result: host is plausible for further modem/SMS testing.\n'
    color reset
  else
    color red
    printf 'Overall result: host is not yet ready for reliable modem/SMS use.\n'
    color reset
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  parse_args "$@"

  check_os
  check_basic_host
  check_systemd
  check_required_commands
  check_usb_stack
  check_device_nodes
  check_user_groups
  check_modemmanager
  check_udev_for_devices
  check_gammu
  check_dmesg_hint
  print_summary

  if ((${#FAILED[@]} > 0)); then
    exit 1
  fi

  exit 0
}

main "$@"
