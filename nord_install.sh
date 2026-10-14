#!/usr/bin/env bash
# vps-nord — WireGuard (NordLynx) tunnel to NordVPN for a proxy node.
#
# Creates a `nord` interface that does NOT touch the machine's default route:
# only traffic that xray explicitly sends there goes through it, via
#   "streamSettings": {"sockopt": {"interface": "nord"}}
# Installs a `vps-nord` CLI (status, region change, server switch) and a
# watchdog that repairs a broken tunnel on its own.
#
# One-line install:
#   bash <(curl -fsSL https://github.com/volkmax777/vps-nord/releases/latest/download/nord_install.sh) --token <token> --region DE
#   bash <(curl -fsSL https://github.com/volkmax777/vps-nord/releases/latest/download/nord_install.sh) --key <key> --region de/berlin
#   bash <(curl -fsSL https://github.com/volkmax777/vps-nord/releases/latest/download/nord_install.sh)   # asks for key/token
#
# Use `bash <(...)`, not `curl | bash`: with the latter stdin is taken by the
# script itself and there is nothing left to read the key from. A local copy
# runs the same way: ./nord_install.sh --token ... --region DE
#
# Re-running is safe: the key and region are taken from /etc/vps-nord/config
# unless given explicitly, and a running tunnel keeps its server. This is also
# what `vps-nord update` does.
#
# The token comes from the Nord Account dashboard: NordVPN → Set up NordVPN
# manually → Generate new token. The NordLynx private key is one per account
# and works for every server, so changing region only changes the peer.

set -euo pipefail

# Replaced with the tag by the release workflow; "dev" means a checkout of main.
VERSION="dev"

# Empty = "not set on the command line". Defaults are filled in below, after
# looking at the config of a previous install.
IFACE=""
TABLE=""
MTU=""
ADDRESS=""
REGION=""
REGION_SET=0
FWMARK=""
FWMARK_SET=0
ADOPT=0
KEY=""
TOKEN=""
WATCHDOG=1
# Where `vps-nord update` downloads the installer from: the latest release by
# default, can be overridden with --url.
DEFAULT_SRC_URL="https://github.com/volkmax777/vps-nord/releases/latest/download/nord_install.sh"
SRC_URL=""

CONF_DIR=/etc/vps-nord
CONF=$CONF_DIR/config
CLI=/usr/local/bin/vps-nord
API=https://api.nordvpn.com/v1

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

usage() {
  cat <<'USAGE'
bash <(curl -fsSL https://github.com/volkmax777/vps-nord/releases/latest/download/nord_install.sh) [options]

  --token <t>     NordVPN access token; the private key is fetched with it
  --key <k>       NordLynx private key directly (44 base64 characters)
  --region <r>    country code (DE), city (berlin, de/berlin) or best
                  (default: best — NordVPN picks by load and node location)
  --iface <name>  interface name, default nord
  --table <n>     routing table number, default 51821
  --mtu <n>       MTU, default 1420
  --fwmark <n>    also route packets with this firewall mark into the tunnel
                  (off by default; e.g. 254 if mark 255 is used by another tunnel)
  --url <u>       installer URL for `vps-nord update` (default: latest release)
  --no-watchdog   do not install the tunnel check timer
  -h, --help      this help

Without --token and --key the key is taken from /etc/vps-nord/config, and if
there is none it is read from stdin — so the script also works without a TTY
(Ansible, other automation).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN=${2:?}; shift 2 ;;
    --key) KEY=${2:?}; shift 2 ;;
    --region) REGION=${2:?}; REGION_SET=1; shift 2 ;;
    --iface) IFACE=${2:?}; shift 2 ;;
    --table) TABLE=${2:?}; shift 2 ;;
    --mtu) MTU=${2:?}; shift 2 ;;
    --fwmark) FWMARK=${2:?}; FWMARK_SET=1; shift 2 ;;
    --url) SRC_URL=${2:?}; shift 2 ;;
    --no-watchdog) WATCHDOG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must be run as root"
command -v apt-get >/dev/null || die "only Debian/Ubuntu are supported"

# --- previous install ------------------------------------------------------

# The script is meant to be re-run: the same one-liner to update, automation
# on every run, or `vps-nord update`. Anything not given on the command line
# comes from the existing config — otherwise a re-run would reset the
# interface name to the default and ask for the key again.
if [[ -r $CONF ]]; then
  eval "$(
    # shellcheck disable=SC1090
    . "$CONF"
    for v in PRIVATE_KEY IFACE TABLE MTU ADDRESS FWMARK REGION REGION_LABEL \
             SERVER ENDPOINT PUBKEY LOAD SRC_URL; do
      n=NORD_$v
      printf 'OLD_%s=%q\n' "$v" "${!n:-}"
    done
  )"
fi

IFACE=${IFACE:-${OLD_IFACE:-nord}}
TABLE=${TABLE:-${OLD_TABLE:-51821}}
MTU=${MTU:-${OLD_MTU:-1420}}
ADDRESS=${ADDRESS:-${OLD_ADDRESS:-10.5.0.2/32}}
REGION=${REGION:-${OLD_REGION:-best}}
SRC_URL=${SRC_URL:-${OLD_SRC_URL:-$DEFAULT_SRC_URL}}
if [[ $FWMARK_SET -eq 0 ]]; then FWMARK=${OLD_FWMARK:-}; fi

# --- dependencies ----------------------------------------------------------

