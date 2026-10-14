# vps-nord

A NordVPN (NordLynx / WireGuard) tunnel for a proxy node, made to be used as an
Xray outbound. One script creates a `nord` interface and installs a CLI and a
watchdog next to it.

```
nord_install.sh   the installer; it also carries the CLI
```

After installation the node has `/usr/local/bin/vps-nord` (the CLI) and
`/usr/local/sbin/nord_install.sh` (a copy of the installer, so reinstalling
needs neither network access nor `--url`).

> **Disclaimer.** This project is not affiliated with, endorsed by or
> supported by NordVPN. It uses the unofficial `api.nordvpn.com/v1` API, which
> may change without notice. You need your own NordVPN subscription, and its
> terms of service apply to how you use it.

## Requirements

Debian or Ubuntu with systemd, kernel 5.6+ (WireGuard is built in; on older
kernels the `wireguard` package is installed), root. `wireguard-tools`, `jq`,
`curl`, `iproute2` and `iptables` are installed automatically if missing.

## How it works

The node's default route is left untouched. The WireGuard config has
`Table = off`, and the route goes into a separate table (51821) that only
sockets bound to the interface reach:

```
ip rule add oif nord table 51821 priority 3100
ip route replace default dev nord table 51821
```

This is exactly what Xray does with `sockopt.interface` (SO_BINDTODEVICE): only
traffic that Xray routing sends to this outbound goes through the tunnel. The
node itself, the panel, incoming connections and other services are not
affected.

Strictly speaking the rule is not required: with `oif` set, the kernel sends
the packet straight to the device even without a route, and
`ip route get 1.1.1.1 oif nord` answers `dev nord`. The rule is kept because
it makes the route explicit and visible; `vps-nord status` checks the binding
itself, not the presence of the rule.

Xray outbound example:

```json
{
  "tag": "NORD",
  "protocol": "freedom",
  "settings": { "domainStrategy": "ForceIPv4" },
  "streamSettings": { "sockopt": { "interface": "nord", "tcpFastOpen": true } }
}
```

## Installation

Token: Nord Account dashboard → NordVPN → Set up NordVPN manually → Generate
new token. The NordLynx private key is fetched with it once; the key is one per
account and works for every server, so changing region only changes the peer.

