#!/usr/bin/env bash
# Markdown release notes for the release workflow: what changed (git-cliff), digests, how to
# consume and verify, the toolchain manifest (from the released dev image), and the
# vulnerability report.
# Env: REGISTRY VERSION CI_DIGEST DEV_DIGEST IDENTITY; reads changes.md and scan.md if present.
set -euo pipefail
: "${REGISTRY:?}" "${VERSION:?}" "${CI_DIGEST:?}" "${DEV_DIGEST:?}" "${IDENTITY:?}"

if [[ -f changes.md ]]; then
  # git-cliff's section for this version, minus its own "## [x.y.z] - date" heading
  printf '## Changes\n\n'
  sed '1{/^## \[/d}' changes.md | sed '/./,$!d'
  echo
fi

cat <<EOF
## Images

| Image | Reference (pin this) |
|---|---|
| \`ci\` | \`$REGISTRY/ci:$VERSION@$CI_DIGEST\` |
| \`dev\` | \`$REGISTRY/dev:$VERSION@$DEV_DIGEST\` |

Floating tags \`${VERSION%.*}\` and \`${VERSION%%.*}\` also point here. Consumers pin the digest.

### Verify

\`\`\`sh
cosign verify $REGISTRY/dev@$DEV_DIGEST \\
  --certificate-identity '$IDENTITY' \\
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
\`\`\`

SBOM and provenance (\`mode=max\`) are attached to each image index:
\`docker buildx imagetools inspect $REGISTRY/dev@$DEV_DIGEST --format '{{json .Provenance}}'\`

## Toolchain

| Tool | Version | In |
|---|---|---|
EOF

ci_tools="$(docker run --rm "$REGISTRY/ci@$CI_DIGEST" print-versions)"
while IFS='=' read -r tool ver; do
  where=dev
  grep -qx "$tool=$ver" <<<"$ci_tools" && where="ci, dev"
  # shellcheck disable=SC2016 # the backticks are literal Markdown
  printf '| `%s` | %s | %s |\n' "${tool#aqua:}" "$ver" "$where"
done < <(docker run --rm "$REGISTRY/dev@$DEV_DIGEST" print-versions)

if [[ -f scan.md ]]; then
  printf '\n## Vulnerability report\n\n'
  echo "Blocking: fixable CRITICAL, or fixable HIGH/CRITICAL in OS packages. Reported only: fixable HIGH"
  echo "in upstream prebuilt binaries and bundled language packages (fixed by upstream version bumps)."
  echo
  sed 's/^#### /### /' scan.md
fi
