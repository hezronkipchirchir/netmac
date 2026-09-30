#!/usr/bin/env bash
# netmac.sh - pick a Wi-Fi network, choose the MAC address to present, connect.
#
# Authorized engagement helper. Two ways to "clone a connected device's MAC":
#   (1) Sniff: monitor-mode capture of the target BSSID -> lists STATIONs
#              (needs a brief Wi-Fi drop on single-radio hardware).
#   (2) LAN  : associate first, then ARP-scan the subnet -> lists neighbours.
#
# Usage:
#   ./netmac.sh                     interactive
#   ./netmac.sh --list              print the network list and exit
#   ./netmac.sh --status            show current wifi state
#   ./netmac.sh --restore           undo the last change (MAC + autoconnect)
#   ./netmac.sh --connect SSID MAC  non-interactive connect (prompts for PSK if new)
#   IFACE=wlan1 SNIFF_SECS=40 ./netmac.sh
#
set -uo pipefail

VERSION="1.0"

# ---------- config / helpers -------------------------------------------------
IFACE="${IFACE:-$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')}"
[[ -z "${IFACE:-}" ]] && { echo "No wifi device found."; exit 1; }
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
STATE="${STATE:-/tmp/netmac_state.env}"
SNIFF_SECS="${SNIFF_SECS:-25}"

