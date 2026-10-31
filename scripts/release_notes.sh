#!/bin/bash
#
# Print the Markdown release notes for the release workflow: what changed
# (git-cliff), the digests, how to consume and verify them, the toolchain
# (from the released images), and the vulnerability report.
#
# Environment: REGISTRY, VERSION, CI_DIGEST, DEV_DIGEST, IDENTITY (all
# required); PROVENANCE_VERIFY (optional: the builder's cosign verify
# commands for the signed provenance, one per line). Reads changes.md and
# scan.md from the working directory when present. STDOUT is the notes;
# messages go to STDERR.

# The uppercase names come from the environment (checked in main).
# shellcheck disable=SC2153
set -euo pipefail

readonly OIDC_ISSUER="https://token.actions.githubusercontent.com"

# shellcheck source=image/lib/log.sh
source "${BASH_SOURCE[0]%/*}/../image/lib/log.sh"

#######################################
# Print git-cliff's section for this version, minus its own
# "## [x.y.z] - date" heading.
# Outputs:
#   Markdown to STDOUT, if changes.md exists.
#######################################
print_changes() {
  [[ -f changes.md ]] || return 0
  printf '## Changes\n\n'
  sed '1{/^## \[/d}' changes.md | sed '/./,$!d'
  echo
}

#######################################
# Print the image references, floating tags, the template download and the
# verification commands.
# Globals:
#   REGISTRY, VERSION, CI_DIGEST, DEV_DIGEST, IDENTITY, OIDC_ISSUER,
#   GITHUB_REPOSITORY, PROVENANCE_VERIFY
# Outputs:
#   Markdown to STDOUT.
#######################################
print_images() {
  local dev="${REGISTRY}/dev@${DEV_DIGEST}"
  local floating="\`${VERSION%.*}\` and \`${VERSION%%.*}\`"
  local inspect="docker buildx imagetools inspect ${dev}"
  local repo="${GITHUB_REPOSITORY:-<owner>/<repo>}"
  local provenance="" commands
  if [[ -n "${PROVENANCE_VERIFY:-}" ]]; then
    # The builder prints the identity regex unquoted: zsh (and bash with
    # failglob) reject its `*` as a glob that matches nothing. Quote it, and
    # drop the blank lines the workflow's YAML block leaves.
    commands="$(sed -e '/^[[:space:]]*$/d' \
      -e "s/\(--certificate-identity-regexp\) \([^' ][^ ]*\)/\1 '\2'/" \
      <<<"${PROVENANCE_VERIFY}")"
    provenance="$(printf '%s\n%s\n\n%s\n%s\n%s\n' \
      "Each platform's provenance is also signed, by Docker's builder" \
      'workflow:' '```sh' "${commands}" '```')"
  fi
  cat <<EOF
## Images

| Image | Reference (pin this) |
|---|---|
| \`ci\` | \`${REGISTRY}/ci:${VERSION}@${CI_DIGEST}\` |
| \`dev\` | \`${REGISTRY}/dev:${VERSION}@${DEV_DIGEST}\` |

Floating tags ${floating} also point here. Consumers pin the digest.

### Start a repository

\`template.tar.gz\` is the repository template, with this release's \`dev\`
image filled in:

\`\`\`sh
gh release download v${VERSION} --repo ${repo} \\
  --pattern template.tar.gz --output - | tar -xz
./dev.sh
\`\`\`

### Verify

\`\`\`sh
cosign verify ${dev} \\
  --certificate-identity '${IDENTITY}' \\
  --certificate-oidc-issuer ${OIDC_ISSUER}
\`\`\`

SBOM and provenance (\`mode=max\`) are attached to each image index:
\`${inspect} --format '{{json .Provenance}}'\`

${provenance}

The release assets (\`template.tar.gz\`, \`CHANGELOG.md\`) have signed build
provenance, attached as \`v${VERSION}.intoto.jsonl\`:

\`\`\`sh
gh attestation verify template.tar.gz --bundle v${VERSION}.intoto.jsonl \\
  --repo ${repo} \\
  --signer-workflow ${repo}/.github/workflows/release.yml
\`\`\`

EOF
}

#######################################
# Print the toolchain table: every dev tool, and whether ci has it too.
# Globals:
#   REGISTRY, CI_DIGEST, DEV_DIGEST
# Outputs:
#   Markdown to STDOUT.
#######################################
print_toolchain() {
  local ci_tools tool tool_version where
  ci_tools="$(docker run --rm "${REGISTRY}/ci@${CI_DIGEST}" print-versions)"
  printf '## Toolchain\n\n| Tool | Version | In |\n|---|---|---|\n'
  while IFS='=' read -r tool tool_version; do
    where="dev"
    if grep -qx "${tool}=${tool_version}" <<<"${ci_tools}"; then
      where="ci, dev"
    fi
    # shellcheck disable=SC2016 # the backticks are literal Markdown
    printf '| `%s` | %s | %s |\n' "${tool#aqua:}" "${tool_version}" \
      "${where}"
  done < <(docker run --rm "${REGISTRY}/dev@${DEV_DIGEST}" print-versions)
}

#######################################
# Print the vulnerability report from scan.md, with the gate's policy.
# Outputs:
#   Markdown to STDOUT, if scan.md exists.
#######################################
print_scan() {
  [[ -f scan.md ]] || return 0
  printf '\n## Vulnerability report\n\n'
  printf '%s%s\n' \
    "Blocking: fixable CRITICAL, or fixable HIGH/CRITICAL in OS packages." \
    " Reported only: fixable HIGH"
  printf '%s%s\n' \
    "in upstream prebuilt binaries and bundled language packages" \
    " (fixed by upstream version bumps)."
  echo
  sed 's/^#### /### /' scan.md
}

main() {
  local name
  for name in REGISTRY VERSION CI_DIGEST DEV_DIGEST IDENTITY; do
    if [[ -z "${!name:-}" ]]; then
      log::fatal "${name} is not set"
    fi
  done
  print_changes
  print_images
  print_toolchain
  print_scan
}

main "$@"
