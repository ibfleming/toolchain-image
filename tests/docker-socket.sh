#!/usr/bin/env bash
# Docker outside of Docker: with the host's socket mounted at /var/run/docker-host.sock (as the
# devcontainer.json template does), docker-socket-init lets vscode use the host engine through
# /var/run/docker.sock. Also: it is idempotent, and does nothing without a host socket.
# Usage: tests/docker-socket.sh <dev image>   (needs a local Docker engine at /var/run/docker.sock)
set -euo pipefail
img="${1:?usage: $0 <dev image>}"
fail=0
ok() { echo "ok   $*"; }
bad() {
  echo "FAIL $*" >&2
  fail=1
}

cid="$(docker run -d --rm -v /var/run/docker.sock:/var/run/docker-host.sock "$img" sleep 300)"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

if docker exec -u vscode "$cid" docker version >/dev/null 2>&1; then
  bad "vscode reached the engine before docker-socket-init ran"
else
  ok "no access before docker-socket-init"
fi

docker exec -u root "$cid" docker-socket-init
docker exec -u root "$cid" docker-socket-init # second start: already serving
if [[ "$(docker exec -u root "$cid" pgrep -c -f 'socat UNIX-LISTEN')" == 1 ]]; then
  ok "idempotent: one proxy after two runs"
else
  bad "expected exactly one socat proxy"
fi

want="$(docker version --format '{{.Server.Version}}')"
got="$(docker exec -u vscode "$cid" docker version --format '{{.Server.Version}}' 2>&1 || true)"
if [[ $got == "$want" ]]; then
  ok "vscode uses the host engine ($got)"
else
  bad "vscode docker version: got '$got', want '$want'"
fi
if docker exec -u vscode "$cid" docker buildx version >/dev/null \
  && docker exec -u vscode "$cid" docker compose version >/dev/null; then
  ok "buildx and compose plugins load"
else
  bad "docker plugins missing"
fi

if docker run --rm -u root "$img" bash -c 'docker-socket-init && [[ ! -e /var/run/docker.sock ]]'; then
  ok "no host socket: does nothing"
else
  bad "docker-socket-init without a host socket"
fi

exit "$fail"
