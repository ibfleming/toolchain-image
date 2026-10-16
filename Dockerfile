# syntax=docker/dockerfile:1.28
#
# Stages: base -> mise -> ci -> dev. Published targets are `ci` and `dev`;
# `dev` is built FROM `ci`, so every CI tool is byte-identical in the dev image.
# Tool versions live only in toolchain/mise.toml + toolchain/mise.lock.

ARG BASE_IMAGE=debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

# ---------------------------------------------------------------------------
# base: OS, CA certs, the single regular user (vscode, 1000:1000)
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base
# hadolint ignore=DL3064
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Debian's docker-clean hook deletes downloaded .debs, which defeats the cache mount.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
  && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Debian security fixes: the release pipeline sets APT_REFRESH to a new value on every run, which
# changes the build cache key of every RUN from here on, so apt fetches (and upgrades to) the
# current packages instead of reusing layers from the registry cache. Empty in local builds.
ARG APT_REFRESH=""
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gnupg grep jq make passwd sudo tar unzip xz-utils \
  && groupadd --gid "${USER_GID}" "${USERNAME}" \
  && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}"

# ---------------------------------------------------------------------------
# mise: pinned, checksum-verified mise binary. Also used by `make lock`.
# ---------------------------------------------------------------------------
FROM base AS mise
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TARGETARCH
# mise: the release binary is verified through its maintainer-signed checksums
# (vendored release key -> fingerprint -> clearsigned SHASUMS256 -> SHA-256), so only the version
# is pinned here and a Renovate bump is complete on its own. The key expires 2028-01-02: refresh
# config/keys/mise-release.asc from keys.openpgp.org when verification starts failing.
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=2026.10.8
ARG MISE_GPG_FPR=24853EC9F655CE80B48E6C3A8B81C9D17413A06D
COPY config/keys/mise-release.asc /tmp/mise-release.asc
RUN case "${TARGETARCH}" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
  && gpg --batch --quiet --import /tmp/mise-release.asc \
  && base="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}" \
  && curl -fsSLo /tmp/SHASUMS256.asc "${base}/SHASUMS256.asc" \
  && gpg --batch --status-file /tmp/gpg.status --output /tmp/SHASUMS256.txt --decrypt /tmp/SHASUMS256.asc \
  && grep -q '^\[GNUPG:\] GOODSIG ' /tmp/gpg.status \
  && grep -Eq "^\[GNUPG:\] VALIDSIG .* ${MISE_GPG_FPR}\$" /tmp/gpg.status \
  && curl -fsSLo /usr/local/bin/mise "${base}/mise-v${MISE_VERSION}-linux-${arch}" \
  && want="$(awk -v a="./mise-v${MISE_VERSION}-linux-${arch}" '$2 == a {print $1}' /tmp/SHASUMS256.txt)" \
  && test -n "${want}" \
  && echo "${want}  /usr/local/bin/mise" | sha256sum -c - \
  && chmod 0755 /usr/local/bin/mise \
  && rm -rf "${GNUPGHOME}" /tmp/SHASUMS256.* /tmp/gpg.status /tmp/mise-release.asc \
  && mise --version
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/var/cache/mise \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/mise.toml \
    MISE_LOCKED=1

# ---------------------------------------------------------------------------
# ci: base + the pinned toolchain. Contract for CI platforms:
#   root default user, no ENTRYPOINT, no WORKDIR, glibc, bash/grep/sudo/groupadd.
# ---------------------------------------------------------------------------
FROM mise AS ci
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# C/C++ toolchain from Debian (compilers track the base digest; cmake/ninja are pinned in mise).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
  && apt-get install -y --no-install-recommends \
      autoconf automake build-essential ccache clang clang-format clang-tidy file \
      libssl-dev libtool lld pkg-config zlib1g-dev
# Shell libraries for the image's scripts and for users' own: logging (log.sh) and the One
# Dark palette. The dir is created first: COPY --chmod=0644 would create it without search bits.
RUN install -d -m 0755 /usr/local/lib/toolchain
COPY --chmod=0644 scripts/lib/log.sh scripts/lib/palette.sh /usr/local/lib/toolchain/
COPY toolchain/mise.toml toolchain/mise.lock /etc/mise/
COPY --chmod=0755 scripts/link_tools.sh /usr/local/sbin/link-tools
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN,required=false \
    --mount=type=cache,target=/var/cache/mise,sharing=locked \
    mise -C / install --locked \
  && link-tools \
  && chmod -R a+rX /opt/mise
COPY --chmod=0755 scripts/print_versions.sh /usr/local/bin/print-versions

# Keep language tooling from fetching its own toolchains at runtime (parity with the manifest).
ENV GOTOOLCHAIN=local \
    UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-system \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

LABEL org.opencontainers.image.title="toolchain-ci" \
      org.opencontainers.image.description="Pinned CI toolchain (root default, no entrypoint)"
# Intentionally: no USER, no ENTRYPOINT, no WORKDIR.

