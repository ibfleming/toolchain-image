# Security policy

## Supported versions

Only the **latest release** is supported. Every release is rebuilt at least weekly to pick up
Debian security updates, so a fix ships in the next release rather than as a backport. Consumers
pin images by digest: move to the newest release's digest to get fixes.

## Reporting a vulnerability

Please report privately through this repository's **Security** tab → **Report a vulnerability**
([GitHub private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).
Don't open a public issue for a vulnerability.

Include what is affected (image and version or digest, from `/etc/toolchain/release` in the
container), how to reproduce it, and the impact you expect. You'll get an acknowledgement within a
week. Fixes are released as soon as they're ready, with the advisory published after the release.

## Scope

In scope:

- the `ci` and `dev` images: what they install and how (`Dockerfile`, `config/`, `image/`,
  `toolchain/`)
- the consumer template (`template/`, the `template.tar.gz` release asset)
- the release pipeline: build, the vulnerability gate, promotion by digest, signing and
  provenance (`.github/workflows/`, `scripts/`)

Out of scope: vulnerabilities in the upstream tools themselves (report those upstream; the images
pick up fixed versions through Renovate), and the `dev` image's Claude Code policy as a security
boundary (it's a default, not a boundary: `vscode` has sudo; see the README's security notes).

## How known vulnerabilities are handled

Every release passes a vulnerability gate (Trivy, `scripts/scan.sh`) before it's promoted: a
fixable CRITICAL anywhere, or a fixable HIGH/CRITICAL in OS packages, blocks it. Fixable HIGH
findings in upstream prebuilt binaries are listed in the release notes. A finding that only
upstream can fix, and that no release fixes yet, can be accepted until a date in
`.config/trivyignore.yaml` (exact binary, reason, expiry); after that date it blocks again.
