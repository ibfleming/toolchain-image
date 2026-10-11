# One Image Family, Two Front Doors: A Reference Design for Shared CI/CD Builder and Dev Container Images (October 2026)

> **Design record.** Original research behind this project (October 2026), kept for its
> reasoning and sources. It was written for one developer's setup, and parts are superseded:
> see [the design index](README.md) for where the implementation deliberately differs.

The best-practice design is **one Dockerfile with named multi-stage targets, `base → ci → dev`, where `dev` is built `FROM ci`**. It is built from a single pinned version manifest in one `docker buildx bake` run, then scanned, given an SBOM and provenance, signed, and published by digest. CI jobs consume `ci`. Dev containers consume `dev` through a thin `devcontainer.json`. The production runtime image is kept completely separate and minimal. Because `dev` inherits from `ci`, the CI toolchain is a strict subset of the dev toolchain by construction, not by convention. That is the only reliable way to make "works in the devcontainer" imply "works in CI".

## TL;DR

- **Architecture:** use a single multi-stage Dockerfile with targets `base` (OS, CA certs, users), `ci` (the pinned toolchain only, no dev conveniences) and `dev` (`FROM ci`, plus shells, debuggers and editor glue). Build both from the same commit and base digest with `docker buildx bake`, and tag and promote them together. The app's runtime image is a separate, distroless or hardened image that never contains the toolchain.
- **Reproducibility and supply chain:** pin the base image by digest, and pin every tool to an exact version with checksums in one manifest (`mise.toml` plus `mise.lock`, or annotated `ARG`s). Let Renovate or Dependabot raise the update PRs, rebuild weekly, and generate SBOM plus `mode=max` provenance with BuildKit. Sign by digest with cosign keyless, scan with Trivy or Grype, and have consumers pin by digest.
- **Platform reality:** GitHub Actions and Azure DevOps container jobs effectively expect the image's default user to be root and no custom `ENTRYPOINT`. GitLab needs `sh`/`bash` and `grep`, plus an empty or shell entrypoint. So the `ci` target stays root-by-default with no entrypoint, while the `dev` target declares a non-root `vscode` user (UID 1000) through dev container metadata. Get least privilege in CI from ephemeral, unprivileged runners and rootless BuildKit or Buildah, not from the image's `USER` line.

## Key Findings

**Established consensus (well-sourced):**
- Docker's own build guidance says to pin base images, and "to fully secure your supply chain integrity, you can pin the image version to a specific digest." It recommends Dependabot's `docker` ecosystem to "raise pull requests to update your base image tags and digests on a schedule."\[1\]
- BuildKit attestations: provenance at `mode=min` is added by default, and SBOM is opt-in (`--sbom=true`). Docker recommends `mode=max` provenance. The classic `docker` driver can silently drop attestations, so use a `docker-container`, `kubernetes` or `remote` builder.\[2\]\[3\]\[4\]
- Reproducible timestamps: the Dockerfile frontend has consumed `SOURCE_DATE_EPOCH` as a special build arg since BuildKit 0.11. `rewrite-timestamp=true` on the image exporter (BuildKit v0.13+) applies it to file timestamps inside layers. It is off by default because of the overhead.\[5\]\[6\]
- The Dev Container spec supports a `devcontainer.metadata` image label. The CLI, the GitHub Action and the Azure DevOps task add it automatically when prebuilding, so a repo's `devcontainer.json` can be reduced to little more than `"image": ...`. Features are pinned by a `devcontainer-lock.json` (the CLI generates it by default; `--frozen-lockfile` enforces it).\[7\]\[8\]\[9\]\[10\]\[11\] Dependabot has a `devcontainers` ecosystem that updates Features and the lockfile.\[12\]
- Kaniko's original repository was archived by Google on June 3, 2025, and Google's last release was v1.24.0. GitLab's docs now cover BuildKit and rootless Buildah for image builds. Treat Kaniko as legacy: the Chainguard fork (chainguard-forks/kaniko) states that "Binary release artifacts such as container images are not published" except to Chainguard customers.

**Opinion (my recommendation, with reasoning):**
- Bake tools into the image. Do not install them at container start with version managers or Features. A version manager is best used as the *manifest format and installer at image build time*, not as a runtime resolver.
- Use Debian 13 (trixie) slim, pinned by digest, as the default base. Use Wolfi/Chainguard or Docker Hardened Images (DHI) `-dev` variants only if you are prepared for their different package ecosystems and user conventions. Do not use Alpine for builder or dev images.
- Use one polyglot image only while the toolchain is small and shared, as is typical for a freelance/homelab estate. Split per language family when image size, rebuild blast radius or CVE noise starts to hurt.

## Details

### 1. Architecture: why multi-stage targets with `dev FROM ci`

| Pattern | Parity guarantee | Maintenance | Verdict |
|---|---|---|---|
| Single image for both | Perfect parity | Dev bloat ships to CI; CI gains a larger attack surface | Acceptable only for tiny toolchains |
| Separate Dockerfiles per image | Drift-prone (two sources of truth) | High | Anti-pattern |
| Layered family across repos (`base` repo → `toolchain` repo → `dev` repo) | Good if digests are chained | Cross-repo release choreography | Use at org scale |
| **One Dockerfile, targets `base → ci → dev`, `dev FROM ci`** | **Strict subset by construction** | **Low; one PR updates both** | **Recommended** |

The key property is that `dev` is *derived* from `ci` and is never independently assembled. Any tool in CI is, byte for byte, the same file in the dev container, because it sits in a shared layer. Dev-only additions (zsh, gdb, `sudo`, editor helpers) can only be *added*, never substituted. Enforce this in tests (see §9): extract the tool version list from both images and fail the build if any shared tool differs, or if `dev` is missing a `ci` tool.

**Runtime/production image:** this lives in the *application* repo as its own final stage. It uses the `ci` image (or a language `-dev` image) as the build stage, then copies artifacts into a distroless, Chainguard or DHI runtime base. Chainguard explicitly recommends "using multi-stage builds to copy artifacts from the -dev variant into a more minimal production image."\[13\] Distroless images are unsuitable as *builders* (no shell or package manager), but they are ideal as the runtime target.\[14\]