need=()
for p in wireguard-tools jq curl iproute2 iptables; do
  dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [[ ${#need[@]} -gt 0 ]]; then
  say "installing: ${need[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
fi

# WireGuard is built into kernels 5.6+; older ones need the dkms package.
if ! modprobe wireguard 2>/dev/null; then
  say "no wireguard module, installing the wireguard package"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard
  modprobe wireguard || die "the wireguard module failed to load"
fi

# --- private key -----------------------------------------------------------

fetch_key() { # $1 = access token
  local out
  # The token is passed to curl on stdin (-K -), not as an argument, so it
  # does not show up in `ps`.
  out=$(printf 'user = "token:%s"\n' "$1" \
          | curl -fsS --max-time 20 -K - "$API/users/services/credentials") \
    || die "NordVPN did not return credentials (wrong or expired token)"
  printf '%s' "$out" | jq -er '.nordlynx_private_key' \
    || die "no nordlynx_private_key in the response — no active subscription?"
}

if [[ -z $KEY && -z $TOKEN && -n ${OLD_PRIVATE_KEY:-} ]]; then
  KEY=$OLD_PRIVATE_KEY
  say "key taken from $CONF"
fi

if [[ -z $KEY && -z $TOKEN ]]; then
  # Reads from the terminal if there is one, otherwise just from stdin — so
  # automation can pass the value without a TTY. This is also why the install
  # is `bash <(curl ...)` and not `curl | bash`: there stdin is the script.
  echo "Enter a NordVPN access token or a NordLynx private key:"
  # `|| [[ -n ... ]]`: read returns non-zero on input without a trailing
  # newline (e.g. `printf %s "$TOKEN" | ...`) even though the value was read.
  answer=""
  read -r answer || [[ -n $answer ]] || die "no key given"
  answer=${answer//[[:space:]]/}
  [[ -n $answer ]] || die "no key given"
  if [[ $answer =~ ^[A-Za-z0-9+/]{43}=$ ]]; then KEY=$answer; else TOKEN=$answer; fi
fi

[[ -n $KEY ]] || KEY=$(fetch_key "$TOKEN")
[[ $KEY =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "the private key does not look like a WireGuard key"

# A re-run (update, automation) must not switch servers: any peer change drops
# the crypto session. If the tunnel is already up with the same key and the
# region was not changed, keep the live peer and only rewrite the config.
if [[ -n ${OLD_SERVER:-} && $KEY == "${OLD_PRIVATE_KEY:-}" ]] \
   && { [[ $REGION_SET -eq 0 ]] || [[ $REGION == "${OLD_REGION:-}" ]]; } \
   && ip link show "$IFACE" >/dev/null 2>&1; then
  ADOPT=1
  say "tunnel is already up (${OLD_SERVER}), keeping the server"
fi

# --- rp_filter -------------------------------------------------------------

# Replies from the tunnel arrive on nord, while the reverse path for their
# addresses goes through the main interface. With strict rp_filter (1) the
# kernel silently drops them: the tunnel looks up but passes nothing.
# The kernel uses max(all, <iface>), so `all` has to be relaxed too.
# What we need is "not stricter than 2": 1 breaks the tunnel, while 0 (filter
# off) is fine as it is — raising it to 2 would quietly tighten a node where
# it was disabled on purpose.
# On a re-run the live value is already our 2, so keep the line written
# earlier — otherwise strict 1 would come back after a reboot.
SYSCTL_FILE=/etc/sysctl.d/99-vps-nord.conf
{
  echo "# vps-nord: rp_filter no stricter than 2 (loose), otherwise the kernel"
  echo "# drops replies arriving on the tunnel interface."
  for k in all default; do
    cur=$(cat "/proc/sys/net/ipv4/conf/$k/rp_filter" 2>/dev/null || echo 2)
    if [[ $cur == 1 ]]; then
      echo "net.ipv4.conf.$k.rp_filter = 2"
      say "rp_filter.$k was strict (1), relaxing to 2" >&2
    elif grep -qx "net.ipv4.conf.$k.rp_filter = 2" "$SYSCTL_FILE" 2>/dev/null; then
      echo "net.ipv4.conf.$k.rp_filter = 2"
    fi
  done
} > "$SYSCTL_FILE.new"
mv "$SYSCTL_FILE.new" "$SYSCTL_FILE"
sysctl -q --system

# --- CLI -------------------------------------------------------------------

install -d -m 0700 "$CONF_DIR"

# Write next to it and rename: bash reads a script as it executes, and
# overwriting the file in place would break a watchdog running right now.
cat > "$CLI.new" <<'NORD_CLI_EOF'
#!/usr/bin/env bash
# vps-nord — manages the NordVPN tunnel. Installed by nord_install.sh; do not
# edit by hand, the next install overwrites it.

set -euo pipefail

CONF_DIR=/etc/vps-nord
CONF=$CONF_DIR/config
STATE_DIR=/run/vps-nord
API=https://api.nordvpn.com/v1

die() { echo "error: $*" >&2; exit 1; }
log() { logger -t vps-nord -- "$*"; }

usage() {
  cat <<'USAGE'
vps-nord — NordVPN tunnel

  status              current server, region, handshake, traffic
  test                exit IP directly and through the tunnel
  region              show the current region
  region <r>          change: country code (DE), city (berlin, de/berlin), best
  regions [pattern]   list countries and cities
  switch              another server in the same region
  up | down | restart interface control
  log [n]             watchdog and wg-quick log
  key --token <t>     replace the private key (or --key <k>)
  policy [up|down|status]  mark rule and blackhole (if installed with --fwmark)
  update [URL]        reinstall/update the script
  watchdog            one check; run by the timer
  uninstall [-y]      remove everything
USAGE
}

if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
  usage
  exit 0
fi

[[ -r $CONF ]] || die "no $CONF — run nord_install.sh first"
# shellcheck disable=SC1090
. "$CONF"

IFACE=${NORD_IFACE:-nord}
TABLE=${NORD_TABLE:-51821}
MTU=${NORD_MTU:-1420}
ADDRESS=${NORD_ADDRESS:-10.5.0.2/32}
FWMARK=${NORD_FWMARK:-}
WGCONF=/etc/wireguard/$IFACE.conf
UNIT=wg-quick@$IFACE

# --- config ----------------------------------------------------------------

save_config() {
  install -d -m 0700 "$CONF_DIR"
  cat > "$CONF.new" <<EOF
# vps-nord state. Rewritten by the vps-nord command.
NORD_PRIVATE_KEY=$(printf '%q' "$NORD_PRIVATE_KEY")
NORD_IFACE=$(printf '%q' "$IFACE")
NORD_TABLE=$(printf '%q' "$TABLE")
NORD_MTU=$(printf '%q' "$MTU")
NORD_ADDRESS=$(printf '%q' "$ADDRESS")
NORD_FWMARK=$(printf '%q' "$FWMARK")
# What was requested: country code, city or best.
NORD_REGION=$(printf '%q' "${NORD_REGION:-best}")
NORD_REGION_LABEL=$(printf '%q' "${NORD_REGION_LABEL:-best available}")
NORD_SERVER=$(printf '%q' "${NORD_SERVER:-}")
NORD_ENDPOINT=$(printf '%q' "${NORD_ENDPOINT:-}")
NORD_PUBKEY=$(printf '%q' "${NORD_PUBKEY:-}")
NORD_LOAD=$(printf '%q' "${NORD_LOAD:-}")
NORD_VERSION=$(printf '%q' "${NORD_VERSION:-unknown}")
# Installer URL for "vps-nord update", set with --url.
# Keep it quoted: the heredoc is unquoted, and backticks in this comment would
# be executed as a command on every config write.
NORD_SRC_URL=$(printf '%q' "${NORD_SRC_URL:-https://github.com/volkmax777/vps-nord/releases/latest/download/nord_install.sh}")
EOF
  chmod 600 "$CONF.new"
  mv "$CONF.new" "$CONF"
}

# --- API -------------------------------------------------------------------

api() { curl -fsS --max-time 20 "$API/$1"; }

countries() {
  local cache=$STATE_DIR/countries.json
  install -d -m 0755 "$STATE_DIR"
  # The country list changes rarely; no need to fetch it on every switch.
  # If the API is unreachable but a cache exists, use the cache, even stale.
  if [[ ! -s $cache ]] || (( $(date +%s) - $(stat -c %Y "$cache") > 86400 )); then
    if api "servers/countries" > "$cache.new" 2>/dev/null; then
      mv "$cache.new" "$cache"
    else
      rm -f "$cache.new"
    fi
  fi
  [[ -s $cache ]] || die "NordVPN did not return the country list"
  cat "$cache"
}

# Turns "DE", "Germany", "berlin", "de/berlin" into an API filter.
# Prints: <kind> <id> <label>, or "none 0 -".
resolve_region() {
  local q=${1:-best}
  if [[ -z $q || $q == best || $q == auto || $q == any ]]; then
    echo "best 0 best available"; return
  fi
  countries | jq -r --arg q "$q" '
    ($q | ascii_downcase | gsub("[_/-]"; " ") | gsub("  +"; " ")) as $n
    | ( [ .[]
          | select((.code | ascii_downcase) == $n or (.name | ascii_downcase) == $n)
          | "country \(.id) \(.name)" ]
      + [ .[] as $c | $c.cities[]
          | select((.name | ascii_downcase) == $n
                or ((($c.code + " " + .name)) | ascii_downcase) == $n
                or ((($c.name + " " + .name)) | ascii_downcase) == $n)
          | "city \(.id) \($c.name) / \(.name)" ] )
    | if length == 0 then "none 0 -" else .[0] end'
}

# Candidates for a region: hostname station pubkey load. For "best" no
# country filter is sent, and NordVPN orders servers by load and by distance
# from the address the request comes from — that is, from this node.
candidates() { # $1 kind, $2 id, $3 how many
  local f=""
  case "$1" in
    country) f="&filters%5Bcountry_id%5D=$2" ;;
    city)    f="&filters%5Bcountry_city_id%5D=$2" ;;
  esac
  api "servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=${3:-10}$f" \
    | jq -r '.[]
        | select(.status == "online")
        | . as $s
        | ( [ .technologies[] | select(.identifier == "wireguard_udp") | .metadata[]
              | select(.name == "public_key") | .value ] | first ) as $pk
        | select($pk != null and $s.station != "")
        | "\($s.hostname) \($s.station) \($pk) \($s.load)"'
}

# --- interface -------------------------------------------------------------

write_wgconf() { # $1 host, $2 station, $3 pubkey, $4 label
  install -d -m 0700 /etc/wireguard
  {
    echo "# Generated by vps-nord. Manual edits are lost on the next server change."
    echo "# Server: $1 ($4)"
    echo
    echo "[Interface]"
    echo "PrivateKey = $NORD_PRIVATE_KEY"
    echo "Address = $ADDRESS"
    echo "MTU = $MTU"
    # No DNS= line on purpose: queries to such a DNS server would bypass the
    # tunnel anyway (Table = off), and xray resolves with its own dns section.
    # Table = off: wg-quick adds no routes. The node's default route stays as
    # it is — only sockets bound to the interface (xray sockopt.interface) go
    # through the tunnel, not all of the machine's traffic.
    echo "Table = off"
    # Metric 100 vs 1000 for the blackhole from nord-policy: while the
    # interface is alive it wins; once it is gone, only the blackhole is left
    # and marked traffic is dropped instead of leaking into main.
    echo "PostUp = ip -4 route replace default dev %i table $TABLE metric 100"
    # del before add — after an unclean stop the rule may still exist, and
    # the interface would come up with two identical rules.
    echo "PostUp = ip -4 rule del oif %i table $TABLE priority 3100 2>/dev/null || true"
    echo "PostUp = ip -4 rule add oif %i table $TABLE priority 3100"
    # The mark rule is deliberately not added here: it lives in the separate
    # nord-policy unit together with the blackhole. Added from here, it would
    # disappear together with the tunnel, and marked traffic would go out
    # with the node's real IP.
    echo "PostUp = sysctl -qw net.ipv4.conf.%i.rp_filter=2"
    # MSS already follows the interface MTU; the clamp is a safeguard in case
    # the path to the server is narrower than 1420.
    echo "PostUp = iptables -t mangle -C POSTROUTING -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A POSTROUTING -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
    echo "PostDown = iptables -t mangle -D POSTROUTING -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true"
    echo "PostDown = ip -4 rule del oif %i table $TABLE priority 3100 2>/dev/null || true"
    # Remove only our own route. Flushing the table would also remove the
    # blackhole and open a leak exactly when the tunnel goes down.
    echo "PostDown = ip -4 route del default dev %i table $TABLE metric 100 2>/dev/null || true"
    echo
    echo "[Peer]"
    echo "PublicKey = $3"
    echo "AllowedIPs = 0.0.0.0/0"
    echo "Endpoint = $2:51820"
    echo "PersistentKeepalive = 25"
  } > "$WGCONF.new"
  chmod 600 "$WGCONF.new"
  mv "$WGCONF.new" "$WGCONF"
}

iface_up() { ip link show "$IFACE" >/dev/null 2>&1; }

apply_conf() {
  if iface_up; then
    # Remove the old peer explicitly. All servers in a NordVPN cluster share
    # one public key, and syncconf with the same key would only change the
    # endpoint and keep the old session: the kernel starts a new handshake
    # only after ~15 s of unanswered traffic or when the session keys expire,
    # while we wait 15 s — a live server would be rejected. A new peer with
    # PersistentKeepalive sends a keepalive at once, and the handshake starts
    # immediately. Losing the session is fine: we only get here to change
    # servers.
    local p
    for p in $(wg show "$IFACE" peers 2>/dev/null); do
      wg set "$IFACE" peer "$p" remove
    done
    # syncconf changes the peer without touching the address, route or rule:
    # a region change does not drop connections on other outbounds.
    wg syncconf "$IFACE" <(wg-quick strip "$IFACE")
  else
    systemctl start "$UNIT"
  fi
}

# The interface may exist while the unit is inactive — for example after a
# manual `wg-quick up`. `systemctl start` then fails with "File exists", and
# the repair would not work exactly when it is needed. So remove the
# interface first.
iface_reset() {
  if systemctl is-active --quiet "$UNIT"; then
    systemctl restart "$UNIT"
    return
  fi
  if iface_up; then
    wg-quick down "$IFACE" >/dev/null 2>&1 || ip link del "$IFACE" 2>/dev/null || true
  fi
  systemctl start "$UNIT"
}

cmd_down() {
  # Pause marker: without it the watchdog would bring the tunnel back within
  # a couple of minutes, making `down` useless. It lives in /run, so a reboot
  # clears it.
  install -d -m 0755 "$STATE_DIR"
  : > "$STATE_DIR/paused"
  if systemctl is-active --quiet "$UNIT"; then
    systemctl stop "$UNIT"
  elif iface_up; then
    wg-quick down "$IFACE"
  else
    echo "$IFACE is not up"
  fi
  echo "watchdog paused until vps-nord up/restart or reboot"
}

resume() { rm -f "$STATE_DIR/paused"; }

handshake_ts() {
  local ts
  ts=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  [[ -n ${ts:-} ]] || ts=0
  echo "$ts"
}

handshake_age() {
  local ts
  ts=$(handshake_ts)
  (( ts > 0 )) || return 1
  echo $(( $(date +%s) - ts ))
}

# $2 is the handshake timestamp before the peer change. Only a handshake newer
# than that counts: a timestamp left over from the previous server must not be
# taken as success of the new one.
wait_handshake() { # $1 = seconds to wait
  local i ts prev=${2:-0}
  for ((i = 0; i < ${1:-15}; i++)); do
    ts=$(handshake_ts)
    if (( ts > prev )) && (( $(date +%s) - ts < 180 )); then return 0; fi
    sleep 1
  done
  return 1
}

# ICMP to three addresses first, stopping at the first reply: one target may
# be blocked or rate-limit ICMP, which is no reason to call the tunnel dead.
# If all three are silent, try HTTPS by IP, without DNS: curl is always there,
# while ICMP may be filtered entirely.
probe_ok() {
  local ip
  for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
    ping -I "$IFACE" -c 1 -W 2 -q "$ip" >/dev/null 2>&1 && return 0
  done
  local code
  code=$(curl -s --max-time 8 --interface "$IFACE" -o /dev/null \
              -w '%{http_code}' https://1.1.1.1/ 2>/dev/null) || code=000
  [[ ${code:-000} != 000 ]]
}

# The probe is the ground truth. The handshake is only a safety net: if the
# probe failed but the handshake is fresh, the link is more likely alive than
# dead, and breaking it costs more than waiting. A really dead peer stops
# answering, its handshake ages, and the check catches it within minutes.
healthy() {
  iface_up || return 1
  probe_ok && return 0
  local age
  age=$(handshake_age) || return 1
  (( age < 300 ))
}

# --- commands --------------------------------------------------------------

cmd_connect() { # $1 region, $2 hostname to skip (for switch)
  local want=${1:-${NORD_REGION:-best}} avoid=${2:-}
  local kind id label info
  info=$(resolve_region "$want") || die "could not get the region list"
  read -r kind id label <<< "$info"
  [[ -n ${kind:-} && $kind != none ]] \
    || die "region '$want' not found — 'vps-nord regions $want' lists similar ones"

  local list host station pk load tried=0
  list=$(candidates "$kind" "$id") || die "NordVPN did not return the server list"
  [[ -n $list ]] || die "no WireGuard servers for '$label'"

  # The live interface's peer is rewritten on every attempt, so a failed
  # search would leave the tunnel on the last server that did not answer —
  # breaking what worked. Keep a copy of the config and restore it.
  local backup=""
  if [[ -f $WGCONF ]]; then
    backup=$(mktemp)
    cp "$WGCONF" "$backup"
  fi
  # Restores the config, not the session: the old server needs a new
  # handshake. So check it and say plainly whether the tunnel is back.
  restore_backup() {
    [[ -n $backup ]] || return 0
    local prev_hs
    prev_hs=$(handshake_ts)
    cp "$backup" "$WGCONF"
    rm -f "$backup"
    apply_conf || true
    echo "restored the previous server: ${NORD_SERVER:-unknown}" >&2
    if wait_handshake 20 "$prev_hs"; then
      echo "the previous tunnel is alive again" >&2
      log "switch failed, back on ${NORD_SERVER:-?}"
    else
      echo "WARNING: the previous server does not answer either — no tunnel right now." >&2
      echo "Try another region: vps-nord region <code>" >&2
      log "switch failed, ${NORD_SERVER:-?} does not answer either — no tunnel"
    fi
  }

  while read -r host station pk load; do
    [[ -n $host ]] || continue
    [[ $host != "$avoid" ]] || continue
    tried=$((tried + 1))
    echo "trying $host ($label, load ${load}%)"
    local prev_hs
    prev_hs=$(handshake_ts)
    write_wgconf "$host" "$station" "$pk" "$label"
    if ! apply_conf; then
      echo "  interface did not come up, next one"
      continue
    fi
    if wait_handshake 15 "$prev_hs"; then
      NORD_REGION=$want
      NORD_REGION_LABEL=$label
      NORD_SERVER=$host
      NORD_ENDPOINT="$station:51820"
      NORD_PUBKEY=$pk
      NORD_LOAD=$load
      save_config
      systemctl -q enable "$UNIT" 2>/dev/null || true
      log "connected $host ($label)"
      echo "connected: $host — $label"
      rm -f "$backup"
      resume
      return 0
    fi
    echo "  no handshake, next one"
  done <<< "$list"

  restore_backup
  (( tried > 0 )) || die "no servers in '$label' other than $avoid"
  die "no server in '$label' answered"
}

# Used by the installer on a re-run: keep the live peer and only rewrite the
# config. syncconf sees the same peer and leaves it alone — the session and
# handshake survive.
cmd_adopt() {
  iface_up || die "interface $IFACE is not up"
  local pk ep host label load
  pk=$(wg show "$IFACE" peers 2>/dev/null | head -n1)
  ep=$(wg show "$IFACE" endpoints 2>/dev/null | awk 'NR==1{print $2}')
  [[ -n ${pk:-} ]] || die "$IFACE has no peer"
  [[ -n ${ep:-} && $ep != "(none)" ]] || die "the $IFACE peer has no endpoint"

  host=${NORD_SERVER:-unknown}
  load=${NORD_LOAD:-}
  label=${NORD_REGION_LABEL:-}
  if [[ -z $label ]]; then
    read -r _ _ label <<< "$(resolve_region "${NORD_REGION:-best}" 2>/dev/null || echo "none 0 -")"
  fi

  write_wgconf "$host" "${ep%:*}" "$pk" "$label"
  wg syncconf "$IFACE" <(wg-quick strip "$IFACE")
  # syncconf does not touch the MTU; apply a changed --mtu right away.
  ip link set dev "$IFACE" mtu "$MTU" 2>/dev/null || true
  NORD_SERVER=$host
  NORD_ENDPOINT=$ep
  NORD_PUBKEY=$pk
  NORD_LOAD=$load
  NORD_REGION_LABEL=$label
  save_config
  systemctl -q enable "$UNIT" 2>/dev/null || true
  log "kept the current peer $host ($ep)"
  echo "kept: $host — $ep"
}

cmd_status() {
  local age hs="—" rxtx="—" state="down"
  if iface_up; then
    state="up"
    if age=$(handshake_age); then hs="${age}s ago"; else hs="never"; fi
    rxtx=$(wg show "$IFACE" transfer 2>/dev/null \
      | awk '{printf "↓ %.2f GiB  ↑ %.2f GiB", $2/1073741824, $3/1073741824}')
  fi
  local server="—"
  if [[ -n ${NORD_SERVER:-} ]]; then
    server="$NORD_SERVER  ${NORD_ENDPOINT:-}  load ${NORD_LOAD:-?}%"
  fi
  printf '%-11s %s\n' "Version:" "${NORD_VERSION:-unknown}"
  printf '%-11s %s\n' "Interface:" "$IFACE ($state)"
  printf '%-11s %s\n' "Region:" "${NORD_REGION_LABEL:-—} (requested: ${NORD_REGION:-—})"
  printf '%-11s %s\n' "Server:" "$server"
  printf '%-11s %s\n' "Handshake:" "$hs"
  printf '%-11s %s\n' "Traffic:" "${rxtx:-—}"
  # Check not the presence of the rule but what it is for: does the kernel
  # route a socket bound to the interface. The rule is not even required for
  # that — with oif set the kernel sends straight to the device; the rule only
  # makes the route explicit and visible in `ip route`.
  local bind="NO — sockets bound to $IFACE go nowhere"
  if ip route get 1.1.1.1 oif "$IFACE" 2>/dev/null | grep -q "dev $IFACE"; then
    bind="ok"
  fi
  printf '%-11s %s\n' "Binding:" "$bind"
  if [[ -n ${FWMARK:-} ]]; then
    local mark="no rule — marked traffic bypasses the tunnel"
    if ip -4 rule list 2>/dev/null | grep -q "fwmark $(printf '0x%x' "$FWMARK") lookup $TABLE"; then
      if ip -4 route show table "$TABLE" 2>/dev/null | grep -q "^blackhole default"; then
        mark="$FWMARK → table $TABLE, blackhole in place"
      else
        mark="$FWMARK → table $TABLE, but NO blackhole: traffic leaks if the tunnel drops"
      fi
    fi
    printf '%-11s %s\n' "Mark:" "$mark"
  fi
  # is-active on an inactive timer both prints "inactive" and returns non-zero:
  # with `|| echo` both words would end up on the line.
  local wd
  wd=$(systemctl is-active nord-watchdog.timer 2>/dev/null) || true
  case "${wd:-}" in
    inactive) wd="not running" ;;
    "") wd="not installed" ;;
  esac
  printf '%-11s %s\n' "Watchdog:" "$wd"
  if [[ -n ${FWMARK:-} ]]; then
    printf '%-11s %s\n' "Xray:" "\"sockopt\": {\"interface\": \"$IFACE\"} or {\"mark\": $FWMARK}"
  else
    printf '%-11s %s\n' "Xray:" "\"sockopt\": {\"interface\": \"$IFACE\"}"
  fi
}

cmd_test() {
  local direct tun
  direct=$(api "helpers/ips/insights" 2>/dev/null || echo '{}')
  tun=$(curl -fsS --max-time 10 --interface "$IFACE" "$API/helpers/ips/insights" 2>/dev/null || echo '{}')
  fmt() { jq -r 'if .ip then "\(.ip)  \(.country // "?") / \(.city // "?")  \(.isp // "?")  protected=\(.protected)" else "no answer" end' <<< "$1"; }
  echo "direct       : $(fmt "$direct")"
  echo "through $IFACE : $(fmt "$tun")"
  [[ $(jq -r '.ip // empty' <<< "$tun") != "" ]] || die "could not get out through the tunnel"
}

cmd_regions() {
  local pat=${1:-} all
  all=$(countries | jq -r '.[] | "\(.code)  \(.name)  [\([.cities[].name] | join(", "))]"')
  if [[ -n $pat ]]; then
    grep -i -- "$pat" <<< "$all" || echo "nothing matches '$pat'"
  else
    echo "$all"
  fi
}

cmd_watchdog() {
  install -d -m 0755 "$STATE_DIR"
  if [[ -e $STATE_DIR/paused ]]; then
    exit 0
  fi
  local fails=0 now last backoff exp
  if [[ -r $STATE_DIR/fails ]]; then fails=$(cat "$STATE_DIR/fails"); fi

  if healthy; then
    echo 0 > "$STATE_DIR/fails"
    exit 0
  fi

  fails=$((fails + 1))
  echo "$fails" > "$STATE_DIR/fails"
  log "check failed ($fails in a row)"

  # One miss is not an outage: breaking a working tunnel costs more than two
  # minutes. Act from the second one, switch servers from the third.
  if (( fails < 2 )); then
    log "first miss, waiting for the next check"
    return
  fi

  if (( fails == 2 )); then
    # Usually the server on the other side restarted: bring the interface up
    # again, keep the server.
    log "restarting $UNIT"
    iface_reset || log "restart failed"
    return
  fi

  # The pause between switches doubles up to half an hour: if the whole path
  # to NordVPN is down rather than one server, frequent switches do not help
  # and only add load.
  now=$(date +%s)
  last=0
  if [[ -r $STATE_DIR/last-switch ]]; then last=$(cat "$STATE_DIR/last-switch"); fi
  exp=$(( fails - 3 ))
  if (( exp > 4 )); then exp=4; fi
  backoff=$(( 300 * (2 ** exp) ))
  if (( backoff > 1800 )); then backoff=1800; fi
  if (( now - last < backoff )); then
    log "server switch postponed for another $(( backoff - (now - last) ))s ($fails misses)"
    return
  fi
  echo "$now" > "$STATE_DIR/last-switch"
  log "switching server in region ${NORD_REGION_LABEL:-?}"
  # In a subshell: on failure cmd_connect calls die, i.e. exit — without the
  # parentheses it would take the log line below with it.
  ( cmd_connect "${NORD_REGION:-best}" "${NORD_SERVER:-}" ) >/dev/null 2>&1 \
    || log "server switch failed"
}

cmd_key() {
  local new=""
  case "${1:-}" in
    --token) new=$(printf 'user = "token:%s"\n' "${2:?token required}" \
                     | curl -fsS --max-time 20 -K - "$API/users/services/credentials" \
                     | jq -er '.nordlynx_private_key') \
                   || die "NordVPN did not return a key" ;;
    --key) new=${2:?key required} ;;
    *) die "usage: vps-nord key --token <t> | --key <k>" ;;
  esac
  [[ $new =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "this does not look like a WireGuard key"
  NORD_PRIVATE_KEY=$new
  save_config
  if [[ -n ${NORD_SERVER:-} ]]; then
    write_wgconf "$NORD_SERVER" "${NORD_ENDPOINT%:*}" "$NORD_PUBKEY" "${NORD_REGION_LABEL:-}"
  fi
  systemctl restart "$UNIT"
  echo "key updated"
}

# Mark rule and blackhole. They live apart from the tunnel: the nord-policy
# unit sets them at boot and only uninstall removes them. The order matters —
# the blackhole appears before the rule and disappears after it, so there is
# never a moment when traffic is marked but has no route: such a packet would
# fall into main and leave with the node's real address.
cmd_policy() {
  [[ -n ${FWMARK:-} ]] || die "no mark configured — reinstall with --fwmark <n>"
  case "${1:-status}" in
    up)
      ip -4 route replace blackhole default metric 1000 table "$TABLE"
      # If the tunnel's PostUp has not run yet, the table has no route and
      # marked traffic would hit the blackhole.
      if iface_up; then
        ip -4 route replace default dev "$IFACE" table "$TABLE" metric 100
      fi
      # Add the rule only if it is missing: del + add would leave a moment in
      # which marked traffic has no rule and leaves with the node's real IP.
      if ! ip -4 rule list pref 3101 2>/dev/null \
           | grep -q "fwmark $(printf '0x%x' "$FWMARK") lookup $TABLE"; then
        ip -4 rule add fwmark "$FWMARK" table "$TABLE" priority 3101
      fi
      log "mark $FWMARK policy enabled (table $TABLE)"
      ;;
    down)
      ip -4 rule del fwmark "$FWMARK" table "$TABLE" priority 3101 2>/dev/null || true
      ip -4 route del blackhole default metric 1000 table "$TABLE" 2>/dev/null || true
      log "mark $FWMARK policy removed"
      ;;
    status)
      local rule="no" hole="no"
      if ip -4 rule list 2>/dev/null | grep -q "fwmark $(printf '0x%x' "$FWMARK") lookup $TABLE"; then rule="yes"; fi
      if ip -4 route show table "$TABLE" 2>/dev/null | grep -q "^blackhole default"; then hole="yes"; fi
      echo "mark $FWMARK → table $TABLE: rule $rule, blackhole $hole"
      ip -4 route show table "$TABLE" 2>/dev/null | sed 's/^/  /'
      ;;
    *) die "usage: vps-nord policy up|down|status" ;;
  esac
}