# ---------------------------------------------------------------------------
# dev: FROM ci + dev conveniences only. Never replaces a ci tool.
# remoteUser and editor config come from the devcontainer.metadata label (docker-bake.hcl).
# ---------------------------------------------------------------------------
FROM ci AS dev
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3064
ARG USERNAME=vscode
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
  && apt-get install -y --no-install-recommends \
      bash-completion clangd dnsutils gdb htop less lldb locales openssh-client \
      procps socat valgrind vim-tiny zsh \
  && echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
  && chmod 0440 "/etc/sudoers.d/${USERNAME}" \
  && visudo -cf "/etc/sudoers.d/${USERNAME}" \
  && usermod --shell /usr/bin/zsh "${USERNAME}" \
  && echo 'skip_global_compinit=1' >> /etc/zsh/zshenv

# Dev-only tools and the shell's tools (separate manifests; never in ci). The shell manifest is
# also what a host installs for the dev shell without the toolchain.
COPY toolchain/dev/mise.toml toolchain/dev/mise.lock /etc/mise/dev/
COPY toolchain/shell/mise.toml toolchain/shell/mise.lock /etc/mise/shell/
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN,required=false \
    --mount=type=cache,target=/var/cache/mise,sharing=locked \
    for manifest in /etc/mise/dev/mise.toml /etc/mise/shell/mise.toml; do \
      MISE_GLOBAL_CONFIG_FILE="${manifest}" mise -C / install --locked \
        && MISE_GLOBAL_CONFIG_FILE="${manifest}" link-tools || exit 1; \
    done \
  && chmod -R a+rX /opt/mise /etc/mise

# Docker client. The engine is the host's (its socket mounted at /var/run/docker-host.sock, see
# docker-socket-init) or, opt-in, Docker-in-Docker. The CLI comes from Docker's apt repository,
# verified by its signing key (vendored, fingerprint pinned): Docker publishes no checksums for its
# static binaries. buildx and compose are checksum-pinned in the dev mise manifest and linked into
# the system plugin directory here. Renovate bumps the CLI (deb datasource).
ARG TARGETARCH
ARG DOCKER_GPG_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# editorconfig-checker-disable-next-line
# renovate: datasource=deb depName=docker-ce-cli registryUrl=https://download.docker.com/linux/debian?suite=trixie&components=stable&binaryArch=amd64
ARG DOCKER_CLI_VERSION=5:29.9.1-1~debian.13~trixie
COPY config/keys/docker-release.asc /tmp/docker-release.asc
COPY --chmod=0755 scripts/docker_socket_init.sh /usr/local/sbin/docker-socket-init
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
  && gpg --batch --quiet --import /tmp/docker-release.asc \
  && gpg --batch --with-colons --fingerprint | grep -q "^fpr:::::::::${DOCKER_GPG_FPR}:" \
  && install -D -m 0644 /tmp/docker-release.asc /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/docker.asc]" \
      "https://download.docker.com/linux/debian trixie stable" >/etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends "docker-ce-cli=${DOCKER_CLI_VERSION}" \
  && install -d -m 0755 /usr/local/lib/docker/cli-plugins \
  && for p in buildx compose; do \
      ln -s "$(readlink -f "/usr/local/bin/docker-cli-plugin-docker-${p}")" \
        "/usr/local/lib/docker/cli-plugins/docker-${p}" || exit 1; \
    done \
  && groupadd --system docker \
  && usermod -aG docker "${USERNAME}" \
  && rm -rf "${GNUPGHOME}" /tmp/docker-release.asc \
  && docker --version && docker buildx version && docker compose version

# zsh plugins, at the git commits pinned in config/zsh/plugins.txt (git verifies a commit by its
# hash, so no checksum is needed; Renovate updates tag + commit together). No plugin manager, no
# runtime clones. Each step is chained with && so any failure aborts the build.
COPY config/zsh/plugins.txt /tmp/zsh-plugins.txt
RUN grep -vE '^(#|$)' /tmp/zsh-plugins.txt | while read -r name repo tag commit; do \
      dir="/usr/local/share/zsh-plugins/${name}" \
      && echo "zsh plugin ${name} ${tag} @ ${commit}" \
      && git init -q "${dir}" \
      && git -C "${dir}" fetch -q --depth 1 "https://github.com/${repo}.git" "${commit}" \
      && git -C "${dir}" -c advice.detachedHead=false checkout -q "${commit}" \
      && test "$(git -C "${dir}" rev-parse HEAD)" = "${commit}" \
      && rm -rf "${dir}/.git" || exit 1; \
    done \
  && test "$(find /usr/local/share/zsh-plugins -mindepth 1 -maxdepth 1 | wc -l)" -eq 4 \
  && rm /tmp/zsh-plugins.txt

