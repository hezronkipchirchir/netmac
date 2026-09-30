# netmac.sh — portable notes

Pick a Wi-Fi network, choose the MAC address to present, connect, and undo.
Built for an authorized engagement where the target AP was refusing a station
at the 802.11 auth stage (MAC-filter style), so presenting a different MAC fixes it.

## Files in this bundle

| File | What it is |
|------|-----------|
| `netmac.sh`      | The finished script (use this one). |
| `README.md`      | This file. |

## 1. Move it to the other device

Any one of these works:

```bash
# A) copy over SSH/scp (from the device that has the file)
scp netmac.sh user@OTHERHOST:~/netmac.sh

# B) copy the text and paste into a new file, then:
chmod +x netmac.sh

# C) if you push it to a repo / gist, git clone or curl the raw URL
```

Then make it executable and check it parses:

```bash
chmod +x netmac.sh
bash -n netmac.sh     # silent = OK
```

## 2. Dependencies on the other device

Use the OS packages (Debian/Kali/Ubuntu names shown):

```bash
sudo apt update
sudo apt install -y network-manager iproute2 iw aircrack-ng arp-scan
#   nmcli  <- network-manager
#   ip     <- iproute2
#   iw     <- iw            (monitor interface create/del)
#   airodump-ng <- aircrack-ng   (only for "sniff AP" option 2)
#   arp-scan                    (only for "ARP-scan" option 3)
```

Fedora: `dnf install NetworkManager iw aircrack-ng arp-scan iproute`
Arch:   `pacman -S networkmanager iw aircrack-ng arp-scan iproute2`

Only `nmcli` and `ip` are strictly required — the script warns (never aborts)
about `iw` / `airodump-ng` / `arp-scan` if those paths aren't installed.

## 3. Run it

```bash
./netmac.sh                        # interactive: list nets -> pick net -> pick MAC -> connect
./netmac.sh --list                 # just print networks (forces labels from nmcli)
./netmac.sh --status               # current iface / MAC / connection / IP / saved state
./netmac.sh --restore              # undo the last change (MAC + autoconnect + priority)
./netmac.sh --connect "SNET" aa:bb:cc:dd:ee:ff   # non-interactive connect
./netmac.sh --help
```

### Environment overrides

```bash
IFACE=wlan1 ./netmac.sh            # pick a non-default radio
SNIFF_SECS=40 ./netmac.sh          # longer monitor-mode capture for option 2
STATE=~/.netmac.env ./netmac.sh    # keep the undo state somewhere persistent
```

No `sudo` prefix needed — the script calls `sudo` only for the operations that need
root (monitor mode, arp-scan, `nmcli connection modify/create/up`), and verifies
your sudo credentials with `sudo -v` first.

## 4. The four MAC sources (menu option in `choose_mac`)

1. **Random locally-administered** — instant, no disconnect. Use when you only need
   to stop presenting a banned MAC (locally-administered bit set, `02:...`).
2. **Sniff the AP (monitor mode)** — brief Wi-Fi drop, then auto-restores your
   previous network. Needs `iw` + `airodump-ng`. On a single-radio adapter
   (e.g. Intel 7265) monitor + client cannot coexist, hence the drop.
3. **ARP-scan the LAN** — must already be associated. Lists real neighbours' MACs.
4. **Manual** — you type a MAC.

## 5. Rollback

Everything the script changes for a connect is recorded in `$STATE`
(default `/tmp/netmac_state.env`): previous active connection, target profile,
the profile's old cloned MAC, old autoconnect, old autoconnect-priority.
`--restore` reads it and puts all of that back, then re-activates the previous
network. Restore is best-effort: values that were empty are cleared.

## 6. Notes / caveats

- Emoji / spaces in an SSID are handled (both in the list and in `nmcli` args),
  but a freshly created profile uses the SSID as the connection name, so an SSID
  containing a single quote would be awkward — rename it with `nmcli con modify`.
- `mac (perm)` is blank on drivers that don't expose `/sys/class/net/<if>/permaddr`;
  that's cosmetic only.
- If the target AP isn't yours and the block was intentional, re-MACing circumvents
  the owner's control — that decision is yours within your authorized scope.
# netmac