cmd_update() {
  local url=""
  if [[ "${1:-}" == "--url" && -n "${2:-}" ]]; then
    url="$2"
  elif [[ -n "${1:-}" && "${1:-}" != -* ]]; then
    url="$1"
  fi
  url="${url:-${NORD_SRC_URL:-https://github.com/volkmax777/vps-nord/releases/latest/download/nord_install.sh}}"
  local tmp rc=0
  tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  curl -fsSL --max-time 30 "$url" -o "$tmp" || die "could not download $url"
  head -n1 "$tmp" | grep -q '^#!' || die "$url is not a script"
  # The installer takes the key and region from the config, nothing is asked.
  local run_args=()
  if [[ -n "${1:-}" ]]; then
    run_args=(--url "$url")
  fi
  if ! bash "$tmp" "${run_args[@]}"; then rc=1; fi
  exit "$rc"
}

cmd_uninstall() {
  [[ ${1:-} == -y ]] || { read -r -p "Remove vps-nord completely? [y/N] " a; [[ $a == y ]] || exit 1; }
  systemctl disable --now nord-watchdog.timer 2>/dev/null || true
  # Remove the policy first (the unit's ExecStop removes the rule and the
  # blackhole), then the tunnel: otherwise the mark rule would outlive the
  # uninstall and marked traffic would go into an empty table.
  systemctl disable --now nord-policy.service 2>/dev/null || true
  systemctl disable --now "$UNIT" 2>/dev/null || true
  rm -f /etc/systemd/system/nord-watchdog.{service,timer} \
        /etc/systemd/system/nord-policy.service \
        /etc/sysctl.d/99-vps-nord.conf "$WGCONF"
  rm -rf "$CONF_DIR" "$STATE_DIR"
  systemctl daemon-reload
  # Remove ourselves last. The file is already open, so the remaining lines
  # still run.
  rm -f /usr/local/bin/vps-nord /usr/local/sbin/nord_install.sh
  echo "removed completely"
}