One-line install:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/volkmax777/vps-nord/main/nord_install.sh) --token <token> --region DE
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/volkmax777/vps-nord/main/nord_install.sh) --key <key> --region de/berlin
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/volkmax777/vps-nord/main/nord_install.sh)   # asks for a key or token
```

Or from a local copy:

```bash
sudo bash nord_install.sh --token <token> --region DE
```

Use `bash <(curl ...)`, not `curl | bash`: with the latter stdin is taken by
the script itself, and there is nothing left to read the key from.

`--token` and `--key` on the command line are visible in `ps` and stay in the
shell history. If that matters, leave them out: the installer asks for the
value and reads it from stdin. The token itself is passed to `curl` on stdin,
not as an argument.

Installer options: `--token`, `--key`, `--region` (default `best`), `--iface`
(default `nord`), `--table` (51821), `--mtu` (1420), `--fwmark`, `--url`,
`--no-watchdog`.

### Re-running and updating

Re-running is safe: anything not given on the command line is taken from
`/etc/vps-nord/config` — key, region, interface name, table, mark. **The
server does not change:** if the tunnel is already up with the same key and
`--region` is not given (or is the same as before), the installer keeps the
live peer and only rewrites the config, so the session is not dropped.

So updating is just `vps-nord update`, and the server changes only on an
explicit command (`vps-nord region`, `vps-nord switch`) or when the watchdog
repairs an outage.

## Choosing a region

`--region` and `vps-nord region` accept:

* a country code or name: `DE`, `Germany`;
* a city: `berlin`, `de/berlin`, `germany/berlin`;
* `best` (also `auto`, `any`) — the default.

With `best` no country filter is sent. NordVPN's recommendation API then picks
servers by load and by distance from the address the request comes from — that
is, from the node itself. The exit country can therefore change from one
switch to the next. If it matters (geo-restricted services), set it
explicitly.

`vps-nord regions [pattern]` lists countries and their cities.

## Commands

```
vps-nord status              server, region, handshake, traffic, binding
vps-nord test                exit IP directly and through the tunnel
vps-nord region              current region
vps-nord region NL           change country
vps-nord region de/berlin    change city (or just berlin)
vps-nord region best         best available, no country restriction
vps-nord regions [pattern]   list countries and cities
vps-nord switch              another server in the same region
vps-nord up | down | restart
vps-nord log [n]
vps-nord key --token <t>     replace the private key
vps-nord policy status       mark rule and blackhole (with --fwmark)
vps-nord update [URL]        reinstall / update the script
vps-nord uninstall [-y]
```

### Changing servers

A region change goes through `wg syncconf`: only the peer changes, the
interface and routes are not recreated, and connections on other outbounds
are not affected. The script takes up to 10 recommendations from the API and
tries them until it sees a handshake (15 seconds per server), so a dead or
overloaded server is skipped automatically.

All servers in one NordVPN cluster share **one peer public key**. `syncconf`
with the same key would only change the endpoint and keep the old session, and
the kernel would not start a new handshake within those 15 seconds — a live
server would look dead. So the old peer is removed explicitly before the
change: a new peer with `PersistentKeepalive` sends a keepalive immediately and
the handshake starts within a second. Only a handshake **newer** than the one
before the change counts as success.

If no candidate answers, the previous server is restored, and the command says
plainly whether the tunnel is back.

Commands that change the peer (`region`, `switch`, `up`, `down`, `restart`,
`key`) and the watchdog take a lock (`/run/vps-nord/lock`), so a manual region
change never collides with the watchdog. The watchdog skips a round if the lock
is taken.

The private key is one per account, so all nodes using it count against the
account's device limit. Changing servers on a live node drops the current
session; do it when you can check the result.

## Watchdog

A timer runs `vps-nord watchdog` every 2 minutes. The probe: one `ping -I nord`
packet to 1.1.1.1, 8.8.8.8 and 9.9.9.9, stopping at the first reply; if all
three are silent, an HTTPS request to `1.1.1.1` through the same interface,
without DNS. The probe is the ground truth; the handshake is only a safety net:
if the probe failed but the handshake is fresh (under 300 seconds), the tunnel
is considered alive.

The handshake alone is never treated as a death sentence: on a lightly loaded
tunnel the timestamp ages by itself, and restarting on that would break
healthy tunnels.

The reaction is gradual: the first miss is only logged, the second restarts the
interface, the third and later switch to another server in the same region.
The pause between switches doubles from 5 minutes up to half an hour.
Everything is logged with the `vps-nord` tag.

`vps-nord down` sets a pause marker in `/run/vps-nord/paused`, and the watchdog
respects it — otherwise a tunnel stopped by hand would come back within a
couple of minutes. `up`, `restart`, a region change and a reboot clear it.

The restart takes into account that the interface may exist while the unit is
inactive (for example after a manual `wg-quick up`). `systemctl start` would
then fail with "File exists", so the interface is removed first and then
brought up by the unit.

## Routing by firewall mark (`--fwmark`)

By default the tunnel is used through interface binding only. If your Xray
outbounds select tunnels by firewall mark, install with `--fwmark <n>`. Pick a
mark, table and priority that do not clash with other tunnels on the node (for
example, if another WireGuard tunnel uses mark 255 and table 51820, use
`--fwmark 254`; vps-nord uses table 51821 and rule priority 3101).

The rule and the blackhole live in a separate `nord-policy` unit, not in the
tunnel's `PostUp`, so they stay in place while the tunnel is down. The table
always contains:

```
default dev nord scope link metric 100      ← set by the tunnel
blackhole default metric 1000               ← set by nord-policy, always there
```

While the interface is alive, metric 100 wins. When it is gone, only the
`blackhole` remains and a marked packet is not sent at all: with the interface
up, `ping -m 254` goes through the tunnel; without it the kernel returns
`connect: Invalid argument`, so marked traffic never leaks out with the node's
real IP.

`vps-nord policy up`/`down` adds the blackhole before the rule and removes it
after the rule, so there is no window in which traffic is marked but has no
route.

In the Xray profile, instead of interface binding:

```json
"streamSettings": { "sockopt": { "mark": 254, "tcpFastOpen": true } }
```

The rule comes **after** `main suppress_prefixlength 0`, so addresses with a
specific route in `main` — overlay networks (NetBird, Tailscale), docker, the
local subnet — stay direct even when marked. Only traffic for which `main` has
nothing but the default route goes into the tunnel.

The state is shown by `vps-nord status` (`Mark:` line) and in more detail by
`vps-nord policy status`.

`rp_filter` is relaxed to 2 (loose) via `/etc/sysctl.d/99-vps-nord.conf` if it
was strict — otherwise the kernel drops replies arriving on `nord`, because the
reverse path for their addresses goes through the main interface. A value of 0
(filter off) is left as is.

## What the script does not do

* **No automatic fallback.** If the tunnel is down, an outbound bound to `nord`
  simply fails to connect — traffic does not leak into the main network, but
  it is not rerouted anywhere either. Use an Xray balancer with `fallbackTag`
  if you need one.
* **No IPv6.** NordLynx manual setup gives IPv4 only, so use `ForceIPv4` in the
  outbound rather than `ForceIP`.
* **Does not touch the node's DNS.** There is no `DNS =` line, and
  `/etc/resolv.conf` stays as it is; Xray resolves with its own `dns` section.
  A `DNS =` line would not help anyway: with `Table = off` queries to it would
  bypass the tunnel.

## Diagnostics

```bash
vps-nord status          # interface binding and a fresh handshake
vps-nord test            # two IPs: the node's own and NordVPN's, with country and ISP
wg show nord
ip rule list | grep nord
ip route show table 51821
journalctl -t vps-nord -n 50
```

If `vps-nord test` shows the node's address on both lines, the binding is not
working: the `oif` rule is missing or the interface is down. If `status` shows
a fresh handshake but `test` gets no answer, it is almost always a strict
`rp_filter` (`sysctl net.ipv4.conf.all.rp_filter` should be 2).

## Testing

```bash
tests/e2e/run.sh                         # full scenario in a Debian container (podman or docker)
unshare -rn tests/handshake.sh old       # kernel check: endpoint-only change, no handshake in 15 s
unshare -rn tests/handshake.sh new       # peer re-added: handshake within ~1 s
```

The end-to-end scenario uses a local WireGuard interface as the NordVPN server
and serves the API from fixtures, so it needs no account and no network access
beyond the Debian package mirror. It covers install, a re-run, a server
switch between two servers with the same peer key, the
watchdog, the lock, `update` and `uninstall`. `handshake.sh` needs `wg` in
`PATH` (or `WG=/path/to/wg`). GitHub Actions (`.github/workflows/ci.yml`) runs
shellcheck and both tests on every push and pull request.

## Ansible

The script is idempotent, so it fits into playbooks:

```yaml
- name: Download the vps-nord installer
  ansible.builtin.get_url:
    url: https://raw.githubusercontent.com/volkmax777/vps-nord/main/nord_install.sh
    dest: /usr/local/sbin/nord_install.sh
    mode: "0755"

- name: Install vps-nord
  ansible.builtin.command:
    cmd: /usr/local/sbin/nord_install.sh --region DE
    stdin: "{{ nord_token }}"   # token on stdin — not visible in ps
    creates: /etc/vps-nord/config
  no_log: true
```

Re-running without `--token` and `--key` is safe: the private key, region and
settings are read from `/etc/vps-nord/config`.

## License

MIT — see [LICENSE](LICENSE).
