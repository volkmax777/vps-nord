#!/bin/bash
# Runs the end-to-end scenario in a throwaway Debian container.
# Needs podman or docker; works rootless (NET_ADMIN inside the container's
# own network namespace is enough for a WireGuard interface).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
engine=${ENGINE:-$(command -v podman || command -v docker)} || true
[[ -n $engine ]] || { echo "need podman or docker (or set ENGINE)" >&2; exit 1; }
exec "$engine" run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
  -v "$here/mock:/mock:ro,Z" \
  -v "$here/scenario.sh:/scenario.sh:ro,Z" \
  -v "$root:/src:ro,Z" \
  "${IMAGE:-docker.io/library/debian:trixie}" /scenario.sh