# The watchdog and a manual command must not rewrite the peer at the same
# time, or one overwrites the other's config mid-search. Read-only commands
# take no lock; the watchdog simply skips a round if the lock is taken.
case "${1:-status}" in
  region|switch|up|down|restart|adopt|key|watchdog)
    install -d -m 0755 "$STATE_DIR"
    exec 9>"$STATE_DIR/lock"
    if [[ ${1} == watchdog ]]; then
      flock -n 9 || exit 0
    else
      flock -w 300 9 || die "another vps-nord command (or the watchdog) is running, try later"
    fi
    ;;
esac

case "${1:-status}" in
  status) cmd_status ;;
  adopt) cmd_adopt ;;
  test) cmd_test ;;
  region)
    if [[ -n ${2:-} ]]; then cmd_connect "$2"; else
      echo "${NORD_REGION_LABEL:-—} (requested: ${NORD_REGION:-—})"; fi ;;
  regions) cmd_regions "${2:-}" ;;
  switch) cmd_connect "${NORD_REGION:-best}" "${NORD_SERVER:-}" ;;
  up) resume; if iface_up; then echo "$IFACE is already up"; else systemctl start "$UNIT"; fi; cmd_status ;;
  down) cmd_down ;;
  restart) resume; iface_reset; cmd_status ;;
  log) journalctl -t vps-nord -u "$UNIT" -n "${2:-50}" --no-pager ;;
  key) shift; cmd_key "$@" ;;
  policy) cmd_policy "${2:-status}" ;;
  update) shift; cmd_update "$@" ;;
  watchdog) cmd_watchdog ;;
  uninstall) cmd_uninstall "${2:-}" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
