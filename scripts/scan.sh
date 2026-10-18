#!/bin/bash
#
# Vulnerability gate and report for one image (Trivy, pinned in
# .config/mise.toml).
#
# Policy:
#   BLOCK   fixable CRITICAL anywhere, and fixable HIGH/CRITICAL in OS
#           (Debian) packages: both are ours to fix (rebuild, base-digest
#           bump, version bump).
#   REPORT  fixable HIGH in third-party prebuilt binaries and bundled
#           language packages (Go binaries like k9s, npm's own deps,
#           CPython's bundled wheels): only upstream releases fix these, so
#           they are listed (Markdown on STDOUT) and tracked through Renovate
#           version bumps rather than buried in an ignore file.
#
# Usage: scan.sh <image ref>
# STDOUT is the Markdown report; exit status 1 means the gate failed.

set -euo pipefail

# Blocking findings, one per line: severity, ID, package, target.
# shellcheck disable=SC2016 # jq variables, not shell ones
readonly JQ_BLOCKING='
  [.Results[]? | select(.Vulnerabilities) | .Class as $c | .Target as $t
    | .Vulnerabilities[]
    | select(.Severity == "CRITICAL" or $c == "os-pkgs")
    | "\(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)"
      + " \(.InstalledVersion) -> \(.FixedVersion)\t\($t)"]
  | unique | .[]'
# Findings per component, as a Markdown table.
# shellcheck disable=SC2016 # jq variables, not shell ones
readonly JQ_TABLE='
  [.Results[]? | select(.Vulnerabilities) | .Target as $t
    | .Vulnerabilities[] | {t: $t, sev: .Severity}]
  | group_by(.t)
  | if length == 0 then "No fixable HIGH/CRITICAL findings."
    else (["| Component | HIGH | CRITICAL |", "|---|---:|---:|"]
      + map((.[0].t | sub("^opt/mise/installs/"; "")) as $name
          | (map(select(.sev == "HIGH")) | length) as $high
          | (map(select(.sev == "CRITICAL")) | length) as $crit
          | "| `\($name)` | \($high) | \($crit) |"))
      | join("\n") end'

# shellcheck source=image/lib/log.sh
source "${BASH_SOURCE[0]%/*}/../image/lib/log.sh"

#######################################
# Print the Markdown report for one image.
# Globals:
#   JQ_TABLE
# Arguments:
#   Image ref.
#   Trivy's JSON report.
#   Gate result: 0 passed, 1 failed.
# Outputs:
#   Markdown to STDOUT.
#######################################
print_report() {
  local image="$1"
  local report="$2"
  local -i gate="$3"
  echo "#### \`${image}\`"
  echo
  if ((gate == 0)); then
    echo "Gate: **passed** (no fixable CRITICAL; no fixable HIGH/CRITICAL" \
      "in OS packages)."
  else
    echo "Gate: **FAILED** (see job log)."
  fi
  echo
  jq -r "${JQ_TABLE}" <<<"${report}"
  echo
}

main() {
  local image="${1:-}"
  local report blocking finding
  local -i gate=0
  if [[ -z "${image}" ]]; then
    log::fatal "usage: scan.sh <image ref>"
  fi
  # One Trivy pass per image (each pass exports the whole image, ~2 GB);
  # the gate is computed from its JSON, so policy and report always agree.
  report="$(trivy image --quiet --scanners vuln --ignore-unfixed \
    --severity HIGH,CRITICAL --format json "${image}")"
  blocking="$(jq -r "${JQ_BLOCKING}" <<<"${report}")"
  if [[ -n "${blocking}" ]]; then
    gate=1
    log::error "blocking findings in ${image}:"
    while IFS= read -r finding; do
      log::error "  ${finding}"
    done <<<"${blocking}"
  fi
  print_report "${image}" "${report}" "${gate}"
  return "${gate}"
}

main "$@"