**Diagram (text description):**

```
             versions manifest (mise.toml + mise.lock / ARGs)   base digest pin
                               │                                   │
                               ▼                                   ▼
 ┌──────────────── toolchain-images repo (one Dockerfile, one bake run) ───────────────┐
 │  stage base : debian:trixie-slim@sha256:… + CA certs, locales, git, users            │
 │       │                                                                              │
 │  stage ci   : base + pinned toolchain (kubectl, helm, terraform/opentofu, node, go…) │──► registry/toolchain/ci:1.8.0  (@sha256:A)
 │       │                                                                              │
 │  stage dev  : FROM ci + zsh, gdb, sudo, devcontainer.metadata label                   │──► registry/toolchain/dev:1.8.0 (@sha256:B)
 └──────────────────────────────────────────────────────────────────────────────────────┘
        │ hadolint → bake (amd64+arm64, registry cache) → structure tests → Trivy gate
        │ → SBOM + provenance(mode=max) → cosign sign (keyless) → promote tags
        ▼
 Consumers: GitHub/Azure DevOps/GitLab/Jenkins jobs pin ci@sha256:A
            app repos' .devcontainer/devcontainer.json pin dev@sha256:B
            app Dockerfile: build stage FROM ci@sha256:A → runtime FROM distroless/DHI
```

### 2. Dev Container spec: prebuild, metadata, and Features vs. baking

- **Prebuild the `dev` image; never build per developer.** VS Code's docs describe putting a "more complex" devcontainer.json in the prebuild and a "dramatically simplified one" in each repo, merged at create time. The spec defines the label as "an array of metadata snippets", and says "the devcontainer.json is considered last" when order matters.\[9\]\[10\]\[15\]
- **Two ways to attach metadata:** (a) build `dev` with `devcontainer build` (or `devcontainers/ci`), which writes the label for you; or (b) add a `LABEL devcontainer.metadata='[...]'` manually in the `dev` stage so bake stays the single build tool.\[9\]\[16\] I prefer (b) for this design, because the label is then reviewable in the Dockerfile and both targets come from one bake invocation. Use (a) only if you rely on Features.
- **Don't put secrets in `remoteEnv` in a prebuilt config.** The reference CLI writes `remoteEnv` into the image label by default, so anyone who can pull the image can read it. (This comes from a CLI flag-default analysis, not from the main spec text.)\[15\]
- **Features vs. Dockerfile:** Features are convenient, but they are opaque install scripts, often pulled by mutable major tags (`:1`, `:2`) and resolved at build time.\[17\] Use them only in the `dev` stage, only for dev conveniences, with a committed `devcontainer-lock.json` and `--frozen-lockfile` in CI.\[11\]\[17\]\[18\]\[19\] Install toolchain components shared with CI in the `ci` stage itself, so CI never depends on Feature resolution.
- **Same image in CI:** `devcontainers/ci` (GitHub Action and Azure DevOps task) can build or pull the dev container and run commands in it, with BuildKit cache via `cacheFrom`.\[16\] That is a valid alternative for teams that want CI to literally be the devcontainer. With the `ci`/`dev` split, though, using the native `container:` or `image:` job keyword with `ci@sha256` is simpler, faster and avoids the dev-only surface.

### 3. Version pinning and the single source of truth

