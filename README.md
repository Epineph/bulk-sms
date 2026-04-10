# bulk-sms

## Hvorfor et python script _direct-to-modem_ ikke er den bedste løsning

Fordi daemon/kø-modellen simpelthen er bedre ingeniørmæssigt designet til _**bulk**-SMS'er_.

Lad:

$$
M = \text{mængde af sms'er at sende}
$$

Hvis scriptet kommunikerer direkte med modemet, skal selve scriptet være i stand til at håndtere:

$$
\text{låsning} + \text{genforsøg} + \text{køtilstand} + \text{leveringsfejl} + \text{enhedskonflikt}
$$

Hvis dit script i stedet kun indsætter job i køen, så bliver dit script:

$$
\text{inputvalidering} + \text{i kø}
$$

## Fase 1: minimalt robut setup

Ved brug af Arch, installer som det mindste:

```bash
sudo pacman -S gammu
```

`gammu` er tilgængeligt på Arch `extra` repository.

Til diagnosticering af modemer og SIM-kortstatus er Archs mobile bredbåndsværktøjer omkring ModemManager ofte nyttige; [ArchWiki](https://wiki.archlinux.org/title/Mobile_broadband_modem) bemærker, at det kan vise modem/SIM-information og også kan sende/modtage SMS'er.

Derfor er et praktisk add-on:

```bash
sudo pacman -S modemmanager usb_modeswitch
```

## Identificer modem device

For AT-kompatibel ikke-Nokia-hardware siger `Gammus` konfigurationsvejledning, at den sædvanlige forbindelsestype er på , og du peger den typisk mod modemenheden, for eksempel `/dev/ttyUSB0`; moderne USB-kabler/modemer kræver generelt ikke en manuelt tvungen baudrate.

Start med at tjekke, hvad der vises, når du tilslutter enheden:

```bash
dmesg | tail -n 80
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
```

Alternativt:

```bash
gammu-detect
```

fordi Gammu eksplicit [dokumenterer](https://docs.gammu.org) gammu-detect og gammu-config som hjælpeværktøjer til generering/validering af konfiguration.

## Brug FILES-backend først

FILES-backend'en er anbefalet, ikke SQL.

Hvorfor? Fordi:

- [Gammus backend-tjeneste](https://docs.gammu.org/smsd/backends.html) gemmer både indgående beskeder og den udgående kø.
- FILES-backend'en [gemmer denne kø](https://man.archlinux.org/man/extra/gammu/gammu-smsd-files.7.en) direkte i filsystemmapper.
- `gammu-smsd-inject` fungerer med alle aktuelt [understøttede backends, inklusivt FILES](https://man.archlinux.org/man/gammu-smsd-inject.1.en).

Så det simpleste stabile design er:

```bash
/var/spool/gammu/inbox
/var/spool/gammu/outbox
/var/spool/gammu/sent
/var/log/gammu/
```

For at lave dem:

```bash
sudo install -d -m 0750 /var/spool/gammu/inbox
sudo install -d -m 0750 /var/spool/gammu/outbox
sudo install -d -m 0750 /var/spool/gammu/sent
sudo install -d -m 0750 /var/log/gammu
```

## 4. Lav `/etc/gammu-smsdrc`

Gammu dokumenterer `/etc/gammu-smsdrc` som standard dæmonkonfigurationsstien, og [konfigurationsfilen skal som minimum indeholde afsnittene](https://docs.gammu.org/smsd/config.html) `[gammu]` og `[smsd]`.

Så et godt startpunkt:

```ini
[gammu]
device = /dev/ttyUSB0
connection = at
synchronizetime = yes
logformat = textall

[smsd]
service = files
logfile = /var/log/gammu/smsd.log
debuglevel = 0

inboxpath = /var/spool/gammu/inbox/
outboxpath = /var/spool/gammu/outbox/
sentsmspath = /var/spool/gammu/sent/
```

Disse FILES-backend-stidirektiver er dokumenteret af Gammu til FILES-tjenesten.

## Test modemet før du bruger dæmonen

Før du introducerer køen, skal du først kontrollere, at Gammu kan kommunikere med modemet:

```bash
gammu --config /etc/gammu-smsdrc identify
gammu --config /etc/gammu-smsdrc networkinfo
gammu --config /etc/gammu-smsdrc getsmsc
```

Det sidste punkt er vigtigt, fordi Gammu dokumenterer, at SMSC normalt læses automatisk fra telefonen/modemmet, men hvis det mislykkes, kan det kontrolleres med `gammu getsmsc`.

## Fase 2: run daemonen

For et _dry run_:

```bash
sudo gammu-smsd --config /etc/gammu-smsdrc --debug info
```

Daemonen er den komponent, der scanner modemet, gemmer modtagne beskeder og sender udgående beskeder i kø.

Når det virker, skal det flyttes under systemd.

## Eksempel på systemd unit

```ini
[Unit]
Description=Gammu SMS Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/gammu-smsd --config /etc/gammu-smsdrc --debug info
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Gem som:

```bash
/etc/systemd/system/gammu-smsd.service
```

Derefter:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gammu-smsd.service
sudo systemctl status gammu-smsd.service
```

## Fase 3: send et enkelt sms

Den dokumenterede model er at sætte i kø via `gammu-smsd-inject`. Gammu's eget eksemåel viser piping teksten til `gammu-smsd-inject TEXT <recipient>`.

Så et enkelt sms ser således ud:

```bash
printf '%s\n' 'Hello from Arch Linux.' \
  | gammu-smsd-inject -c /etc/gammu-smsdrc TEXT +4512345678
```

## Fase 4: bulk sms

Det er her et _wrappper_ script kommer ind.
Daemonen ved allerede, hvordan man sender arbejde i kø. Så dit bulk-script bør kun gøre dette:

$$
\text{bulk-arbejde}_{sms} = \sum_{i=1}^{N} \text{i kø}(m_i,b)
$$

Hvor:

- $N \ = \text{antaller af modtagerer}$
- $m_i = \text{modtager}_i$
- $b \ \ \ = \text{beskedens indhold}$
  Med andre ord: én injektion pr. modtager.

Det er enkelt, inspektionsbart og pålideligt.

## Shell script for enkelte og bulk-sms

```bash
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
  command -v "$1" >/dev/null 2>&1 \
    || die "Required command not found: $1"
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

  printf '%s\n' "$message" \
    | gammu-smsd-inject -c "$config" TEXT "$number"
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
      -h|--help)
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

  is_valid_number "$to" \
    || die "Invalid number format: $to"

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
      -h|--help)
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
    is_valid_number "$n" \
      || die "Invalid number format: $n"
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
    -h|--help)
      usage
      ;;
    *)
      die "Unknown subcommand: $1"
      ;;
  esac
}

main "$@"
```

## Eksempler på brug

### 1. sæt et sms i kø

```bash
local-sms send \
  --to +4512345678 \
  --message "Test fra lokalt modem"
```

### 2. Sæt bulk-sms i kø fra en fil

```bash
local-sms bulk \
  --file modtagere.txt \
  --message "Tilbud... indsæt resten"
```

### 3. Sæt bulk-sms i kø fra en CSV liste

```bash
local-sms bulk \
  --numbers "+4511111111,+4522222222,+4533333333" \
  --message "I aften starter vi...."
```