# Claude Code: pinned native binary, verified end to end (vendored release key -> fingerprint ->
# signed manifest -> per-platform SHA-256). Installed root-owned in /usr/local/bin (outside the
# user's home and volumes); DISABLE_UPDATES blocks `claude update` / `claude install`, so the
# version only changes with the image.
# Pin the `stable` channel: https://downloads.claude.ai/claude-code-releases/stable
# renovate: datasource=custom.claude-code-stable depName=claude-code
ARG CLAUDE_CODE_VERSION=2.1.292
ARG CLAUDE_CODE_GPG_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
COPY config/keys/claude-code-release.asc /tmp/claude-code-release.asc
RUN case "${TARGETARCH}" in \
      amd64) plat=linux-x64 ;; \
      arm64) plat=linux-arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
  && gpg --batch --quiet --import /tmp/claude-code-release.asc \
  && gpg --batch --with-colons --fingerprint | grep -q "^fpr:::::::::${CLAUDE_CODE_GPG_FPR}:" \
  && base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}" \
  && curl -fsSLo /tmp/manifest.json "${base}/manifest.json" \
  && curl -fsSLo /tmp/manifest.json.sig "${base}/manifest.json.sig" \
  && gpg --batch --verify /tmp/manifest.json.sig /tmp/manifest.json \
  && test "$(jq -r .version /tmp/manifest.json)" = "${CLAUDE_CODE_VERSION}" \
  && curl -fsSLo /usr/local/bin/claude "${base}/${plat}/claude" \
  && want="$(jq -er --arg p "${plat}" '.platforms[$p].checksum' /tmp/manifest.json)" \
  && echo "${want}  /usr/local/bin/claude" | sha256sum -c - \
  && chmod 0755 /usr/local/bin/claude \
  && rm -rf "${GNUPGHOME}" /tmp/manifest.json /tmp/manifest.json.sig /tmp/claude-code-release.asc \
  && claude --version

# The policy dir is created explicitly: `COPY --chmod=0644` would otherwise create it 0644
# (no search bit), leaving the policy unreadable to vscode and so silently ignored.
RUN install -d -m 0755 /etc/claude-code

# Managed policy: Claude Code's highest-precedence settings, root-owned. A secure default for
# every container; derived images can replace it (see docs/customizing.md). Per-project Claude state lives in
# a volume at ~/.claude (CLAUDE_CONFIG_DIR); pre-creating it makes the volume vscode-owned.
COPY --chmod=0644 config/claude/managed-settings.json /etc/claude-code/managed-settings.json
RUN install -d -o "${USERNAME}" -g "${USERNAME}" -m 0700 "/home/${USERNAME}/.claude"

COPY --chmod=0755 scripts/gen_zsh_completions.sh /usr/local/sbin/gen-zsh-completions
RUN gen-zsh-completions

# Shared shell/prompt/git config (root-owned, read-only to the user) ...
COPY config/zsh/ /usr/local/share/toolchain/zsh/
COPY config/starship/ /usr/local/share/toolchain/starship/
COPY config/git/gitconfig /etc/gitconfig
# ... and seeded, user-owned home files (.zshrc, .npmrc, ~/.config/k9s). Pre-creating the
# XDG dirs makes named volumes mounted there inherit vscode ownership.
# (install -d only chowns the dirs it is given, so parents are listed explicitly.)
RUN for d in .config .cache .local .local/bin .local/share .local/share/mise .local/state \
      .local/state/zsh; do \
      install -d -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/${d}" || exit 1; \
    done
COPY --chown=${USERNAME}:${USERNAME} config/home/ /home/${USERNAME}/

# User bin dirs come AFTER the system ones, so a stray file in ~/.local/bin (from `npm -g`, a
# script, or an agent) can't silently shadow the image's pinned tools (claude, git, kubectl, ...).
ENV PATH=${PATH}:/home/${USERNAME}/.local/bin:/home/${USERNAME}/go/bin \
    COLORTERM=truecolor \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_UPDATES=1 \
    GH_NO_UPDATE_NOTIFIER=1

# Build metadata for `welcome` and tooling: /etc/toolchain/release (version, revision, date,
# source, previous release), /etc/toolchain/versions (pinned tools) and /etc/toolchain/previous
# (the previous release's tools, from scripts/previous_tools.sh; empty for local builds). Last on
# purpose: it changes every release, so only this layer rebuilds.
ARG VERSION=0.0.0-dev
ARG REVISION=
ARG SOURCE_URL=
ARG SOURCE_DATE_EPOCH=0
ARG PREVIOUS_VERSION=
ARG PREVIOUS_TOOLS=
RUN install -d -m 0755 /etc/toolchain \
  && { \
    echo "TOOLCHAIN_VERSION=${VERSION}"; \
    echo "TOOLCHAIN_REVISION=${REVISION}"; \
    echo "TOOLCHAIN_CREATED=$(date -u -d "@${SOURCE_DATE_EPOCH:-0}" +%F)"; \
    echo "TOOLCHAIN_SOURCE=${SOURCE_URL}"; \
    echo "TOOLCHAIN_PREVIOUS=${PREVIOUS_VERSION}"; \
  } >/etc/toolchain/release \
  && print-versions >/etc/toolchain/versions \
  && echo "${PREVIOUS_TOOLS}" | tr ' ' '\n' | sed '/^$/d' >/etc/toolchain/previous

LABEL org.opencontainers.image.title="toolchain-dev" \
      org.opencontainers.image.description="Dev container image: toolchain-ci plus dev conveniences" \
      toolchain.claude-code.version="${CLAUDE_CODE_VERSION}"
