#!/usr/bin/env bash
# init-firewall: opt-in outbound allowlist for the dev container (iptables + ipset).
#
# Runs as root. The vscode user may run exactly this via sudo, with no arguments.
# Configuration comes from PID 1's environment (set at container creation by the repo's
# devcontainer.json `containerEnv`), never from the caller, so nothing running inside
# the container (an agent included) can widen its own allowlist:
#   TOOLCHAIN_FIREWALL=1                       enable (anything else: no-op)
#   TOOLCHAIN_FIREWALL_ALLOW="host cidr ..."   extra hostnames / IPv4 / IPv4 CIDRs
#   TOOLCHAIN_FIREWALL_GITHUB=snapshot         skip the live GitHub meta API, use the baked ranges
# Requires the container to have NET_ADMIN and NET_RAW (capAdd).
#
# DNS-aware: a local dnsmasq becomes the container's resolver and adds the IPs of every
# answer for an allowlisted name (and its subdomains) to the allow set as they are resolved,
# so CDN-backed hosts with rotating IPs keep working. Only dnsmasq (and root) may send
# queries upstream; everything else must resolve through it.
set -euo pipefail

ALLOWLIST=/etc/toolchain/firewall/allowlist.txt
GITHUB_SNAPSHOT=/etc/toolchain/firewall/github-ipv4.txt
SET=toolchain-allow
CHAIN_OUT=TOOLCHAIN-OUT
CHAIN_IN=TOOLCHAIN-IN
RUN_DIR=/run/toolchain-firewall

log() { echo "init-firewall: $*"; }
die() {
  echo "init-firewall: ERROR: $*" >&2
  exit 1
}
# Fail closed: if PID 1's environment can't be read (e.g. PID 1 isn't root and we lack
# CAP_SYS_PTRACE), stop with an error rather than treating the firewall as "off".
[[ $EUID -eq 0 ]] || die "must run as root"
pid1_environ="$(tr '\0' '\n' </proc/1/environ)" \
  || die "cannot read PID 1's environment; run the container with root as PID 1 (the default)"
pid1_env() { sed -n "s/^$1=//p" <<<"$pid1_environ" | head -n1; }

if [[ "$(pid1_env TOOLCHAIN_FIREWALL)" != 1 ]]; then
  log "disabled (container not created with TOOLCHAIN_FIREWALL=1)"
  exit 0
fi
extra="$(pid1_env TOOLCHAIN_FIREWALL_ALLOW)"

ipv4_re='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$'
host_re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

# Upstream resolvers come from the container's original resolv.conf, saved on the first run
# (afterwards /etc/resolv.conf points at the local dnsmasq).
mkdir -p "$RUN_DIR"
[[ -f $RUN_DIR/resolv.conf.orig ]] || cp /etc/resolv.conf "$RUN_DIR/resolv.conf.orig"
mapfile -t upstreams < <(awk '/^nameserver/ {print $2}' "$RUN_DIR/resolv.conf.orig" \
  | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -vx '127.0.0.1' || true)
