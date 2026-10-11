#!/usr/bin/env bash
# Vulnerability gate + report for one image (Trivy, pinned in mise.toml).
#
# Policy:
#   BLOCK  fixable CRITICAL anywhere, and fixable HIGH/CRITICAL in OS (Debian) packages:
#          both are ours to fix (rebuild / base-digest bump / version bump).
#   REPORT fixable HIGH in third-party prebuilt binaries and bundled language packages
#          (Go binaries like k9s, npm's own deps, CPython's bundled wheels): only upstream
#          releases fix these, so they are listed (markdown on stdout) and tracked via
#          Renovate version bumps instead of being buried in an ignore file.
# Usage: scan.sh <image-ref>    (exit 1 = gate failed)
set -euo pipefail
img="${1:?image ref}"
# One Trivy pass per image (each pass exports the whole image, ~2 GB); the gate is computed
# from the JSON, so policy and report always agree.
report="$(trivy image --quiet --scanners vuln --ignore-unfixed --severity HIGH,CRITICAL --format json "$img")"

blocking="$(jq -r '
  [.Results[]? | select(.Vulnerabilities) | .Class as $c | .Target as $t | .Vulnerabilities[]
    | select(.Severity == "CRITICAL" or $c == "os-pkgs")
    | "\(.Severity)\t\(.VulnerabilityID)\t\(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)\t\($t)"]
  | unique | .[]' <<<"$report")"
gate=0
if [[ -n $blocking ]]; then
  gate=1
  echo "scan: BLOCKING findings in $img:" >&2
  echo "$blocking" >&2
fi

echo "#### \`$img\`"
echo
if [[ $gate -eq 0 ]]; then
  echo "Gate: **passed** (no fixable CRITICAL; no fixable HIGH/CRITICAL in OS packages)."
else
  echo "Gate: **FAILED** (see job log)."
fi
echo
jq -r '
  [.Results[]? | select(.Vulnerabilities) | .Target as $t
    | .Vulnerabilities[] | {t: $t, sev: .Severity}]
  | group_by(.t)
  | if length == 0 then "No fixable HIGH/CRITICAL findings."
    else (["| Component | HIGH | CRITICAL |", "|---|---:|---:|"]
      + map((.[0].t | sub("^opt/mise/installs/"; "")) as $name
          | (map(select(.sev == "HIGH")) | length) as $high
          | (map(select(.sev == "CRITICAL")) | length) as $crit
          | "| `\($name)` | \($high) | \($crit) |"))
      | join("\n") end' <<<"$report"
echo
exit "$gate"
