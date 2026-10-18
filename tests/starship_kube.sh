#!/bin/bash
#
# Prompt test, run INSIDE the dev image: switch through the contexts of a
# fake kubeconfig and check what the starship kubernetes segment renders
# (text, aliases, and the prod color).
#
# Usage: starship_kube.sh <kubeconfig fixture>

set -euo pipefail

readonly STARSHIP_DIR="/usr/local/share/toolchain/starship"
readonly DEFAULT_STARSHIP_CONFIG="${STARSHIP_DIR}/starship.toml"
# The segment is drawn in reverse video, so its color is emitted as the
# foreground, plus inverse.
readonly RED_BG='38;2;224;108;117'    # One Dark red #e06c75
readonly PURPLE_BG='38;2;198;120;221' # One Dark purple #c678dd
readonly KUBE_ICON=$'\U000F10FE'

# shellcheck source=image/lib/log.sh
source "${TOOLCHAIN_LIB_DIR:-/usr/local/lib/toolchain}/log.sh"

FAILED=0

#######################################
# Print the prompt starship renders, with its escape codes.
# Outputs:
#   The prompt to STDOUT.
#######################################
render() {
  starship prompt
}

#######################################
# Print the prompt as plain text: no colors, no zsh %{ %} markers.
# Outputs:
#   The text to STDOUT.
#######################################
plain() {
  render | sed 's/\x1b\[[0-9;]*m//g; s/%[{}]//g'
}

#######################################
# Switch to a context and check the segment's text and color. Prod must be
# red and nothing else.
# Globals:
#   FAILED (set on failure)
# Arguments:
#   Context, expected text, expected color (RED_BG or PURPLE_BG).
# Outputs:
#   The result to STDERR.
#######################################
check_context() {
  local context="$1"
  local want="$2"
  local color="$3"
  local text colored line
  local -i passed=0
  kubectl config use-context "${context}" >/dev/null
  text="$(plain)"
  colored="$(render)"
  if [[ "${text}" == *"${want}"* && "${colored}" == *"${color}"* ]]; then
    passed=1
  fi
  # A red (prod) segment must not also contain the default purple.
  if [[ "${color}" == "${RED_BG}" && "${colored}" == *"${PURPLE_BG}"* ]]; then
    passed=0
  fi
  if ((passed)); then
    printf -v line '%-55s -> %s' "${context}" "${want}"
    log::ok "${line}"
  else
    log::error "${context}: want \"${want}\" (color ${color}), got:" \
      "${text//$'\n'/ }"
    FAILED=1
  fi
}

#######################################
# Check that a namespace switch shows up in the prompt immediately. kubens
# would ask the API whether the namespace exists, so offline this edits the
# kubeconfig directly, which is what kubens does afterwards.
# Globals:
#   FAILED (set on failure)
#######################################
check_namespace_switch() {
  kubectl config use-context dev-cluster >/dev/null
  kubectl config set-context --current --namespace=kube-system >/dev/null
  if [[ "$(plain)" == *"dev-cluster (kube-system)"* ]]; then
    log::ok "namespace switch reflected in the prompt"
  else
    log::error "namespace switch not reflected"
    FAILED=1
  fi
}

#######################################
# Check that the segment is hidden without a kubeconfig.
# Globals:
#   FAILED (set on failure)
#######################################
check_no_kubeconfig() {
  if [[ "$(KUBECONFIG=/nonexistent plain)" == *"${KUBE_ICON}"* ]]; then
    log::error "segment shown without a kubeconfig"
    FAILED=1
  else
    log::ok "no kubeconfig -> segment hidden"
  fi
}

main() {
  local fixture="${1:-}"
  if [[ -z "${fixture}" ]]; then
    log::fatal "usage: starship_kube.sh <kubeconfig fixture>"
  fi
  # The interactive zsh config selects this file; set it here so the test
  # also runs from plain bash.
  export STARSHIP_CONFIG="${STARSHIP_CONFIG:-${DEFAULT_STARSHIP_CONFIG}}"
  KUBECONFIG="$(mktemp)"
  export KUBECONFIG
  cp "${fixture}" "${KUBECONFIG}"
  cd /tmp

  check_context dev-cluster "dev-cluster (monitoring)" "${PURPLE_BG}"
  check_context staging "staging" "${PURPLE_BG}"
  check_context prod-us-east "${KUBE_ICON} prod-us-east (payments)" \
    "${RED_BG}"
  check_context "arn:aws:eks:us-east-1:123456789012:cluster/payments-api" \
    "eks:payments-api (default)" "${PURPLE_BG}"
  check_context gke_acme-data-123_us-central1_analytics-main \
    "gke:analytics-main" "${PURPLE_BG}"
  check_namespace_switch
  check_no_kubeconfig

  rm -f "${KUBECONFIG}"
  return "${FAILED}"
}

main "$@"