- **Base image:** `FROM debian:trixie-slim@sha256:<index-digest>` (tag kept for readability, digest for integrity). Use the multi-arch *index* digest so amd64 and arm64 both resolve.\[20\]\[21\]
- **Tool manifest (pick one; don't mix):**
  - **Option A (recommended): `mise.toml` plus a committed `mise.lock`, installed at image build time with `mise install --locked`.** The lockfile "pins exact versions and checksums of tools", and the strict `locked` mode "prevents API calls to GitHub, aqua registry, etc." mise's author Jeff Dickey notes (jdx.dev, March 2026) that only 39 of the 919 tools in the registry default to a plugin-based backend (about 4%). Most install via the aqua backend, which verifies checksums and can verify cosign, SLSA and GitHub attestations. Developers get the same manifest outside containers if they want it, but the image is the contract.
  - **Option B: annotated `ARG`s** (`# renovate: datasource=github-releases depName=hashicorp/terraform` followed by `ARG TERRAFORM_VERSION=…`) plus a `*_SHA256` ARG verified with `sha256sum -c`. Renovate's built-in `customManagers:dockerfileVersions` preset matches exactly this comment and `ARG`/`ENV …_VERSION` convention.\[22\]\[23\]
- **apt packages:** pinning exact Debian package versions (`pkg=1.2.3-1`) breaks as soon as the archive moves on. The honest choices are: pin the base digest and accept that the security archive moves; or for true rebuildability, point apt at `snapshot.debian.org` keyed to `SOURCE_DATE_EPOCH` (the BuildKit maintainer's `repro-sources-list.sh` approach).\[24\] Keep apt usage minimal and put versioned toolchain items in the manifest.
- **Checksums/GPG:** never use `curl | sh`. Download a pinned release, verify the SHA-256 (or cosign or GPG signature where the vendor publishes one), then install.
- **Reproducible builds:** set `SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)` and export with `rewrite-timestamp=true`.\[6\]\[25\] Be realistic, though: bit-for-bit reproducibility of a large builder image is hard. The practical goal is "every input pinned, every output traceable via provenance", with reproducibility verified for the `ci` stage if you have the appetite.
- **Nix/devbox/Flox:** this is the most rigorous route to hermetic toolchains. It is worth it if your team already speaks Nix. Otherwise it brings a steep learning curve and a second packaging universe. I would not adopt it just for this problem.

### 4. Base image choice

| Base | libc | Builder/dev suitability | Notes |
|---|---|---|---|
| **Debian 13 trixie-slim** | glibc | **Best default** | Broadest binary compatibility; apt; stable cadence |
| Ubuntu 24.04/26.04 | glibc | Good | Ships an `ubuntu` user at UID 1000, which collides with dev container UID remapping (see §6). Delete or renumber it\[26\]\[27\] |
| Microsoft `devcontainers/base` | glibc | Great for `dev`; awkward as `ci` | Default `debian` tag is trixie; non-root `vscode` user (UID 1000) with sudo and zsh/Oh My Zsh.\[28\] Using it as `ci` drags dev conveniences into CI |
| Wolfi / Chainguard `-dev` | glibc | Viable | glibc, apk, daily rebuilds, low CVE counts; BusyBox ash by default and a different package naming scheme.\[29\]\[30\]\[31\] Free tier tags are limited\[32\] |
| Docker Hardened Images `-dev` | glibc (Debian) or musl (Alpine) | Viable | More than 1,000 images made free and open source under Apache 2.0 on Dec 17, 2025 (commercial launch was May 2025); `-dev` tags include a shell and package manager |
| Alpine | musl | **Avoid for builders** | musl breaks prebuilt glibc binaries; Azure DevOps needs Node plus extra packages and a label; GitHub's container hooks special-case `isAlpine`\[33\]\[34\] |
| UBI | glibc | Good in RHEL/OpenShift shops | dnf; subscription-aware content |
| Distroless | — | **Never as builder** | Runtime only |

### 5. Building the image itself

- **docker buildx bake** with one `docker-bake.hcl`: a `_common` target (platforms `linux/amd64` and `linux/arm64`, attestations, labels, `SOURCE_DATE_EPOCH`) inherited by `ci` and `dev` targets.\[35\]\[36\] Bake builds targets in parallel and shares the `base`/`ci` layers.\[36\]\[37\]
- **Multi-arch:** build arm64 *natively* where you can (an arm64 runner, or a remote BuildKit on an arm64 node). QEMU emulation of compiler-heavy stages is slow. The per-platform outputs combine into one index.
- **Caching:** `cache-to=type=registry,ref=…:buildcache,mode=max` for CI, and `RUN --mount=type=cache,target=/var/cache/apt` (with `sharing=locked`) for package caches.\[35\]\[38\] Don't let developer laptops write to the shared cache.\[39\]
- **Versioning:** use semver for the image *contract*. Major means a tool removed or a breaking upgrade (e.g., Terraform major). Minor means a tool added or a minor bump. Patch means a rebuild for OS patches or a tool patch. Release tags (`1.8.0`) are immutable (enable tag immutability in the registry). `1.8` and `1` float. Consumers pin `@sha256` and let Renovate bump them. Never let anything consume `latest`.
- **Promotion:** build once, push to a `staging/` path, run the tests and scan gates, then *copy by digest* to `release/` (`crane copy` or `docker buildx imagetools create`), never rebuild. Signatures and attestations follow the digest.
- **Rebuild cadence:** schedule a weekly rebuild (Chainguard images are rebuilt daily).\[31\] Also rebuild on base-digest PRs and critical CVEs. A scheduled rebuild with no manifest changes produces a new patch version.

### 6. Security and supply chain

- **Users and UIDs:** create `vscode` (UID/GID 1000) in `base`. On Linux, the dev container tooling remaps the remote user's UID/GID to the host user's to avoid bind-mount permission problems (`updateRemoteUserUID`, default true). It only applies at container creation, and it *does not update the UID when another user already has it*. This is exactly the Ubuntu 24.04 `ubuntu`-user trap,\[27\]\[40\] so ensure exactly one regular user exists. On macOS and Windows, Docker Desktop's file sharing hides most of this.\[40\]
- **CI user, the honest trade-off:** GitHub's docs say container actions "must be run by the default Docker user (root)".\[41\] In actions/checkout issue #956, filed after the v3.1.0 rollout, the maintainers wrote that "running a container using a container user that is not 'root' is an unsupported path", and it breaks writes to `/__w` and `$GITHUB_ENV` (actions/runner issue #4302 reports container jobs failing with permission denied on `GITHUB_ENV` and the workspace after upgrading from v2.330.0 to v2.332.0). Microsoft Learn's container-jobs page requires a `USER` "provided with access to groupadd and other privileged commands without using sudo", because the agent creates its own user at job start, and it warns: "No ENTRYPOINT. Containers with an ENTRYPOINT might not work, because docker exec expects the container to always be running." So the `ci` image keeps root as its default user and sets no `ENTRYPOINT`. Get your least privilege from: ephemeral, single-job runners; no `--privileged`; no host Docker socket; Kubernetes `securityContext` (`runAsNonRoot`, dropped capabilities) where the platform supports it (GitLab Kubernetes executor, Jenkins pod templates, ARC Kubernetes mode); and short-lived OIDC credentials instead of stored secrets.
- **Building images inside CI jobs:** rank the options. (1) Remote or rootless **BuildKit** (buildx `kubernetes`/`remote` driver, or `moby/buildkit:rootless` with `buildctl-daemonless.sh`).\[42\]\[43\] (2) Rootless **Buildah**, which GitLab documents and which is native to OpenShift.\[44\]\[45\] (3) Docker-outside-of-Docker (socket mount), which is root-equivalent on the host and acceptable only on single-tenant, ephemeral VMs. (4) Docker-in-Docker, which needs privileged containers (ARC's `containerMode: dind` runs a privileged daemon sidecar).\[46\]\[47\] Rootless BuildKit in Kubernetes often needs `--oci-worker-no-process-sandbox`, which is a real isolation trade-off.\[48\]
- **Secrets:** use `RUN --mount=type=secret,id=…` only. Never `ARG`/`ENV` a secret. With `mode=max` provenance, build-arg values are *published in the attestation*.\[3\]
- **Scan, SBOM, sign:** use a Trivy (or Grype) gate on fixable CRITICAL/HIGH findings, with a reviewed `.trivyignore` that has expiries. Generate the BuildKit SBOM (Syft-based scanner) plus provenance.\[49\] Sign with `cosign sign --yes <image>@sha256:…` using GitHub OIDC (`id-token: write`).\[50\]\[51\] Consumers verify with `--certificate-identity` pinned to your release workflow ref and `--certificate-oidc-issuer https://token.actions.githubusercontent.com`. \[52\]\[53\]\[54\] Never verify with `--certificate-identity-regexp '.*'`.
- **SLSA/OpenSSF:** BuildKit provenance on a hosted, ephemeral builder gets you close to SLSA Build L2. L3 needs a hardened, isolated builder whose signing material is inaccessible to the build steps. Pin GitHub Actions to commit SHAs (an OpenSSF Scorecard "Pinned-Dependencies" check) and pin `FROM` lines by digest.\[55\] Use CIS Docker Benchmark items such as health checks and no secrets in layers as review checklist input, recognizing that many of them target runtime containers, not builder images.

### 7. CI agent specifics

| Platform | How to consume | Image requirements / gotchas |
|---|---|---|
| **GitHub Actions** | `container: image: …/ci@sha256:A` on Linux runners | Runner mounts the workspace at `/__w/…` and overrides workdir. No `ENTRYPOINT`. Default step shell is `sh`, so set `defaults.run.shell: bash`. Root default user. On ARC, set `containerMode` to `dind` (privileged) or `kubernetes` (container hooks, needs a work volume, no privileged daemon)\[47\]\[56\] |
| **Azure DevOps** | `resources.containers` + `container:` | glibc so the agent's Node runs. Provide `bash`, `sudo`, `which`, `groupadd`. User must be able to run `groupadd` without sudo. Non-glibc images need their own Node plus the `com.azure.dev.pipelines.agent.handler.node.path` label. Classic pipelines don't support container jobs\[34\]\[57\] |
| **GitLab CI** | `image: name: …/ci@sha256:A`, `entrypoint: [""]` | Image needs `sh` or `bash` and `grep`. Scripts run in `/builds/<project>`, not your `WORKDIR`. `image@digest` is supported natively\[58\] |
| **Jenkins (Kubernetes plugin)** | Pod template: `jnlp` (inbound-agent) container + your `ci` container, steps in `container('ci')`\[59\] | Don't bake the Jenkins agent into the toolchain image. Keep the agent sidecar separate so agent upgrades don't force toolchain releases. Use `command: sleep infinity`-style long-running args |

**Ephemeral vs. long-lived agents:** use ephemeral, one job per runner (ARC scale sets, GitHub `--ephemeral`, autoscaled GitLab runners, Jenkins pods). Long-lived agents accumulate state and root-owned workspace files, and they make "works on CI" depend on agent history.\[60\]\[61\]

**Run as job container vs. bake the agent in:** run the toolchain image *as the job container* and let the platform inject its agent. Baking the runner into the image couples two release cycles. Only do it where the platform requires it (e.g., a custom ARC runner image when you can't use container jobs).

**Proxmox homelab (opinion):** run a small k3s or Talos cluster on Proxmox VMs with ARC scale sets (`minRunners: 0`) or GitLab's Kubernetes executor. Add Harbor or Zot as a local registry with a Docker Hub pull-through cache and tag immutability, and a rootless BuildKit deployment for image builds. This gives you ephemeral, unprivileged builds on hardware you control.

### 8. Size vs. completeness, and golden-image anti-patterns

- **Kitchen-sink images** (every language, every cloud CLI) produce 5–10 GB pulls, huge CVE surfaces, slow rebuilds and an owner nobody can find. Every tool must have a consumer and an owner in the manifest.
- **Drift:** this happens when repos `apt install` extra tools in CI steps or `postCreateCommand`. Policy: if it's needed in both places, it goes in `ci`. If it's dev-only, it goes in `dev`. Never install it at job runtime.
- **`latest` tags, mutable tags in consumers, and "rebuild on demand by hand"** are all anti-patterns. Use digests, Renovate and a schedule.
- **Split heuristic (opinion):** start with one `ci` image for a small estate. Split into `toolchain-infra` (terraform/opentofu, kubectl, helm, cloud CLIs) and per-language-family images (`toolchain-node`, `toolchain-go`, `toolchain-jvm`) sharing the same `base` when any of these holds: the image exceeds about 2–3 GB; one language's upgrade cadence blocks others; or teams fight over versions. A polyglot repo can use a multi-container dev setup or Compose rather than one giant image.

### 9. Testing the image

- **Hadolint** in pre-commit and CI. DL3008, DL3018 and similar rules flag unpinned packages,\[62\] so tune the apt rules to match your policy rather than fake-pinning.
- **container-structure-test** (still maintained; v1.22.1 released Dec 2025) with `commandTests` asserting `expectedOutput` regexes such as `Terraform v1\.9\.8`.\[63\]\[64\] Better still, *generate* the test file from the manifest so versions are never duplicated by hand. **goss/dgoss** (v0.4.10, July 2026) is a good alternative,\[65\]\[66\] and nicer for process, port and file-permission checks.
- **Parity test:** run `mise ls --json` (or a `versions.sh` that prints `tool=version`) in both `ci` and `dev`. Assert that `ci ⊆ dev` with identical versions, and that both equal the manifest.
- **Platform smoke tests:** a matrix job that actually runs the image as a GitHub container job, a GitLab job and an Azure DevOps container job, runs `actions/checkout`, writes `$GITHUB_ENV`, and builds a sample project. This catches the user and entrypoint regressions described above.
- **Dev container smoke test:** `devcontainer up` plus `devcontainer exec` on a Linux runner with a non-1000 host UID, to exercise UID remapping.

### 10. Governance

- **Ownership:** a named platform owner (for you, that's you), `CODEOWNERS` on the manifest, and every tool entry annotated with its consumer.
- **Registry layout:** `registry.example.com/toolchain/{ci,dev}` (plus `/staging/` for unpromoted builds) and `…/toolchain/buildcache`. Turn on immutable tags and keep signatures and attestations next to the images.
- **Retention/deprecation:** keep every released digest for at least as long as you need to rebuild old releases (for example 12–18 months). Support N and N-1 minor versions, publish an end-of-life date when a major lands, and garbage-collect untagged staging digests after 30 days.
- **Documentation:** auto-generate a `CHANGELOG.md` and a `TOOLS.md` (tool, version, owner) from the manifest for every release, and attach the SBOM.
- **Consumption and updates:** consumers pin `@sha256` and receive Renovate PRs. Changes to the image go through a PR to the toolchain repo. A one-off need goes in the consuming repo's own Dockerfile `FROM ci@sha256`, never in a fork of the image.

## Reference implementation

### Repository layout

```
toolchain-images/
├── Dockerfile                  # stages: base, ci, dev
├── docker-bake.hcl
├── mise.toml                   # single source of truth for tool versions
├── mise.lock                   # exact versions + per-platform checksums (committed)
├── scripts/
│   ├── install-apt.sh          # minimal OS packages
│   └── print-versions.sh       # emits tool=version for parity tests
├── tests/
│   ├── ci.structure.yaml       # generated from mise.lock
│   └── dev.structure.yaml
├── devcontainer/
│   └── devcontainer.json       # template for consuming repos
├── .hadolint.yaml
├── .trivyignore
├── renovate.json
├── CODEOWNERS
├── TOOLS.md / CHANGELOG.md     # generated
└── .github/workflows/release.yml
```

### Dockerfile skeleton

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=debian:trixie-slim@sha256:<index-digest>   # Renovate/Dependabot bump

FROM ${BASE_IMAGE} AS base
ARG SOURCE_DATE_EPOCH
ARG USERNAME=vscode USER_UID=1000 USER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git bash grep sudo which passwd gnupg unzip xz-utils jq \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME}

FROM base AS ci
# Pinned, checksum-verified mise binary; then locked toolchain install
ARG MISE_VERSION=2026.10.0
ARG MISE_SHA256_AMD64=<sha256> MISE_SHA256_ARM64=<sha256>
ARG TARGETARCH
RUN set -eux; arch="${TARGETARCH/amd64/x64}"; \
    curl -fsSLo /usr/local/bin/mise "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${arch}"; \
    sum="$([ "$TARGETARCH" = amd64 ] && echo "$MISE_SHA256_AMD64" || echo "$MISE_SHA256_ARM64")"; \
    echo "${sum}  /usr/local/bin/mise" | sha256sum -c -; chmod +x /usr/local/bin/mise
ENV MISE_DATA_DIR=/opt/mise MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml MISE_LOCKED=1 \
    PATH=/opt/mise/shims:$PATH
COPY mise.toml /etc/mise/config.toml
COPY mise.lock /etc/mise/mise.lock
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN \
    mise install --locked && mise reshim && chmod -R a+rX /opt/mise
COPY scripts/print-versions.sh /usr/local/bin/print-versions
LABEL org.opencontainers.image.title="toolchain-ci" \
      org.opencontainers.image.source="https://github.com/you/toolchain-images"
# Intentionally: no USER (root default for GHA/Azure DevOps), no ENTRYPOINT, no WORKDIR

FROM ci AS dev
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      zsh vim less procps gdb openssh-client bash-completion \
    && echo "vscode ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/vscode && chmod 0440 /etc/sudoers.d/vscode
LABEL org.opencontainers.image.title="toolchain-dev" \
      devcontainer.metadata='[{"remoteUser":"vscode","updateRemoteUserUID":true,"customizations":{"vscode":{"extensions":["hashicorp.terraform","redhat.vscode-yaml"]}}}]'
```

(The image ships root with `remoteUser: vscode` in metadata, the same pattern Microsoft's own devcontainer base images use.)\[26\]

### docker-bake.hcl

```hcl
variable "REGISTRY" { default = "registry.example.com/toolchain" }
variable "VERSION"  { default = "0.0.0-dev" }
variable "SOURCE_DATE_EPOCH" { default = "0" }

target "_common" {
  context   = "."
  platforms = ["linux/amd64", "linux/arm64"]
  args      = { SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH }
  attest    = ["type=provenance,mode=max", "type=sbom"]
  secret    = ["id=github_token,env=GITHUB_TOKEN"]
  labels    = { "org.opencontainers.image.version" = VERSION }
}
target "ci" {
  inherits   = ["_common"]
  target     = "ci"
  tags       = ["${REGISTRY}/staging/ci:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:ci"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:ci,mode=max"]
}
target "dev" {
  inherits   = ["_common"]
  target     = "dev"
  tags       = ["${REGISTRY}/staging/dev:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:ci", "type=registry,ref=${REGISTRY}/buildcache:dev"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:dev,mode=max"]
}
group "default" { targets = ["ci", "dev"] }
```

### Consuming repo: `.devcontainer/devcontainer.json`

```jsonc
{
  "name": "project",
  "image": "registry.example.com/toolchain/dev:1.8.0@sha256:<B>",
  // remoteUser, extensions etc. come from the image's devcontainer.metadata label
  "mounts": ["source=project-cache,target=/home/vscode/.cache,type=volume"],
  "postCreateCommand": "print-versions",   // no tool installs here, by policy
  "customizations": { "vscode": { "settings": { "terminal.integrated.defaultProfile.linux": "zsh" } } }
}
```

### Release pipeline (GitHub Actions; pin every action to a commit SHA in real use)

```yaml
name: release-toolchain
on:
  push: { tags: ["v*.*.*"] }
  schedule: [{ cron: "0 4 * * 1" }]     # weekly patch rebuild
  workflow_dispatch: {}
permissions: { contents: read, packages: write, id-token: write }
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - run: docker run --rm -i hadolint/hadolint:<ver>@sha256:<d> < Dockerfile
      - uses: docker/setup-qemu-action@<sha>         # or native arm64 runners/remote BuildKit
      - uses: docker/setup-buildx-action@<sha>       # docker-container driver (keeps attestations)
      - uses: docker/login-action@<sha>
        with: { registry: registry.example.com, username: ${{ secrets.REG_USER }}, password: ${{ secrets.REG_TOKEN }} }
      - name: Bake (both targets, both arches, SBOM + provenance)
        env:
          VERSION: ${{ github.ref_type == 'tag' && github.ref_name || format('nightly-{0}', github.run_number) }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
          docker buildx bake --push --metadata-file bake-meta.json
          echo "CI_DIGEST=$(jq -r '.ci["containerimage.digest"]' bake-meta.json)"  >> $GITHUB_ENV
          echo "DEV_DIGEST=$(jq -r '.dev["containerimage.digest"]' bake-meta.json)" >> $GITHUB_ENV
      - name: Structure + parity tests
        run: |
          for t in ci dev; do d=$([ $t = ci ] && echo $CI_DIGEST || echo $DEV_DIGEST)
            container-structure-test test --image registry.example.com/toolchain/staging/$t@$d --config tests/$t.structure.yaml; done
          diff <(docker run --rm registry.example.com/toolchain/staging/ci@$CI_DIGEST print-versions) \
               <(docker run --rm registry.example.com/toolchain/staging/dev@$DEV_DIGEST print-versions | grep -Ff <(docker run --rm registry.example.com/toolchain/staging/ci@$CI_DIGEST print-versions | cut -d= -f1))
      - name: Vulnerability gate
        run: |
          for d in ci@$CI_DIGEST dev@$DEV_DIGEST; do
            docker run --rm aquasec/trivy:<ver>@sha256:<d> image --exit-code 1 --ignore-unfixed \
              --severity CRITICAL,HIGH registry.example.com/toolchain/staging/$d; done
      - uses: sigstore/cosign-installer@<sha>
      - name: Sign by digest (keyless) and promote by copy
        run: |
          for d in ci@$CI_DIGEST dev@$DEV_DIGEST; do
            cosign sign --yes registry.example.com/toolchain/staging/$d; done
          docker buildx imagetools create -t registry.example.com/toolchain/ci:${VERSION} registry.example.com/toolchain/staging/ci@$CI_DIGEST
          docker buildx imagetools create -t registry.example.com/toolchain/dev:${VERSION} registry.example.com/toolchain/staging/dev@$DEV_DIGEST
```

(Copying by digest preserves the digest, so the signatures and attestations remain valid. Alternatively, sign after promotion. Either way, sign the digest, never a tag.)

### Consuming the `ci` image in jobs

```yaml
# GitHub Actions
jobs:
  build:
    runs-on: ubuntu-24.04            # or your ARC scale set name
    container: { image: registry.example.com/toolchain/ci:1.8.0@sha256:<A> }
    defaults: { run: { shell: bash } }
    steps:
      - uses: actions/checkout@<sha>
      - run: terraform -version && helm version && make test
```

```yaml
# GitLab CI
build:
  image: { name: "registry.example.com/toolchain/ci:1.8.0@sha256:<A>", entrypoint: [""] }
  script: [ "make test" ]
```

```yaml
# Azure DevOps
resources:
  containers:
    - container: toolchain
      image: registry.example.com/toolchain/ci:1.8.0@sha256:<A>
      endpoint: my-registry-connection
jobs:
  - job: build
    pool: { vmImage: ubuntu-latest }
    container: toolchain
    steps: [ { script: make test } ]
```

```groovy
// Jenkins Kubernetes plugin
podTemplate(containers: [
  containerTemplate(name: 'ci', image: 'registry.example.com/toolchain/ci:1.8.0@sha256:<A>', command: 'sleep', args: 'infinity')
]) { node(POD_LABEL) { container('ci') { sh 'make test' } } }
```

Optionally verify before use, in a policy step or an admission controller such as Kyverno or the Sigstore policy-controller:
`cosign verify registry.example.com/toolchain/ci@sha256:<A> --certificate-identity "https://github.com/you/toolchain-images/.github/workflows/release.yml@refs/tags/v1.8.0" --certificate-oidc-issuer https://token.actions.githubusercontent.com`

## Recommendations: best-practices checklist

1. One Dockerfile with `base → ci → dev` stages, `dev FROM ci`, and one bake run producing both. Keep the runtime image separate and minimal.
2. One version manifest (`mise.toml` + `mise.lock`, or annotated ARGs + SHA256), with no tool versions anywhere else.
3. `FROM …@sha256:<index digest>`; Actions pinned to SHAs; Features pinned via `devcontainer-lock.json` + `--frozen-lockfile`.\[7\]
4. Verify every downloaded binary (checksum, signature or attestation). No `curl | sh`.
5. Renovate (`customManagers:dockerfileVersions`, the mise lockfile, docker digests) or Dependabot (`docker` + `devcontainers` ecosystems).\[12\]\[23\] Weekly scheduled rebuilds.
6. Build multi-arch with buildx (`docker-container` or remote driver), registry cache `mode=max`, and cache mounts for apt.
7. Attach SBOM + `provenance=mode=max`. No secrets in build args. Secrets only via `--mount=type=secret`.
8. Gate on Trivy/Grype; cosign keyless sign by digest; verify with an exact identity.\[51\]\[67\]
9. Semver releases, immutable tags, promote by digest copy, consumers pin digests. No `latest`.
10. `ci` target: root default, no `ENTRYPOINT`/`WORKDIR`, glibc, `bash`/`sh`, `grep`, `sudo`, `which`, `groupadd` present.
11. `dev` target: a single regular user `vscode` at UID 1000; `remoteUser` via metadata; dev-only tools only.
12. Ephemeral runners; image builds via rootless BuildKit or Buildah; no DinD or socket mounts on shared runners.
13. Hadolint, structure tests generated from the manifest, a `ci ⊆ dev` parity test, and per-platform smoke tests.
14. Named owner, CODEOWNERS, a generated TOOLS.md and CHANGELOG, an N/N-1 support window, and retention policies.

## Key trade-offs and decision points

- **Bake vs. version manager at runtime:** baking gives deterministic, offline-capable and fast job starts. Runtime installs (`mise install` in a CI step, Features at create time) give per-repo flexibility but bring back network dependence and drift. **Decision:** bake; let repos override only by deriving `FROM ci@sha256`.
- **Root default in `ci`:** this is a pragmatic concession to GitHub Actions and Azure DevOps semantics. If you run *only* GitLab or Jenkins on Kubernetes, you can set `USER 1000` in `ci` and enforce `runAsNonRoot`. That is better, but it is platform-specific.
- **Polyglot vs. per-language images:** polyglot means one thing to update and maximal parity, but it is bigger, noisier and has a larger blast radius. Per-family images are leaner but need more release orchestration. Split at roughly 2–3 GB or when upgrade cadences conflict.
- **Debian vs. Wolfi/DHI:** Debian gives maximum compatibility and familiarity. Wolfi/DHI give far fewer CVEs and faster patches, at the cost of a different package universe and, for Chainguard, a commercial model for pinned tags.\[32\] For a freelance/homelab context, Debian plus weekly rebuilds is the sweet spot. Revisit if clients demand near-zero-CVE scan reports.
- **Bit-for-bit reproducibility:** this is achievable for small stages with `SOURCE_DATE_EPOCH`, `rewrite-timestamp` and snapshot apt sources, but expensive for a full toolchain image. Provenance plus digest pinning gives most of the security value.
- **devcontainers/ci vs. native container jobs:** use `devcontainers/ci` if you want CI to *be* the dev container (lifecycle hooks included). Use native `container:`/`image:` with the `ci` target for speed, a smaller surface and platform-native semantics. With this design, the native route is the better default.

## Caveats

- Platform behaviour around container users is fragile. GitHub runner releases have changed workspace permission behaviour (actions/runner issue #4302 reports container jobs failing with permission denied after upgrading from v2.330.0 to v2.332.0), so keep the platform smoke tests in place.
- Some details came from community sources rather than primary docs, and you should verify them before relying on them: the `remoteEnv`-in-label behaviour (a CLI flag-default analysis), the Ubuntu-24.04 devcontainer UID fix version (a third-party blog), and DHI tag naming (a third-party blog).
- The `base:ubuntu` devcontainer tag pointing at 26.04 is an inference from Docker Hub wording.
- Docker's free DHI catalog is new (December 2025). DevClass (Dec 18, 2025) quoted one developer warning, "It's free for now, just like registries were 'free' and docker desktop was free… until they weren't". Avoid a hard dependency on it without a fallback base.
- Version numbers in the examples (mise, Terraform, image semver) are placeholders. Your manifest and Renovate should supply real ones.
- SLSA level claims depend on your builder isolation. Self-hosted runners on a Proxmox homelab do not automatically meet SLSA Build L3.

## Sources

1. [Building best practices](https://docs.docker.com/build/building/best-practices/)
2. [Add SBOM and provenance attestations with GitHub Actions](https://docs.docker.com/build/ci/github-actions/attestations/)
3. [ci(docker): attach an SBOM and full provenance, and sign the digest by bocan · Pull Request #64 · bocan/mood-rss-reader](https://github.com/bocan/mood-rss-reader/pull/64)
4. [Build attestations](https://docs.docker.com/build/metadata/attestations/)
5. [SOURCE\_DATE\_EPOCH — reproducible-builds.org](https://reproducible-builds.org/docs/source-date-epoch/)
6. [buildkit/docs/build-repro.md at master · moby/buildkit](https://github.com/moby/buildkit/blob/master/docs/build-repro.md)
7. [spec/docs/specs/devcontainer-lockfile.md at main · devcontainers/spec](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainer-lockfile.md)
8. [Test: Experimental Dev Container Lockfile · Issue #8403 · microsoft/vscode-remote-release](https://github.com/microsoft/vscode-remote-release/issues/8403)
9. [Developing inside a Container](https://code.visualstudio.com/docs/devcontainers/containers)
10. [spec/docs/specs/devcontainer-reference.md at main · devcontainers/spec](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainer-reference.md)
11. [@devcontainers/cli - npm](https://www.npmjs.com/package/@devcontainers/cli)
12. [General Availability of Dependabot Integration](https://containers.dev/guide/dependabot)
13. [wolfi-base Secure-by-Default Container Image](https://images.chainguard.dev/directory/image/wolfi-base/overview)
14. [Getting Started with the Python Chainguard Container — Chainguard Academy](https://edu.chainguard.dev/chainguard/chainguard-images/getting-started/python/)
15. [Devcontainers](https://awesome-copilot.github.com/instruction/devcontainers/)
16. [ci/docs/github-action.md at main · devcontainers/ci](https://github.com/devcontainers/ci/blob/main/docs/github-action.md)
17. [Commit \`.devcontainer/devcontainer-lock.json\` to the repository · Issue #170914 · home-assistant/core](https://github.com/home-assistant/core/issues/170914)
18. [fix: honour a committed devcontainer-lock.json as VS Code does by krelinga · Pull Request #28 · krelinga/drydock](https://github.com/krelinga/drydock/pull/28)
19. [(devcontainer): Pin devcontainer Feature versions; mutable major tags admit unreviewed Feature code · Issue #412 · evanharmon1/harmon-init](https://github.com/evanharmon1/harmon-init/issues/412)
20. [ci(containers): pin base images by digest, add dependabot docker updates by Redo-San · Pull Request #555 · Redo-San/RedoSan-Authenticity](https://github.com/Redo-San/RedoSan-Authenticity/pull/555)
21. [Pin the builder and runtime base images by digest · Issue #69 · pmgledhill102/gcp-discord-bot-go](https://github.com/pmgledhill102/gcp-discord-bot-go/issues/69)
22. [Custom Manager Support using Regex - Renovate Docs](https://docs.renovatebot.com/modules/manager/regex/)
23. [CustomManager Presets - Renovate Docs](https://docs.renovatebot.com/presets-customManagers/)
24. [Reproducible builds · Issue #16044 · docker-library/official-images](https://github.com/docker-library/official-images/issues/16044)
25. [Repro build of Docker images is now much easier (BuildKit v0.13 beta1)](https://lists.reproducible-builds.org/pipermail/rb-general/2023-October/003103.html)
26. [Dev Containers Part 3: UIDs and file ownership](https://happihacking.com/blog/posts/2024/dev-containers-uids/)
27. [github.com](https://github.com/microsoft/vscode-remote-release/issues/10030)
28. [microsoft/devcontainers-base - Docker Image](https://hub.docker.com/r/microsoft/devcontainers-base)
29. [How to transition to secure container images with new migration guides](https://www.chainguard.dev/unchained/how-to-transition-to-secure-container-images-with-new-migration-guides)
30. [What is Wolfi? The Linux undistro for secure containers](https://edu.chainguard.dev/open-source/wolfi/overview/)
31. [Introducing Wolfi: The first Linux (un)distro designed for securing the software supply chain](https://www.chainguard.dev/unchained/introducing-wolfi-the-first-linux-un-distro-designed-for-securing-the-software-supply-chain)
32. [You might want to check out Wolfi and Chainguard Images. Wolfi is a Linux distro...](https://news.ycombinator.com/item?id=36941375)
33. [Customizing the containers used by jobs - GitHub Docs](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/customizing-the-containers-used-by-jobs)
34. [YAML pipeline container jobs - Azure Pipelines](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/container-phases?view=azure-devops)
35. [Bake file reference](https://docs.docker.com/build/bake/reference/)
36. [Docker Buildx Bake: Declarative Multi-Platform Image Builds](https://www.matthewswong.com/en/blog/docker-bake-multi-platform-builds/)
37. [Publish Multiple Images with Multi-Stage Targets and Buildx Bake](https://oneuptime.com/blog/post/2026-08-03-publish-multiple-images-multi-stage-dockerfile-buildx-bake/view)
38. [Docker Bake — Beginner's Guide](https://acchapm1.github.io/tutorials/Docker-Bake/docker-bake-beginner-guide)
39. [Docker Bake — Deep Dive](https://acchapm1.github.io/tutorials/Docker-Bake/docker-bake-deep-dive)
40. [Add a non-root user to a container](https://code.visualstudio.com/remote/advancedcontainers/add-nonroot-user)
41. [Dockerfile support for GitHub Actions - GitHub Docs](https://docs.github.com/en/actions/reference/workflows-and-actions/dockerfile-support)
42. [Migrating Container Builds from Kaniko to Docker BuildKit](https://medium.com/@imfah33m/migrating-container-builds-from-kaniko-to-docker-buildkit-d8aa67931838)
43. [Kaniko, BuildKit & Image Volumes In Kubernetes (2026)](https://alexandre-vazquez.com/kaniko-image-volumes-kubernetes-build-history/)
44. [Kaniko Is Dead. Here's How I Build Tenant Images in Kubernetes Now. - DEV Community](https://dev.to/jonny2k26/kaniko-is-dead-heres-how-i-build-tenant-images-in-kubernetes-now-4em8)
45. [Buildah vs Kaniko 2026: Container Image Building](https://lucaberton.com/blog/buildah-vs-kaniko-2026/)
46. [actions-runner-controller/docs/deploying-alternative-runners.md at master · actions/actions-runner-controller](https://github.com/actions/actions-runner-controller/blob/master/docs/deploying-alternative-runners.md)
47. [Actions Runner Controller · Prasanta Kumar Behera](https://pkbehera.co.in/learn/github-actions/actions-runner-controller/)
48. [Kaniko Is Dead: Google Quietly Archived It in June 2025 — What Rootless BuildKit Means for a Git-Push PaaS's Image-Build Path](https://bex.co/blog/2026/07/11/kaniko-archived-rootless-buildkit-paas)
49. [build: add SBOM and provenance attestations to published images by aneojgurhem · Pull Request #342 · aneoconsulting/ArmoniK.Extensions.Csharp.Archive](https://github.com/aneoconsulting/ArmoniK.Extensions.Csharp.Archive/pull/342)
50. [Sigstore and Cosign — Keyless Signing for Containers and Artifacts](https://www.qcecuring.com/education/code-signing/sigstore-and-cosign)
51. [Signing and Verifying Container Images with Sigstore and Cosign](https://secure-pipelines.com/ci-cd-security/signing-verifying-container-images-sigstore-cosign/)
52. [GitHub - sigstore/cosign: Code signing and transparency for containers and binaries · GitHub](https://github.com/sigstore/cosign)
53. [Keyless Signing of Container Images using GitHub Actions](https://blog.saintmalik.me/keyless-signing-container-images-github-oidc/)
54. [Lab: Signing and Verifying Container Images with Cosign in GitHub Actions](https://secure-pipelines.com/ci-cd-security/lab-signing-verifying-container-images-cosign-github-actions/)
55. [build: pin Docker base images by digest by Aalihaidar · Pull Request #35 · Aalihaidar/resume-engine](https://github.com/Aalihaidar/resume-engine/pull/35)
56. [Docker Container Jobs in GitHub Actions](https://josh-ops.com/posts/github-container-jobs/)
57. [container phases](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/container-phases)
58. <https://docs.gitlab.com/ci/docker/using_docker_images/>
59. [Kubernetes](https://plugins.jenkins.io/kubernetes/)
60. [Self-hosted runner with Docker step creates files that trip up the checkout step · Issue #434 · actions/runner](https://github.com/actions/runner/issues/434)
61. [Cleaning up files changed by a GitHub Action that runs in a container](https://devopsjournal.io/blog/2023/06/21/GitHub-container-based-Action-cleanup)
62. [How to Pin Package Versions in Dockerfiles for Reproducible Builds](https://oneuptime.com/blog/post/2026-02-08-how-to-pin-package-versions-in-dockerfiles-for-reproducible-builds/view)
63. [container-structure-test module - github.com/GoogleContainerTools/container-structure-test - Go Packages](https://pkg.go.dev/github.com/GoogleContainerTools/container-structure-test)
64. [container-structure-test/README.md at main · GoogleContainerTools/container-structure-test](https://github.com/GoogleContainerTools/container-structure-test/blob/main/README.md)
65. [goss/extras/dgoss/README.md at master · goss-org/goss](https://github.com/goss-org/goss/blob/master/extras/dgoss/README.md)
66. [Releases · goss-org/goss](https://github.com/goss-org/goss/releases)
67. [Verifying Signatures - Sigstore](https://docs.sigstore.dev/cosign/verifying/verify/)