NORD_CLI_EOF
chmod 0755 "$CLI.new"
mv "$CLI.new" "$CLI"

# A copy of the installer next to the CLI makes the node self-contained:
# reinstalling or changing options works without network access or --url.
if [[ -f $0 && -r $0 && $(readlink -f "$0" 2>/dev/null || echo "$0") != "/usr/local/sbin/nord_install.sh" ]]; then
  install -m 0755 "$0" /usr/local/sbin/nord_install.sh
  say "installer saved: /usr/local/sbin/nord_install.sh"
elif [[ ! -f $0 && -n ${SRC_URL:-} ]]; then
  # Run via `bash <(curl ...)`: $0 is a pipe, there is nothing to copy, so
  # fetch the same URL. Replace the old copy only with a complete download.
  if curl -fsSL --max-time 15 "$SRC_URL" -o /usr/local/sbin/nord_install.sh.new 2>/dev/null \
     && head -n1 /usr/local/sbin/nord_install.sh.new | grep -q '^#!'; then
    install -m 0755 /usr/local/sbin/nord_install.sh.new /usr/local/sbin/nord_install.sh
    say "installer saved: /usr/local/sbin/nord_install.sh"
  fi
  rm -f /usr/local/sbin/nord_install.sh.new
fi

# --- initial state ---------------------------------------------------------

