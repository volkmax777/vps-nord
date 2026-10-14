#!/bin/bash
# Kernel check behind the "remove the old peer before switching" logic.
#
# Two WireGuard "servers" share one private key (like a NordVPN cluster); the
# client is moved from the first to the second either the old way (only the
# endpoint changes) or the new way (peer removed and re-added). Prints how long
# the new handshake took. Runs unprivileged in a user+net namespace:
#
#   unshare -rn tests/handshake.sh <old|new> [session-age-seconds]
#
# Expected: "old" gets no handshake within 15 s, "new" gets one within ~1 s,
# for both a fresh session and one older than 2 minutes (age 130).
set -u
MODE=${1:?old|new}; AGE=${2:-3}; WG=${WG:-wg}
ip link set lo up
SK=$($WG genkey); SP=$(echo "$SK" | $WG pubkey); CK=$($WG genkey); CP=$(echo "$CK" | $WG pubkey)
for i in 1 2; do
  ip link add s$i type wireguard
  $WG set s$i private-key <(echo "$SK") listen-port 5100$i peer "$CP" allowed-ips 10.9.$i.2/32
  ip addr add 10.9.$i.1/24 dev s$i; ip link set s$i up
done
ip link add c0 type wireguard
$WG set c0 private-key <(echo "$CK") peer "$SP" endpoint 127.0.0.1:51001 allowed-ips 0.0.0.0/0 persistent-keepalive 25
ip addr add 10.9.1.2/32 dev c0; ip link set c0 up
sleep 2
ts() { $WG show c0 latest-handshakes | awk '{print $2; exit}'; }
sleep "$AGE"
ip link del s1                       # the first server goes away
prev=$(ts)
if [[ $MODE == old ]]; then
  $WG set c0 peer "$SP" endpoint 127.0.0.1:51002      # what syncconf does with the same key
else
  $WG set c0 peer "$SP" remove
  $WG set c0 peer "$SP" endpoint 127.0.0.1:51002 allowed-ips 0.0.0.0/0 persistent-keepalive 25
fi
for i in $(seq 1 15); do
  if (( $(ts) > prev )); then echo "$MODE, session ${AGE}s: new handshake after ${i}s"; exit 0; fi
  sleep 1
done
echo "$MODE, session ${AGE}s: no handshake within 15s"
exit 1
