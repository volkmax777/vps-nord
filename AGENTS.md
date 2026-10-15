# AGENTS.md

Guidance for AI coding agents (and humans) working on vps-nord. Read this
before changing `nord_install.sh`. User-facing documentation is in
`README.md`; this file is about *why* the code is the way it is.

## What the project is

A single Bash installer that sets up a NordVPN (NordLynx/WireGuard) tunnel on a
Debian/Ubuntu proxy node, for use as an Xray outbound. It creates a `nord`
interface that does not touch the default route, installs a `vps-nord` CLI and
a systemd watchdog. Many installs run unattended on production nodes, so
reliability and backward compatibility matter more than features.

## Layout

```
nord_install.sh          installer; the CLI is embedded in it (heredoc NORD_CLI_EOF)
README.md                user documentation
tests/e2e/run.sh         runs tests/e2e/scenario.sh in a Debian container
tests/e2e/scenario.sh    end-to-end checks (install, re-run, switch, watchdog, update, uninstall)
tests/e2e/mock/          fake NordVPN API (curl), fake systemd (systemctl), sysctl wrapper
tests/handshake.sh       kernel-level check of the peer-switch behaviour
.github/workflows/ci.yml shellcheck + both tests; release on tag v*
```

What the installer puts on a node:

| Path | What |
|---|---|
| `/usr/local/bin/vps-nord` | the CLI (written atomically: `.new` + `mv`) |
| `/usr/local/sbin/nord_install.sh` | copy of the installer, for offline reinstall |
| `/etc/vps-nord/config` | state, `NORD_*` shell variables, mode 600 (contains the private key) |
| `/etc/wireguard/<iface>.conf` | generated WireGuard config |
| `/etc/sysctl.d/99-vps-nord.conf` | rp_filter relaxation (only if it was strict) |
| `nord-watchdog.{service,timer}` | check every 2 minutes |
| `nord-policy.service` | mark rule + blackhole, only with `--fwmark` |
| `/run/vps-nord/` | `lock`, `fails`, `paused`, `last-switch`, `countries.json` cache |

## Invariants — do not break these

Each of these exists because the alternative failed in practice or in a test.

1. **The default route is never touched.** `Table = off`; the route lives in
   table 51821 (`--table`), reached by `ip rule oif <iface> priority 3100`.
   Only sockets bound to the interface (Xray `sockopt.interface`) use it.
2. **Fail closed with `--fwmark`.** The mark rule (priority 3101) and a
   `blackhole default metric 1000` live in the separate `nord-policy` unit,
   never in `PostUp`/`PostDown`: otherwise the rule disappears with the tunnel
   and marked traffic leaks with the node's real IP. The tunnel route has
   metric 100 and wins while the interface exists. `policy up` adds the
   blackhole before the rule; `policy down` removes the rule first. `PostDown`
   deletes only its own route — never flush the table. A re-run never
   restarts `nord-policy` (its stop removes the rule): it runs the idempotent
   `policy up`, which adds the rule only if missing, never del + add.
3. **Switching servers removes the old peer first** (`apply_conf`). All
   servers in a NordVPN cluster share one peer public key; `wg syncconf` with
   the same key only changes the endpoint and keeps the old session, and the
   kernel does not start a new handshake within the 15 s we wait. Removing the
   peer makes the new one (with `PersistentKeepalive`) handshake immediately.
   `tests/handshake.sh` demonstrates both cases. Keep `PersistentKeepalive`.
4. **A handshake counts only if newer than the one before the change**
   (`wait_handshake` takes the previous timestamp).
5. **Re-running the installer never changes the server.** If the interface is
   up, the key is unchanged and `--region` is not given (or unchanged), the
   installer calls the internal `vps-nord adopt`: rewrite the config, keep the
   live peer (`syncconf` *without* removing the peer). `vps-nord update` relies
   on this. Changing servers drops the session and may fail under the
   account's connection limit.
6. **The watchdog is conservative.** Probe = ICMP to 1.1.1.1/8.8.8.8/9.9.9.9
   (first reply wins), then HTTPS to 1.1.1.1 by IP. A fresh handshake (<300 s)
   counts as healthy even if the probe fails; a stale handshake alone is never
   a reason to restart. Miss 1: log; miss 2: restart the interface; miss 3+:
   switch server, with backoff 5 → 30 min. It respects `/run/vps-nord/paused`
   (set by `down`) and skips the round if the lock is taken.
7. **One lock for every command that changes the peer** (`region`, `switch`,
   `up`, `down`, `restart`, `adopt`, `key`, `watchdog`) — fd 9 on
   `/run/vps-nord/lock`.