cat > "$CONF" <<EOF
# vps-nord state. Rewritten by the vps-nord command.
NORD_PRIVATE_KEY=$(printf '%q' "$KEY")
NORD_IFACE=$(printf '%q' "$IFACE")
NORD_TABLE=$(printf '%q' "$TABLE")
NORD_MTU=$(printf '%q' "$MTU")
NORD_ADDRESS=$(printf '%q' "$ADDRESS")
NORD_FWMARK=$(printf '%q' "$FWMARK")
NORD_REGION=$(printf '%q' "$REGION")
NORD_REGION_LABEL=$(printf '%q' "${OLD_REGION_LABEL:-}")
NORD_SERVER=$(printf '%q' "${OLD_SERVER:-}")
NORD_ENDPOINT=$(printf '%q' "${OLD_ENDPOINT:-}")
NORD_PUBKEY=$(printf '%q' "${OLD_PUBKEY:-}")
NORD_LOAD=$(printf '%q' "${OLD_LOAD:-}")
NORD_VERSION=$(printf '%q' "$VERSION")
NORD_SRC_URL=$(printf '%q' "$SRC_URL")
EOF
chmod 600 "$CONF"

# --- mark policy -----------------------------------------------------------

# A separate unit rather than the tunnel's PostUp: the rule and the blackhole
# must stay in place at all times, including while the tunnel is down.
# Otherwise the mark protects only until the first outage.
if [[ -n $FWMARK ]]; then
  cat > /etc/systemd/system/nord-policy.service <<EOF
