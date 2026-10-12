#!/usr/bin/env bash
# Runs INSIDE the dev image. Switches through the contexts in a fake kubeconfig and checks
# what the starship kubernetes segment renders (text, aliases, and the prod color).
# Usage: starship-kube.sh <kubeconfig-fixture>
set -euo pipefail

# The interactive zsh config selects this file; set it here so the test also runs from plain bash.
export STARSHIP_CONFIG="${STARSHIP_CONFIG:-/usr/local/share/toolchain/starship/starship.toml}"
KUBECONFIG="$(mktemp)"
export KUBECONFIG
cp "${1:?kubeconfig fixture}" "$KUBECONFIG"
cd /tmp

# The segment is drawn in reverse video: its color is emitted as the *foreground* + inverse.
red_bg='38;2;224;108;117'    # one-dark red   #e06c75
purple_bg='38;2;198;120;221' # one-dark purple #c678dd

render() { starship prompt; }
plain() { render | sed 's/\x1b\[[0-9;]*m//g; s/%[{}]//g'; }

fail=0
check() { # context, expected text, expected background
  local ctx="$1" want="$2" bg="$3" out
  kubectl config use-context "$ctx" >/dev/null
  out="$(plain)"
  if grep -qF -- "$want" <<<"$out" && render | grep -q "$bg" \
    && ! { [[ $bg == "$red_bg" ]] && render | grep -q "$purple_bg"; }; then
    printf 'ok   %-55s -> %s\n' "$ctx" "$want"
  else
    printf 'FAIL %-55s want "%s" (bg %s)\n     got: %s\n' "$ctx" "$want" "$bg" "$(tr -s '\n' ' ' <<<"$out")"
    fail=1
  fi
}

check dev-cluster "dev-cluster (monitoring)" "$purple_bg"
check staging "staging" "$purple_bg"
check prod-us-east "󱃾 prod-us-east (payments)" "$red_bg"
check "arn:aws:eks:us-east-1:123456789012:cluster/payments-api" "eks:payments-api (default)" "$purple_bg"
check gke_acme-data-123_us-central1_analytics-main "gke:analytics-main" "$purple_bg"

# Namespace switches show up immediately. (kubens would query the API to check the namespace
# exists, so offline we edit the kubeconfig directly, which is what kubens does afterwards.)
kubectl config use-context dev-cluster >/dev/null
kubectl config set-context --current --namespace=kube-system >/dev/null
if plain | grep -qF "dev-cluster (kube-system)"; then echo "ok   namespace switch reflected in prompt"; else
  echo "FAIL namespace switch not reflected"
  fail=1
fi

# No kubeconfig at all -> segment absent.
if KUBECONFIG=/nonexistent plain | grep -qF "󱃾"; then
  echo "FAIL segment shown without kubeconfig"
  fail=1
else echo "ok   no kubeconfig -> segment hidden"; fi

rm -f "$KUBECONFIG"
exit "$fail"
