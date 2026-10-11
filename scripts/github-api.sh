#!/usr/bin/env bash
# GET a GitHub REST API path (e.g. `meta`, `repos/o/r/releases/latest`) and print the JSON.
# Authenticated when possible (5,000 req/h instead of 60): `gh` if logged in, else
# GH_TOKEN / GITHUB_TOKEN as a bearer token, else anonymous. Host/CI-side only; never in
# the dev container.
set -euo pipefail
path="${1:?api path}"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh api "$path"
elif [[ -n ${GH_TOKEN:-${GITHUB_TOKEN:-}} ]]; then
  curl -fsS -H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}" "https://api.github.com/$path"
else
  curl -fsS "https://api.github.com/$path"
fi
