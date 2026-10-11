#!/usr/bin/env bash
# toolchain-firewall: the dev image's postStartCommand. A no-op unless the container was
# created with containerEnv TOOLCHAIN_FIREWALL=1; then it starts init-firewall as root
# (the only command the vscode user may run via sudo). init-firewall re-reads the setting
# from PID 1, so this wrapper's own environment cannot enable or widen anything.
set -euo pipefail

if [[ "${TOOLCHAIN_FIREWALL:-0}" != 1 ]]; then
  echo "toolchain-firewall: off (set containerEnv TOOLCHAIN_FIREWALL=1 and capAdd NET_ADMIN, NET_RAW to enable)"
  exit 0
fi
exec sudo -n /usr/local/sbin/init-firewall