8. **rp_filter: "no stricter than 2".** Only a strict 1 is relaxed; 0 is left
   alone. On a re-run the live value is already 2, so a line written earlier is
   kept — otherwise strict 1 returns after reboot.
9. **No `DNS=` line.** With `Table = off` queries would bypass the tunnel
   anyway, and wg-quick would rewrite the node's `/etc/resolv.conf`.
10. **Secrets stay out of argv.** The token goes to curl via `-K -` on stdin.
    Reading the key/token from stdin must also accept input without a trailing
    newline (`read ... || [[ -n $answer ]]`).
11. **Atomic writes** for the CLI, config, WireGuard config and sysctl file
    (`.new` + `mv`). Bash reads scripts while executing; overwriting the CLI in
    place breaks a running watchdog.

## Heredoc gotchas

- The CLI is in a **quoted** heredoc (`<<'NORD_CLI_EOF'`): nothing inside
  expands at install time. Values the CLI needs come from
  `/etc/vps-nord/config` at run time.
- `save_config` and the initial config use **unquoted** heredocs: never put
  backticks or `$(...)` in comments there — they run on every config write.
- With `pipefail`, never `cmd | grep -q` (or `| head`, `awk '...exit'`) on
  output that can be long: the reader exits early, the writer dies of
  SIGPIPE and the pipeline fails. Match on captured output instead
  (`has_mark_rule`, `has_blackhole`). Nodes with other VPN agents have
  long rule lists.
- Config values are written with `printf '%q'` and read by sourcing the file.
  The installer reads the old config in a subshell and re-emits `OLD_*`
  variables, so a broken config cannot clobber installer variables.

## Backward compatibility

Existing nodes upgrade with `vps-nord update` (re-runs the installer with no
arguments). Therefore:

- Keep reading every `NORD_*` key that released versions wrote. New keys must
  have defaults.
- An option that is removed must not break a config that still has it.
- Systemd unit names, the `vps-nord` log tag, table 51821 and priorities
  3100/3101 are relied on by existing installs and by users' Xray configs.
- The default update URL is the latest release
  (`releases/latest/download/nord_install.sh`); a release reaches nodes on
  their next `vps-nord update`. `main` is only what the next release will be.

## Releases

Push a tag `vX.Y.Z` on a commit of `main`. CI runs all checks on the tag and
only then the `release` job stamps `VERSION="vX.Y.Z"` into the installer and
publishes it as the release asset. In the repository `VERSION` stays `"dev"`;
the installer writes it to the config as `NORD_VERSION`, and
`vps-nord status` shows it.

## NordVPN API

Unofficial and undocumented; it may change. Used endpoints (all `v1`):

- `users/services/credentials` — Basic auth `token:<token>`, returns
  `nordlynx_private_key`.
- `servers/countries` — country and city ids (cached in `/run`, 24 h).
- `servers/recommendations?filters[servers_technologies][identifier]=wireguard_udp`
  (+ `country_id` / `country_city_id`) — ordered by load and distance from the
  caller; without a filter this is the `best` region.
- `helpers/ips/insights` — for `vps-nord test`.

The peer key is in `technologies[] | select(.identifier=="wireguard_udp") |
.metadata[] | select(.name=="public_key")`. Address is always `10.5.0.2/32`,
port 51820, IPv4 only. One private key per account; all nodes using it count
against the account's device limit.

## Conventions

- Bash with `set -euo pipefail`; `shellcheck -S style` must be clean for the
  installer, the extracted CLI and the tests.
- English only, in code, messages, logs and docs.
- Comments explain *why*, not what; keep the existing density.
- Debian/Ubuntu only (`apt-get`, `dpkg -s`), systemd required.
- Docs must not mention or compare other projects, and must not contain
  details of any particular deployment (hostnames, IPs, providers).
- Do not add features without being asked; robustness fixes are welcome.

## Testing

```bash
bash -n nord_install.sh
shellcheck -S style nord_install.sh tests/*.sh tests/e2e/*.sh tests/e2e/mock/{curl,systemctl,sysctl}
awk '/^cat > "\$CLI.new" <<.NORD_CLI_EOF.$/{f=1;next} /^NORD_CLI_EOF$/{f=0} f' nord_install.sh > /tmp/cli.sh && shellcheck -S style /tmp/cli.sh
tests/e2e/run.sh                       # podman or docker; prints ALL PASSED
unshare -rn tests/handshake.sh new     # must succeed
unshare -rn tests/handshake.sh old     # must FAIL (that is the bug being guarded against)
```

The e2e scenario mounts `tests/e2e/mock` read-only; generated keys and
fixtures go to `/tmp/fixtures` inside the container. Any behaviour change
should come with a check in `scenario.sh`. Nothing in the tests talks to the
real NordVPN API.
