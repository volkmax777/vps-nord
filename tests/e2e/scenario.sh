#!/bin/bash
# End-to-end scenario, runs inside a Debian container (see run.sh).
#
# A local WireGuard interface plays the NordVPN server, the API is served by
# fixtures (mock/curl), systemd by mock/systemctl. Two "servers" in the fixture
# share one public key, like servers in a NordVPN cluster.
set -u
export PATH=/mock:$PATH
apt-get update -qq >/dev/null
apt-get install -y -qq wireguard-tools jq curl iproute2 iptables iputils-ping procps \
  bsdutils util-linux kmod >/dev/null 2>&1
cp /mock/curl /mock/systemctl /mock/sysctl /usr/local/sbin/   # visible to child processes too
export PATH=/usr/local/sbin:$PATH

fail=0
check() { # $1 description, rest: command
  local d=$1; shift
  if "$@"; then echo "  ok   $d"; else echo "  FAIL $d"; fail=1; fi
}

SK=$(wg genkey); SP=$(echo "$SK" | wg pubkey); CK=$(wg genkey); CP=$(echo "$CK" | wg pubkey)
mkdir -p /tmp/fixtures; echo "$CK" > /tmp/fixtures/client.key
ip link add s1 type wireguard
wg set s1 private-key <(echo "$SK") listen-port 51820 peer "$CP" allowed-ips 10.5.0.2/32
ip link set s1 up
cat > /tmp/fixtures/reco.json <<J
[{"hostname":"de1.mock","station":"127.0.0.1","load":11,"status":"online","technologies":[{"identifier":"wireguard_udp","metadata":[{"name":"public_key","value":"$SP"}]}]},
 {"hostname":"de2.mock","station":"127.0.0.2","load":12,"status":"online","technologies":[{"identifier":"wireguard_udp","metadata":[{"name":"public_key","value":"$SP"}]}]}]
J
# The host kernel already has the module; modprobe cannot run rootless.
# shellcheck disable=SC2317,SC2329  # SC2317 on shellcheck < 0.10
modprobe() { :; }; export -f modprobe
hs() { wg show nord latest-handshakes | awk '{print $2}'; }
conf() { grep "^$1=" /etc/vps-nord/config | cut -d= -f2-; }

echo "== 1. install (token on stdin)"
printf 'a%.0s' {1..64} | bash /src/nord_install.sh --region DE --fwmark 254 >/tmp/install.log 2>&1
check "installer exits 0"            grep -q 'Next, add an outbound' /tmp/install.log
check "connected to de1.mock"        test "$(conf NORD_SERVER)" = de1.mock
check "handshake present"            test "$(hs)" -gt 0
check "mark rule and blackhole"      bash -c 'vps-nord policy status | grep -q "rule yes, blackhole yes"'
check "version recorded and shown"   bash -c 'vps-nord status | grep -q "^Version: *dev$"'
check "updates from the latest release" grep -q '^NORD_SRC_URL=https://github.com/volkmax777/vps-nord/releases/latest/download/nord_install.sh$' /etc/vps-nord/config

echo "== 2. re-run without options"
h1=$(hs); sleep 2
: > /tmp/systemctl.log
ip monitor rule > /tmp/rules.log 2>&1 & mon=$!
bash /src/nord_install.sh >/tmp/rerun.log 2>&1
sleep 0.5; kill "$mon" 2>/dev/null
check "server kept"                  test "$(conf NORD_SERVER)" = de1.mock
check "session kept (same handshake)" test "$(hs)" = "$h1"
check "no DNS line in wg config"     bash -c '! grep -q ^DNS /etc/wireguard/nord.conf'
check "policy unit not restarted"    bash -c '! grep -q "restart nord-policy" /tmp/systemctl.log'
check "mark rule never removed"      bash -c '! grep -q "^Deleted.*fwmark" /tmp/rules.log'
check "mark rule still in place"     bash -c 'vps-nord policy status | grep -q "rule yes, blackhole yes"'

echo "== 3. switch to a server with the same peer key"
sleep 2
t0=$(date +%s)
vps-nord switch >/tmp/switch.log 2>&1
check "switch succeeded"             grep -q 'connected: de2.mock' /tmp/switch.log
check "took under 5 s"               test $(( $(date +%s) - t0 )) -lt 5

echo "== 4. watchdog"
vps-nord watchdog
check "healthy, fail counter 0"      test "$(cat /run/vps-nord/fails)" = 0
( flock /run/vps-nord/lock sleep 3 ) & sleep 0.5
vps-nord watchdog; rc=$?; wait
check "skips the round when locked"  test "$rc" = 0

echo "== 5. update from a local URL"
vps-nord update file:///src/nord_install.sh >/tmp/update.log 2>&1
check "server kept on update"        grep -q 'keeping the server' /tmp/update.log
check "installer copy refreshed"     cmp -s /src/nord_install.sh /usr/local/sbin/nord_install.sh

echo "== 6. uninstall"
vps-nord uninstall -y >/dev/null
check "interface removed"            bash -c '! ip link show nord >/dev/null 2>&1'
check "config removed"               test ! -e /etc/vps-nord

echo
if [[ $fail -eq 0 ]]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $fail