c_r()  { printf '\033[0m%s\n' "$*"; }
hdr()  { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
wn()   { printf '\033[1;33m%s\033[0m\n' "$*"; }
er()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

# Prompt on the controlling terminal, read the answer from it. This keeps ask()
# usable inside $(...) command substitutions and while stdin is a pipe/heredoc
# (e.g. feeding pick_mac_list from arp-scan output).
ask() {
  local p="$1" d="${2:-}" a=""
  # Try to open the controlling terminal for real (a plain -r test passes even
  # with no controlling tty, where the open then fails). Fall back to stdin.
  if { true >/dev/tty; } 2>/dev/null; then
    printf '\033[1;34m%s\033[0m' "$p" >/dev/tty
    IFS= read -r a </dev/tty || a=""
  else
    printf '\033[1;34m%s\033[0m' "$p"
    IFS= read -r a || a=""
  fi
  printf '%s' "${a:-$d}"
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

need_root() { if [[ $EUID -ne 0 ]]; then $SUDO -v || return 1; fi; }

have() { command -v "$1" >/dev/null 2>&1; }

check_deps() {
  local missing=()
  for t in nmcli ip; do have "$t" || missing+=("$t"); done
  # These are only needed for specific paths; warn, never die.
  have iw          || wn "note: iw not found          -> option '2) Sniff' will be unavailable"
  have airodump-ng || wn "note: airodump-ng not found -> option '2) Sniff' will be unavailable"
  have arp-scan    || wn "note: arp-scan not found    -> option '3) ARP-scan' will be unavailable"
  ((${#missing[@]})) && { er "Missing required tools: ${missing[*]}"; return 1; }
  return 0
}

rand_mac() { # locally-administered, unicast
  local h; h="$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
  printf '02:%s:%s:%s:%s:%s' "${h:0:2}" "${h:2:2}" "${h:4:2}" "${h:6:2}" "${h:8:2}"
}

get_iface_mac() { tr 'A-F' 'a-f' < "/sys/class/net/$IFACE/address" 2>/dev/null; }

get_perm_mac() {
  if [[ -r "/sys/class/net/$IFACE/permaddr" ]]; then
    tr 'A-F' 'a-f' < "/sys/class/net/$IFACE/permaddr"
  else
    ip -o link show "$IFACE" 2>/dev/null | grep -o 'permaddr [^ ]*' | awk '{print tolower($2)}'
  fi
}

# ---------- network discovery ------------------------------------------------
declare -a N_SSID N_BSSID N_SIG N_SEC N_CHAN N_PROFILE

list_wifi_profiles() {
  local n
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    [[ "$(nmcli -g connection.type connection show "$n" 2>/dev/null)" == "802-11-wireless" ]] && printf '%s\n' "$n"
  done < <(nmcli -g NAME connection show 2>/dev/null)
}

profile_for_ssid() {
  local target="$1" n s
  [[ -z "$target" ]] && return 0
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    s="$(nmcli -g 802-11-wireless.ssid connection show "$n" 2>/dev/null)"
    [[ "$s" == "$target" ]] && { printf '%s' "$n"; return 0; }
  done < <(list_wifi_profiles)
}

active_wifi() {
  local n
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    if [[ "$(nmcli -g connection.type connection show --active "$n" 2>/dev/null)" == "802-11-wireless" ]]; then
      printf '%s' "$n"; return 0
    fi
  done < <(nmcli -g NAME connection show --active 2>/dev/null)
}

load_networks() {
  N_SSID=(); N_BSSID=(); N_SIG=(); N_SEC=(); N_CHAN=(); N_PROFILE=()
  local ssid="" bssid="" sig="" sec="" chan="" line
  # nmcli -m multiline emits, per record: SSID, BSSID, SIGNAL, SECURITY, CHAN
  # then a blank line. Flush on CHAN (last field) so values land in the right row.
  flush_record() {
    [[ -z "$bssid" ]] && return 0
    N_SSID+=("${ssid:-<hidden>}")
    N_BSSID+=("$bssid")
    N_SIG+=("${sig:-?}")
    N_SEC+=("${sec:---}")
    N_CHAN+=("${chan:-}")
    N_PROFILE+=("$(profile_for_ssid "${ssid:-}")")
    ssid=""; bssid=""; sig=""; sec=""; chan=""
  }
  while IFS= read -r line; do
    line="$(trim "$line")"
    case "$line" in
      "SSID:"*)     ssid="$(trim "${line#SSID:}")" ;;
      "BSSID:"*)    bssid="$(trim "${line#BSSID:}")" ;;
      "SIGNAL:"*)   sig="$(trim "${line#SIGNAL:}")" ;;
      "SECURITY:"*) sec="$(trim "${line#SECURITY:}")" ;;
      "CHAN:"*)     chan="$(trim "${line#CHAN:}")"; flush_record ;;
      "")           flush_record ;;
    esac
  done < <(nmcli -m multiline -f SSID,BSSID,SIGNAL,SECURITY,CHAN device wifi list 2>/dev/null)
  flush_record
}

show_networks() {
  load_networks
  hdr "AVAILABLE NETWORKS on $IFACE"
  if ((${#N_SSID[@]} == 0)); then
    wn "No networks listed. Try: nmcli device wifi rescan ; then re-run."
    return 0
  fi
  printf '%-4s %-26s %-7s %-11s %-5s %s\n' "IDX" "SSID" "SIGNAL" "SECURITY" "CHAN" "BSSID"
  printf '%-4s %-26s %-7s %-11s %-5s %s\n' "---" "----" "------" "--------" "----" "-----"
  local i
  for i in "${!N_SSID[@]}"; do
    printf '%-4s %-26s %-7s %-11s %-5s %s\n' \
      "$((i+1))" "${N_SSID[$i]}" "${N_SIG[$i]}" "${N_SEC[$i]}" "${N_CHAN[$i]}" "${N_BSSID[$i]}"
    [[ -n "${N_PROFILE[$i]}" ]] && printf '     %s\n' "(saved profile: ${N_PROFILE[$i]})"
  done
}

choose_network() {
  load_networks
  local n; n="$(ask 'Select network number: ')"
  [[ "$n" =~ ^[0-9]+$ ]] || { er "Not a number."; return 1; }
  (( n>=1 && n<=${#N_SSID[@]} )) || { er "Out of range."; return 1; }
  SEL_SSID="${N_SSID[$((n-1))]}"
  SEL_BSSID="${N_BSSID[$((n-1))]}"
  SEL_CHAN="${N_CHAN[$((n-1))]}"
  SEL_SEC="${N_SEC[$((n-1))]}"
  SEL_PROFILE="${N_PROFILE[$((n-1))]}"
  ok "Target: '$SEL_SSID'  bssid=$SEL_BSSID  chan=${SEL_CHAN:-?}  sec=${SEL_SEC:---}  profile=${SEL_PROFILE:-<none>}"
}

# ---------- MAC sources ------------------------------------------------------
sniff_stations() { # -> prints "stationMAC|bssid|probed" lines seen on the target BSSID
  local bssid="$1" chan="$2" prev="$3"
  need_root || { er "sniff needs root."; return 1; }
  have airodump-ng || { er "airodump-ng not installed."; return 1; }
  wn "Monitor mode will drop '$prev' on $IFACE for ~${SNIFF_SECS}s, then restore it."
  local go; go="$(ask 'Proceed? [y/N] ')"
  [[ "${go,,}" == y* ]] || return 1

  local dir mon="mon_netmac"; dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  $SUDO nmcli device disconnect "$IFACE" >/dev/null 2>&1; sleep 1
  if $SUDO iw dev "$IFACE" interface add "$mon" type monitor 2>/dev/null; then :; else
    er "Could not create monitor interface (driver support?)."
    [[ -n "$prev" ]] && $SUDO nmcli connection up "$prev" >/dev/null 2>&1
    return 1
  fi
  $SUDO ip link set "$mon" up

  local args=(--band bg -w "$dir/cap" --output-format csv --write-interval 1)
  [[ -n "$chan" && "$chan" != 0 && "$chan" != "?" ]] && args+=( -c "$chan" )
  [[ -n "$bssid" ]] && args+=( --bssid "$bssid" )

  hdr "Sniffing ${bssid:-<any>} (chan ${chan:-hop}) for ${SNIFF_SECS}s ..."
  timeout "$SNIFF_SECS" $SUDO airodump-ng "${args[@]}" "$mon" >/dev/null 2>&1

  $SUDO ip link set "$mon" down 2>/dev/null
  $SUDO iw dev "$mon" del 2>/dev/null

  local csv; csv="$(ls "$dir"/cap-*.csv 2>/dev/null | head -n1)"
  if [[ -n "$csv" ]]; then
    awk -F', *' -v tgt="$bssid" '
      /^Station MAC/ { st=1; next }
      st==1 && NF>=6 {
        gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$6); gsub(/^ +| +$/,"",$7);
        if ($1=="") next;
        if (tgt=="" || $6==tgt) printf "%s|%s|%s\n", $1, $6, ($7==""?"-":$7)
      }' "$csv"
  fi
  [[ -n "$prev" ]] && $SUDO nmcli connection up "$prev" >/dev/null 2>&1
}

arp_neighbours() { # -> "mac|ip vendor" lines for devices on the subnet we are on
  need_root || { er "arp-scan needs root."; return 1; }
  have arp-scan || { er "arp-scan not installed."; return 1; }
  hdr "ARP-scanning local subnet on $IFACE ..."
  $SUDO arp-scan --interface="$IFACE" --localnet 2>/dev/null \
    | awk -F'\t' '/^[0-9]/{printf "%s|%s %s\n", $2, $1, $3}'
}

pick_mac_list() { # reads "mac|extra" lines from stdin -> sets PICKED_MAC
  local -a macs=() ext=() line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    macs+=("${line%%|*}"); ext+=("${line#*|}")
  done
  ((${#macs[@]} == 0)) && { wn "No devices found."; return 1; }
  local i
  for i in "${!macs[@]}"; do printf '  [%d] %s   %s\n' "$((i+1))" "${macs[$i]}" "${ext[$i]}"; done
  local n; n="$(ask 'Pick MAC number (or 0 to cancel): ' 0)"
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le ${#macs[@]} ]] || return 1
  PICKED_MAC="${macs[$((n-1))]}"
}

choose_mac() {
  hdr "HOW SHOULD WE PICK THE MAC?"
  echo "  1) Random locally-administered MAC   (works if you were only MAC-banned)"
  echo "  2) Sniff AP for connected devices    (monitor mode, brief disconnect)"
  echo "  3) ARP-scan current network          (you must already be on it)"
  echo "  4) Enter a MAC manually"
  local ch; ch="$(ask 'Choice [1]: ' 1)"
  case "$ch" in
    1) PICKED_MAC="$(rand_mac)"; ok "Using random MAC $PICKED_MAC" ;;
    2) local out; out="$(sniff_stations "$SEL_BSSID" "$SEL_CHAN" "$(active_wifi)")"
       [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/  station /'
       pick_mac_list <<<"$out" || return 1 ;;
    3) local out; out="$(arp_neighbours)"
       pick_mac_list <<<"$out" || return 1 ;;
    4) PICKED_MAC="$(ask 'MAC (aa:bb:cc:dd:ee:ff): ')"
       [[ "$PICKED_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { er "Bad MAC."; return 1; } ;;
    *) er "Bad choice."; return 1 ;;
  esac
  return 0
}

# ---------- apply ------------------------------------------------------------
apply_connect() {
  local ssid="$1" mac="$2" prof="$3" sec="${4:-}"
  local prev; prev="$(active_wifi)"

  if [[ -z "$prof" ]]; then
    wn "No saved profile for '$ssid'. Create it (needs the Wi-Fi password)."
    ((${#ssid} == 0)) && { er "Empty SSID."; return 1; }
    $SUDO nmcli connection add type wifi ifname "$IFACE" con-name "$ssid" ssid "$ssid" || return 1
    prof="$ssid"
    if [[ "$sec" == "--" || -z "$sec" ]]; then
      ok "Network looks open; no PSK set."
    else
      $SUDO nmcli connection modify "$prof" wifi-sec.key-mgmt wpa-psk
      local psk; psk="$(ask 'Wi-Fi password: ')"
      $SUDO nmcli connection modify "$prof" wifi-sec.psk "$psk"
    fi
  fi

  # remember state for --restore
  {
    printf "PREV_ACTIVE='%s'\n" "$prev"
    printf "PROFILE='%s'\n"     "$prof"
    printf "OLD_MAC='%s'\n"     "$(nmcli -g 802-11-wireless.cloned-mac-address connection show "$prof" 2>/dev/null)"
    printf "OLD_AUTOCONNECT='%s'\n" "$(nmcli -g connection.autoconnect connection show "$prof" 2>/dev/null)"
    printf "OLD_PRIORITY='%s'\n"    "$(nmcli -g connection.autoconnect-priority connection show "$prof" 2>/dev/null)"
  } > "$STATE"

  if [[ "${mac,,}" == "$(get_iface_mac)" ]]; then
    wn "Interface already uses $mac."
  fi

  $SUDO nmcli connection modify "$prof" 802-11-wireless.cloned-mac-address "$mac" || return 1
  $SUDO nmcli connection modify "$prof" connection.autoconnect yes

  hdr "Connecting to '$ssid' with MAC $mac ..."
  $SUDO nmcli connection up "$prof" 2>&1 | sed 's/^/  /'

  sleep 3
  local st; st="$(nmcli -t -f GENERAL.CONNECTION device show "$IFACE" | cut -d: -f2-)"
  if [[ "$st" == "$prof" || "$st" == "$ssid" ]]; then
    ok "CONNECTED to '$st' ($(nmcli -t -f IP4.ADDRESS device show "$IFACE" | cut -d: -f2-))"
    ok "Interface MAC now: $(get_iface_mac)  (perm: $(get_perm_mac))"
  else
    er "Did not connect (now on '$st'). Restoring previous network..."
    [[ -n "$prev" ]] && $SUDO nmcli connection up "$prev" 2>&1 | sed 's/^/  /'
    return 1
  fi
}

restore() {
  [[ -f "$STATE" ]] || { wn "Nothing to restore."; return; }
  # shellcheck disable=SC1090
  source "$STATE"
  hdr "Restoring profile '$PROFILE'"
  $SUDO nmcli connection modify "$PROFILE" 802-11-wireless.cloned-mac-address "${OLD_MAC:-}"
  [[ -n "${OLD_AUTOCONNECT:-}" ]] && $SUDO nmcli connection modify "$PROFILE" connection.autoconnect "$OLD_AUTOCONNECT"
  [[ -n "${OLD_PRIORITY:-}" ]] && $SUDO nmcli connection modify "$PROFILE" connection.autoconnect-priority "$OLD_PRIORITY"
  [[ -n "${PREV_ACTIVE:-}" ]] && $SUDO nmcli connection up "$PREV_ACTIVE"
  ok "Done. Interface MAC: $(get_iface_mac)  (perm: $(get_perm_mac))"
}

status() {
  hdr "STATUS"
  echo "iface      : $IFACE"
  echo "mac (now)  : $(get_iface_mac)"
  echo "mac (perm) : $(get_perm_mac)"
  echo "connection : $(nmcli -t -f GENERAL.CONNECTION device show "$IFACE" | cut -d: -f2-)"
  echo "ip         : $(nmcli -t -f IP4.ADDRESS device show "$IFACE" | cut -d: -f2-)"
  [[ -f "$STATE" ]] && { echo "saved state:"; sed 's/^/  /' "$STATE"; }
}

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

connect_target() { # --connect SSID MAC
  local ssid="$1" mac="$2" prof
  [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { er "Bad MAC: $mac"; exit 2; }
  prof="$(profile_for_ssid "$ssid")"
  apply_connect "$ssid" "$mac" "$prof" ""
}

main() {
  case "${1:-}" in
    -h|--help)    usage; exit 0 ;;
    -V|--version) echo "netmac.sh $VERSION"; exit 0 ;;
  esac
  check_deps || exit 1
  case "${1:-}" in
    --list)    show_networks; exit 0 ;;
    --status)  status; exit 0 ;;
    --restore) restore; exit 0 ;;
    --connect) [[ $# -ge 3 ]] || { er "usage: $0 --connect SSID MAC"; exit 2; }
               connect_target "$2" "$3"; exit $? ;;
    "") : ;;
    *) er "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
  hdr "netmac.sh $VERSION  (iface=$IFACE)"
  show_networks
  echo
  choose_network || exit 1
  echo
  choose_mac     || { er "No MAC chosen."; exit 1; }
  echo
  apply_connect "$SEL_SSID" "$PICKED_MAC" "$SEL_PROFILE" "$SEL_SEC"
}

main "$@"