[[ ${#upstreams[@]} -gt 0 ]] || die "no IPv4 upstream nameserver in $RUN_DIR/resolv.conf.orig"

domains=()
add_host() {
  local host="$1" ips
  domains+=("$host")
  ips="$(dig +short +time=3 +tries=2 "@${upstreams[0]}" A "$host" | grep -E '^[0-9.]+$' || true)"
  if [[ -z $ips ]]; then
    log "warning: $host did not resolve; skipped"
    return 0
  fi
  while read -r ip; do ipset add "$SET-new" "$ip" -exist; done <<<"$ips"
}

# 1. Build the allow set off to the side, then swap it in atomically.
ipset create "$SET-new" hash:net family inet -exist
ipset flush "$SET-new"

# GitHub's web/api/git ranges: live from the API when possible, else the snapshot baked into
# the image (`make firewall-snapshot`), so an API rate limit can't break container start.
if [[ "$(pid1_env TOOLCHAIN_FIREWALL_GITHUB)" != snapshot ]] \
  && meta="$(curl -fsS --max-time 10 https://api.github.com/meta 2>/dev/null)"; then
  github_ranges="$(jq -r '(.web + .api + .git)[] | select(contains(":") | not)' <<<"$meta")"
else
  log "using baked GitHub ranges $GITHUB_SNAPSHOT (live API skipped or unavailable)"
  github_ranges="$(grep -vE '^\s*(#|$)' "$GITHUB_SNAPSHOT")"
fi
[[ -n $github_ranges ]] || die "no GitHub ranges available"
while read -r cidr; do
  [[ $cidr =~ $ipv4_re ]] || die "invalid GitHub range: $cidr"
  ipset add "$SET-new" "$cidr" -exist
done <<<"$github_ranges"

while IFS= read -r line; do
  line="${line%%#*}"
  line="${line//[[:space:]]/}"
  [[ -z $line ]] && continue
  [[ $line =~ $host_re ]] || die "invalid hostname in $ALLOWLIST: $line"
  add_host "$line"
done <"$ALLOWLIST"

for item in $extra; do
  if [[ $item =~ $ipv4_re ]]; then
    ipset add "$SET-new" "$item" -exist
  elif [[ $item =~ $host_re ]]; then
    add_host "$item"
  else
    die "invalid TOOLCHAIN_FIREWALL_ALLOW entry: $item"
  fi
done

ipset create "$SET" hash:net family inet -exist
ipset swap "$SET-new" "$SET"
ipset destroy "$SET-new"

# 2. Our own chains (idempotent): rebuilt on every run, hooked in once.
for chain in "$CHAIN_OUT" "$CHAIN_IN"; do
  iptables -N "$chain" 2>/dev/null || iptables -F "$chain"
done

iptables -A "$CHAIN_OUT" -o lo -j ACCEPT
iptables -A "$CHAIN_OUT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Upstream DNS only for dnsmasq (and root, for seeding); everyone else uses 127.0.0.1.
for ns in "${upstreams[@]}"; do
  for owner in dnsmasq root; do
    iptables -A "$CHAIN_OUT" -d "$ns" -p udp --dport 53 -m owner --uid-owner "$owner" -j ACCEPT
    iptables -A "$CHAIN_OUT" -d "$ns" -p tcp --dport 53 -m owner --uid-owner "$owner" -j ACCEPT
  done
done
iptables -A "$CHAIN_OUT" -m set --match-set "$SET" dst -j ACCEPT
# Reject (not drop) so blocked requests fail fast instead of hanging.
iptables -A "$CHAIN_OUT" -p tcp -j REJECT --reject-with tcp-reset
iptables -A "$CHAIN_OUT" -j REJECT --reject-with icmp-admin-prohibited

iptables -A "$CHAIN_IN" -i lo -j ACCEPT
iptables -A "$CHAIN_IN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A "$CHAIN_IN" -j DROP

iptables -C OUTPUT -j "$CHAIN_OUT" 2>/dev/null || iptables -I OUTPUT 1 -j "$CHAIN_OUT"
iptables -C INPUT -j "$CHAIN_IN" 2>/dev/null || iptables -I INPUT 1 -j "$CHAIN_IN"

# IPv6 is not allowlisted: block it outright (except loopback) so it can't bypass the rules.
if ip6tables -L >/dev/null 2>&1; then
  ip6tables -P OUTPUT DROP
  ip6tables -C OUTPUT -o lo -j ACCEPT 2>/dev/null || ip6tables -I OUTPUT 1 -o lo -j ACCEPT
fi

# 3. Local resolver: dnsmasq keeps the allow set in sync with DNS answers for allowlisted
# names (and their subdomains). Restarted on every run; it re-reads the config.
{
  echo "no-resolv"
  echo "listen-address=127.0.0.1"
  echo "bind-interfaces"
  echo "user=dnsmasq"
  echo "pid-file=$RUN_DIR/dnsmasq.pid"
  echo "cache-size=1000"
  for ns in "${upstreams[@]}"; do echo "server=$ns"; done
  for d in "${domains[@]}"; do echo "ipset=/$d/$SET"; done
} >"$RUN_DIR/dnsmasq.conf"
if [[ -s $RUN_DIR/dnsmasq.pid ]]; then
  kill "$(cat "$RUN_DIR/dnsmasq.pid")" 2>/dev/null || true
  sleep 0.5
fi
dnsmasq --conf-file="$RUN_DIR/dnsmasq.conf" || die "dnsmasq failed to start"
{
  echo "# Managed by init-firewall: resolve through the local, allowlist-aware dnsmasq."
  echo "nameserver 127.0.0.1"
  grep -E '^(search|options)' "$RUN_DIR/resolv.conf.orig" || true
} >/etc/resolv.conf

# 4. Self-check: an allowed host works, an arbitrary one does not.
curl -sS --max-time 10 -o /dev/null https://api.github.com/zen || die "self-check failed: api.github.com unreachable"
# The negative probe only means something if the probe host isn't itself allowlisted
# (a repo may legitimately allow it via TOOLCHAIN_FIREWALL_ALLOW).
probe=example.com
probe_ip="$(dig +short +time=3 +tries=2 "@${upstreams[0]}" A "$probe" | grep -E '^[0-9.]+$' | head -n1 || true)"
if [[ -n $probe_ip ]] && ! ipset test "$SET" "$probe_ip" 2>/dev/null; then
  if curl -sS --max-time 5 -o /dev/null "https://$probe" 2>/dev/null; then
    die "self-check failed: $probe is reachable"
  fi
fi
ranges="$(ipset list "$SET" | grep -c '^[0-9]')"
log "enabled: $ranges allowed ranges, ${#domains[@]} DNS-tracked names; self-check passed"
