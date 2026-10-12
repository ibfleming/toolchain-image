#!/usr/bin/env bash
# Make the host's Docker engine usable by the dev user ("Docker outside of Docker").
#
# devcontainer.json mounts the host's socket at /var/run/docker-host.sock. This script runs as root
# on every container start (the image metadata's postStartCommand) and serves that socket at
# /var/run/docker.sock, owned by group `docker` (which vscode is in), through a socat proxy.
# A proxy rather than chown/chmod: the mounted socket is the host's own file, and its owner varies
# by platform (root on Docker Desktop, a host-specific docker group on Linux).
#
# Does nothing without a host socket: none mounted, or Docker-in-Docker owns /var/run/docker.sock.
set -euo pipefail
host=/var/run/docker-host.sock
sock=/var/run/docker.sock
log=/tmp/docker-socket-proxy.log

[[ -S $host ]] || exit 0
if [[ -S $sock ]] && pgrep -f "socat UNIX-LISTEN:$sock" >/dev/null; then
  exit 0 # already serving
fi

rm -f "$sock"
nohup setsid socat "UNIX-LISTEN:$sock,fork,mode=0660,user=root,group=docker" "UNIX-CONNECT:$host" \
  </dev/null >"$log" 2>&1 &
for _ in $(seq 50); do
  [[ -S $sock ]] && exit 0
  sleep 0.1
done
echo "docker-socket-init: the proxy did not start, see $log" >&2
exit 1