[Unit]
Description=vps-nord: routing by mark $FWMARK
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$CLI policy up
ExecStop=$CLI policy down

[Install]
WantedBy=multi-user.target
EOF
  # A mark changed on a re-run: drop the rule for the old one. The blackhole
  # and the new rule are set below, so marked traffic is never unrouted.
  if [[ -n ${OLD_FWMARK:-} && $OLD_FWMARK != "$FWMARK" ]]; then
    ip -4 rule del fwmark "$OLD_FWMARK" table "$TABLE" priority 3101 2>/dev/null || true
  fi
  systemctl daemon-reload
  systemctl -q enable nord-policy.service
  # Never restart the unit: its stop removes the rule and the blackhole, and
  # until the start puts them back marked traffic would bypass the tunnel.
  # `policy up` on an active unit is idempotent and keeps both in place.
  if systemctl is-active --quiet nord-policy.service; then
    "$CLI" policy up
  else
    systemctl start nord-policy.service
  fi
  say "mark $FWMARK → table $TABLE, blackhole set"
fi

# --- watchdog --------------------------------------------------------------

if [[ $WATCHDOG -eq 1 ]]; then
  cat > /etc/systemd/system/nord-watchdog.service <<EOF
[Unit]
Description=vps-nord: tunnel check
After=wg-quick@$IFACE.service

[Service]
Type=oneshot
ExecStart=$CLI watchdog
EOF

  cat > /etc/systemd/system/nord-watchdog.timer <<'EOF'
[Unit]
Description=vps-nord: tunnel check every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl -q enable nord-watchdog.timer
fi

# --- connect ---------------------------------------------------------------

if [[ $ADOPT -eq 1 ]]; then
  "$CLI" adopt
else
  say "connecting: region '$REGION'"
  "$CLI" region "$REGION"
fi
systemctl -q enable "wg-quick@$IFACE"
if [[ $WATCHDOG -eq 1 ]]; then systemctl -q start nord-watchdog.timer; fi

echo
"$CLI" status
echo
cat <<EOF
Next, add an outbound to your xray profile:

  {"tag": "NORD", "protocol": "freedom",
   "settings": {"domainStrategy": "ForceIPv4"},
   "streamSettings": {"sockopt": {"interface": "$IFACE", "tcpFastOpen": true}}}

Change region:  vps-nord region NL   |   vps-nord regions de   |   vps-nord switch
EOF
