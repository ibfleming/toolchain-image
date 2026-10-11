#!/usr/bin/env bash
# Print GitHub's web/api/git IPv4 ranges (https://api.github.com/meta), one per line, sorted.
# Authenticated when possible (5,000 req/h instead of 60): `gh` if logged in, else
# GH_TOKEN / GITHUB_TOKEN as a bearer token, else anonymous. /meta is public, so a
# fine-grained token with no permissions is enough. Host-side only; never in containers.
set -euo pipefail

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  meta="$(gh api meta)"
elif [[ -n ${GH_TOKEN:-${GITHUB_TOKEN:-}} ]]; then
  meta="$(curl -fsS -H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}" https://api.github.com/meta)"
else
  meta="$(curl -fsS https://api.github.com/meta)"
fi
jq -r '(.web + .api + .git)[] | select(contains(":") | not)' <<<"$meta" | sort -uV
