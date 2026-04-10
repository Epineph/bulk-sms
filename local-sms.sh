#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_CONFIG="/etc/gammu-smsdrc"
readonly DEFAULT_DELAY="0.20"

# -----------------------------------------------------------------------------
# Utility
# -----------------------------------------------------------------------------

function usage() {
	cat <<'EOF'
Usage:
  local-sms send --to <number> --message <text> [--config <file>]
  local-sms bulk --file <numbers.txt> --message <text>
                 [--config <file>] [--delay <seconds>] [--dry-run]
  local-sms bulk --numbers <n1,n2,...> --message <text>
                 [--config <file>] [--delay <seconds>] [--dry-run]

Description:
  Queue single or bulk SMS through gammu-smsd using gammu-smsd-inject.

Options:
  send
    --to <number>         Recipient number, ideally E.164 style.
    --message <text>      Message body.

  bulk
    --file <path>         File with one number per line. Blank lines and lines
                          beginning with '#' are ignored.
    --numbers <csv>       Comma-separated recipient list.
    --message <text>      Message body.
    --delay <seconds>     Delay between queue injections. Default: 0.20
    --dry-run             Validate and print what would be queued.

  common
    --config <file>       gammu-smsd config file. Default: /etc/gammu-smsdrc
    -h, --help            Show this help.

Examples:
  local-sms send \
    --to +4512345678 \
    --message "Test from terminal"

  local-sms bulk \
    --file recipients.txt \
    --message "Meeting moved to 14:00"

  local-sms bulk \
    --numbers "+4511111111,+4522222222,+4533333333" \
    --message "System maintenance tonight" \
    --delay 0.50

  local-sms bulk \
    --file recipients.txt \
    --message "Dry run only" \
    --dry-run

Recipient file format:
  +4511111111
  +4522222222
  # comment
  +4533333333
EOF
}

function die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

function require_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		die "Required command not found: $1"
}

function trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

function is_valid_number() {
	local number="$1"

	[[ "$number" =~ ^\+?[1-9][0-9]{6,14}$ ]]
}

function enqueue_sms() {
	local config="$1"
	local number="$2"
	local message="$3"

	printf '%s\n' "$message" |
		gammu-smsd-inject -c "$config" TEXT "$number"
}

function read_numbers_from_file() {
	local file="$1"

	[[ -f "$file" ]] || die "Recipient file not found: $file"

	while IFS= read -r line || [[ -n "$line" ]]; do
		line="$(trim "$line")"

		[[ -z "$line" ]] && continue
		[[ "${line:0:1}" == "#" ]] && continue

		printf '%s\n' "$line"
	done <"$file"
}

function read_numbers_from_csv() {
	local csv="$1"
	local item=""

	IFS=',' read -r -a _items <<<"$csv"

	for item in "${_items[@]}"; do
		item="$(trim "$item")"
		[[ -n "$item" ]] && printf '%s\n' "$item"
	done
}

function unique_numbers() {
	awk '!seen[$0]++'
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

function cmd_send() {
	local config="$DEFAULT_CONFIG"
	local to=""
	local message=""

	while (($#)); do
		case "$1" in
		--to)
			shift
			to="${1:-}"
			;;
		--message)
			shift
			message="${1:-}"
			;;
		--config)
			shift
			config="${1:-}"
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "Unknown argument for send: $1"
			;;
		esac
		shift
	done

	[[ -n "$to" ]] || die "--to is required"
	[[ -n "$message" ]] || die "--message is required"
	[[ -f "$config" ]] || die "Config file not found: $config"

	is_valid_number "$to" ||
		die "Invalid number format: $to"

	enqueue_sms "$config" "$to" "$message"
}

function cmd_bulk() {
	local config="$DEFAULT_CONFIG"
	local file=""
	local numbers_csv=""
	local message=""
	local delay="$DEFAULT_DELAY"
	local dry_run="false"

	while (($#)); do
		case "$1" in
		--file)
			shift
			file="${1:-}"
			;;
		--numbers)
			shift
			numbers_csv="${1:-}"
			;;
		--message)
			shift
			message="${1:-}"
			;;
		--config)
			shift
			config="${1:-}"
			;;
		--delay)
			shift
			delay="${1:-}"
			;;
		--dry-run)
			dry_run="true"
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "Unknown argument for bulk: $1"
			;;
		esac
		shift
	done

	[[ -n "$message" ]] || die "--message is required"
	[[ -f "$config" ]] || die "Config file not found: $config"

	if [[ -n "$file" && -n "$numbers_csv" ]]; then
		die "Use either --file or --numbers, not both"
	fi

	if [[ -z "$file" && -z "$numbers_csv" ]]; then
		die "One of --file or --numbers is required"
	fi

	local -a recipients=()
	local n=""
	local valid_count=0
	local queued_count=0

	if [[ -n "$file" ]]; then
		mapfile -t recipients < <(
			read_numbers_from_file "$file" | unique_numbers
		)
	else
		mapfile -t recipients < <(
			read_numbers_from_csv "$numbers_csv" | unique_numbers
		)
	fi

	((${#recipients[@]} > 0)) || die "No recipients found"

	for n in "${recipients[@]}"; do
		is_valid_number "$n" ||
			die "Invalid number format: $n"
	done

	valid_count="${#recipients[@]}"

	printf 'Validated recipients: %s\n' "$valid_count"

	for n in "${recipients[@]}"; do
		if [[ "$dry_run" == "true" ]]; then
			printf '[DRY-RUN] would queue to %s\n' "$n"
		else
			enqueue_sms "$config" "$n" "$message"
			printf '[QUEUED] %s\n' "$n"
			sleep "$delay"
		fi
		queued_count="$((queued_count + 1))"
	done

	printf 'Processed recipients: %s\n' "$queued_count"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
	require_cmd gammu-smsd-inject

	(($# > 0)) || {
		usage
		exit 1
	}

	case "$1" in
	send)
		shift
		cmd_send "$@"
		;;
	bulk)
		shift
		cmd_bulk "$@"
		;;
	-h | --help)
		usage
		;;
	*)
		die "Unknown subcommand: $1"
		;;
	esac
}

main "$@"
