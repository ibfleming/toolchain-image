#!/usr/bin/env bash
# Host-side test of the opt-in egress firewall in the dev image (needs network).
# Mirrors a real dev container: PID 1 runs as root (the image default), and every step
# runs as vscode through `docker exec`, the way VS Code runs postStartCommand and terminals.
# Covers: off by default, allow/deny when on, per-repo extras, fail-closed, and that nothing
# running as vscode can widen or remove the allowlist.
# Usage: tests/firewall.sh <dev-image>
set -euo pipefail
img="${1:?dev image}"
caps=(--cap-add NET_ADMIN --cap-add NET_RAW)
fail=0

# scenario <name> <pass|fail> <docker-run args...> -- <script run as vscode>
scenario() {
  local name="$1" want="$2" args=() got out cid
  shift 2
  while [[ $1 != -- ]]; do
    args+=("$1")
    shift
  done
  shift
  cid="$(docker run -d --rm "${args[@]}" "$img" sleep infinity)"
  if out="$(docker exec -u vscode "$cid" bash -c "$1" 2>&1)"; then got=pass; else got=fail; fi
  docker rm -f "$cid" >/dev/null
  if [[ $got == "$want" ]]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s (wanted %s, got %s)\n%s\n' "$name" "$want" "$got" "$(tail -4 <<<"$out")"
    fail=1
  fi
}

# Any HTTP response (even 404) means the connection got through.
reach() { echo "curl -sS --max-time 8 -o /dev/null $1"; }
# Use the baked GitHub ranges so ~20 firewall starts don't exhaust the API's rate limit.
on=("${caps[@]}" -e TOOLCHAIN_FIREWALL=1 -e TOOLCHAIN_FIREWALL_GITHUB=snapshot)
start='toolchain-firewall >/dev/null'

# 1. Off by default: postStartCommand is a no-op and the network is open.
scenario "off by default: example.com reachable" pass \
  -- "toolchain-firewall && $(reach https://example.com)"

# 2. On: allowlisted hosts work, everything else is rejected fast.
for url in https://api.anthropic.com https://claude.ai https://github.com https://registry.npmjs.org \
  https://pypi.org https://proxy.golang.org; do
  scenario "on: ${url#https://} reachable" pass "${on[@]}" -- "$start && $(reach "$url")"
done
# DNS-aware tracking: rotating CDN IPs (CI hit this with proxy.golang.org) and subdomains.
scenario "on: CDN host stays reachable across repeated lookups" pass "${on[@]}" \
  -- "$start && for i in 1 2 3 4 5 6; do $(reach https://proxy.golang.org) || exit 1; done"
scenario "on: subdomain of an allowlisted name reachable" pass "${on[@]}" \
  -- "$start && $(reach https://www.claude.com)"
scenario "on: example.com blocked" fail "${on[@]}" -- "$start && $(reach https://example.com)"
scenario "on: blocked request fails fast (<3s, rejected not dropped)" pass "${on[@]}" \
  -- "$start; s=\$SECONDS; ! $(reach https://example.com) 2>/dev/null; (( SECONDS - s < 3 ))"

scenario "on: default GitHub source (live API, snapshot fallback) works" pass "${caps[@]}" -e TOOLCHAIN_FIREWALL=1 \
  -- "$start && $(reach https://github.com)"

# 3. Per-repo extras from containerEnv are honored.
scenario "on + TOOLCHAIN_FIREWALL_ALLOW=example.com: reachable" pass \
  "${on[@]}" -e TOOLCHAIN_FIREWALL_ALLOW=example.com -- "$start && $(reach https://example.com)"

# 4. Tampering from inside (as vscode) cannot widen or remove the allowlist.
scenario "tamper: sudo init-firewall with arguments is refused" fail "${on[@]}" \
  -- "$start && sudo -n /usr/local/sbin/init-firewall example.com"
scenario "tamper: caller env TOOLCHAIN_FIREWALL_ALLOW is ignored" fail "${on[@]}" \
  -- "$start && TOOLCHAIN_FIREWALL_ALLOW=example.com toolchain-firewall >/dev/null && $(reach https://example.com)"
scenario "tamper: re-running the firewall keeps it closed" fail "${on[@]}" \
  -- "$start && $start && $(reach https://example.com)"
scenario "tamper: vscode cannot flush iptables" fail "${on[@]}" -- "$start && iptables -F"
scenario "tamper: vscode cannot sudo anything else" fail -- "sudo -n iptables -L"
scenario "tamper: vscode cannot bypass dnsmasq via an outside resolver" fail "${on[@]}" \
  -- "$start && dig +time=2 +tries=1 +short @1.1.1.1 example.com | grep -qE '^[0-9.]+$'"
scenario "tamper: vscode cannot rewrite /etc/resolv.conf" fail "${on[@]}" \
  -- "$start && echo 'nameserver 1.1.1.1' > /etc/resolv.conf"

# 5. Fail closed / fail loudly instead of silently running open.
scenario "on without NET_ADMIN: fails loudly" fail -e TOOLCHAIN_FIREWALL=1 -e TOOLCHAIN_FIREWALL_GITHUB=snapshot \
  -- "toolchain-firewall"
scenario "on with non-root PID 1: fails closed (no silent 'off')" fail \
  "${on[@]}" -u vscode -- "toolchain-firewall"

exit "$fail"
