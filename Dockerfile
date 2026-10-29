# syntax=docker/dockerfile:1.28
#
# One Dockerfile, two published images:
#
#   base   the OS, CA certificates and the one regular user (vscode, 1000:1000)
#   mise   + the pinned, signature-verified mise binary (also used by `make lock`)
#   ci     + the pinned toolchain                                           -> published
#   dev    + developer conveniences, built FROM ci, never replacing a tool  -> published
#
# Because dev is built FROM ci, every CI tool is byte-identical in the dev image. Tool versions
# live in toolchain/{,dev/,shell/}mise.toml and their locks. This file pins only the base image
# (by digest), mise and the Docker CLI (each verified by signature or signing key); the zsh plugins
# are pinned by commit in config/zsh/plugins.txt.

ARG BASE_IMAGE=debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f


# ==================================================================================================
# base: the OS, CA certificates and the single regular user (vscode, 1000:1000)
# ==================================================================================================
FROM ${BASE_IMAGE} AS base
# hadolint ignore=DL3064
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Keep downloaded .debs: Debian's docker-clean hook deletes them, defeating the apt cache mounts.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
  && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# APT_REFRESH: the release pipeline sets a new value on every run. That changes the build cache key
# of every RUN from here on, so releases fetch (and upgrade to) Debian's current packages instead of
# reusing cached layers. Empty in local builds; CI reuses the last release's value.
ARG APT_REFRESH=""
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gnupg grep jq make passwd sudo tar unzip xz-utils \
  && groupadd --gid "${USER_GID}" "${USERNAME}" \
  && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}"


# ==================================================================================================
# mise: the pinned, signature-verified mise binary (also used by `make lock`)
# ==================================================================================================
FROM base AS mise
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TARGETARCH

# Verified through its maintainer-signed checksums: vendored release key -> pinned fingerprint ->
# clearsigned SHASUMS256 -> SHA-256 of the binary. Only the version is pinned here, so a Renovate
# bump is complete on its own. The key expires 2028-01-02: when verification starts failing,
# refresh config/keys/mise-release.asc from keys.openpgp.org.
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=2026.10.23
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

# The image's own mise: its tools in /opt/mise, its config in /etc/mise, installs locked.
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/var/cache/mise \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/mise.toml \
    MISE_LOCKED=1


# ==================================================================================================
# ci: base + the pinned toolchain (published)
#
# The contract CI platforms rely on (GitHub Actions and Azure DevOps container jobs): root as the
# default user, no ENTRYPOINT, no WORKDIR, glibc, and bash, grep, sudo and groupadd present.
# ==================================================================================================
FROM mise AS ci
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- C/C++ toolchain ------------------------------------------------------------------------------
# From Debian: the compilers follow the base image's digest; cmake and ninja are pinned in mise.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
  && apt-get install -y --no-install-recommends \
      autoconf automake build-essential ccache clang clang-format clang-tidy file \
      libssl-dev libtool lld pkg-config zlib1g-dev

# --- Shell libraries ------------------------------------------------------------------------------
# For the image's scripts and for users' own: logging (log.sh), the One Dark palette, dev container
# lifecycle state (lifecycle.sh) and readiness checks (validate.sh). The directory is created first:
# COPY --chmod=0644 would otherwise create it without search bits.
RUN install -d -m 0755 /usr/local/lib/toolchain
COPY --chmod=0644 image/lib/log.sh image/lib/palette.sh image/lib/lifecycle.sh \
      image/lib/validate.sh /usr/local/lib/toolchain/

# --- The toolchain --------------------------------------------------------------------------------
# Installed locked from toolchain/mise.toml, then linked into /usr/local/bin (no mise shims), so
# every process finds the tools, not only interactive shells.
COPY toolchain/mise.toml toolchain/mise.lock /etc/mise/
COPY --chmod=0755 image/link_tools.sh /usr/local/sbin/link-tools
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN,required=false \
    --mount=type=cache,target=/var/cache/mise,sharing=locked \
    mise -C / install --locked \
  && link-tools \
  && chmod -R a+rX /opt/mise
COPY --chmod=0755 image/print_versions.sh /usr/local/bin/print-versions

# --- Environment ----------------------------------------------------------------------------------
# Keep language tooling from fetching its own toolchains at runtime (parity with the manifest).
ENV GOTOOLCHAIN=local \
    UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-system \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

LABEL org.opencontainers.image.title="toolchain-ci" \
      org.opencontainers.image.description="Pinned CI toolchain (root default, no entrypoint)"
# Intentionally no USER, no ENTRYPOINT and no WORKDIR (the contract above).


# ==================================================================================================
# dev: ci + developer conveniences (published)
#
# Only ever adds to ci; never replaces one of its tools. remoteUser and the editor setup come from
# the devcontainer.metadata label (docker-bake.hcl).
# ==================================================================================================
FROM ci AS dev
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3064
ARG USERNAME=vscode

# --- System packages, sudo and the login shell ----------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
  && apt-get install -y --no-install-recommends \
      bash-completion clangd dnsutils gdb htop less lldb locales openssh-client \
      procps socat valgrind vim-tiny xclip zsh \
  && echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
  && chmod 0440 "/etc/sudoers.d/${USERNAME}" \
  && visudo -cf "/etc/sudoers.d/${USERNAME}" \
  && usermod --shell /usr/bin/zsh "${USERNAME}" \
  && echo 'skip_global_compinit=1' >> /etc/zsh/zshenv

# --- Dev-only tools and the shell's own tools -----------------------------------------------------
# Separate manifests, never in ci. The shell manifest is also what a host installs for the dev
# shell without the toolchain.
COPY toolchain/dev/mise.toml toolchain/dev/mise.lock /etc/mise/dev/
COPY toolchain/shell/mise.toml toolchain/shell/mise.lock /etc/mise/shell/
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN,required=false \
    --mount=type=cache,target=/var/cache/mise,sharing=locked \
    for manifest in /etc/mise/dev/mise.toml /etc/mise/shell/mise.toml; do \
      MISE_GLOBAL_CONFIG_FILE="${manifest}" mise -C / install --locked \
        && MISE_GLOBAL_CONFIG_FILE="${manifest}" link-tools || exit 1; \
    done \
  && chmod -R a+rX /opt/mise /etc/mise

# --- Docker client --------------------------------------------------------------------------------
# The engine is the host's (its socket mounted at /var/run/docker-host.sock and served by
# docker-socket-init) or, opt-in, Docker-in-Docker. The CLI comes from Docker's apt repository,
# verified by its signing key: the vendored file must hold exactly one primary key, with the pinned
# fingerprint (Docker publishes no checksums for its static binaries). Renovate bumps the CLI (deb
# datasource). buildx and compose are checksum-pinned in the dev mise manifest and linked into the
# system plugin directory here.
ARG TARGETARCH
ARG DOCKER_GPG_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# editorconfig-checker-disable-next-line
# renovate: datasource=deb depName=docker-ce-cli registryUrl=https://download.docker.com/linux/debian?suite=trixie&components=stable&binaryArch=amd64
ARG DOCKER_CLI_VERSION=5:29.9.1-1~debian.13~trixie
COPY config/keys/docker-release.asc /tmp/docker-release.asc
COPY --chmod=0755 image/docker_socket_init.sh /usr/local/sbin/docker-socket-init
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
  && gpg --batch --with-colons --import-options show-only --import /tmp/docker-release.asc \
      >/tmp/docker-key.txt \
  && test "$(grep -c '^pub:' /tmp/docker-key.txt)" -eq 1 \
  && awk -F: '/^pub:/ { p = 1; next } p && /^fpr:/ { print $10; exit }' /tmp/docker-key.txt \
      | grep -qx "${DOCKER_GPG_FPR}" \
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
  && rm -rf "${GNUPGHOME}" /tmp/docker-release.asc /tmp/docker-key.txt \
  && docker --version && docker buildx version && docker compose version

# --- zsh plugins ----------------------------------------------------------------------------------
# At the git commits pinned in config/zsh/plugins.txt: git verifies a commit by its hash, so no
# checksum is needed, and Renovate updates tag and commit together. No plugin manager and no
# runtime clones. Every step is chained with &&, so any failure aborts the build.
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

# --- Claude Code managed policy -------------------------------------------------------------------
# Claude Code's highest-precedence settings, root-owned: a secure default for every container,
# which derived images can replace (see docs/customizing.md). The image ships no Claude Code CLI;
# the VS Code extension runs its own bundled one, which reads this policy.
#
# The policy directory is created explicitly: COPY --chmod=0644 would otherwise create it 0644 (no
# search bit), leaving the policy unreadable to vscode and so silently ignored. ~/.claude holds the
# per-project Claude state, in a volume (CLAUDE_CONFIG_DIR), so the extension's sign-in survives a
# rebuild; pre-creating it makes that volume vscode-owned.
RUN install -d -m 0755 /etc/claude-code
COPY --chmod=0644 config/claude/managed-settings.json /etc/claude-code/managed-settings.json
RUN install -d -o "${USERNAME}" -g "${USERNAME}" -m 0700 "/home/${USERNAME}/.claude"

# --- Commands -------------------------------------------------------------------------------------
# Dev container lifecycle state (image/lib/lifecycle.sh): dev-status reports it, dev-wait blocks
# until the container is ready, dev-reset clears it.
COPY --chmod=0755 image/dev_status.sh /usr/local/bin/dev-status
COPY --chmod=0755 image/dev_wait.sh /usr/local/bin/dev-wait
COPY --chmod=0755 image/dev_reset.sh /usr/local/bin/dev-reset
# Clipboard and browser from the container to your machine. xclip (in front of the real
# /usr/bin/xclip) uses the display VS Code forwards, or else OSC 52 through the terminal; xdg-open
# uses VS Code's $BROWSER helper, or else prints and copies the URL.
COPY --chmod=0755 image/clipboard.sh /usr/local/bin/xclip
COPY --chmod=0755 image/xdg_open.sh /usr/local/bin/xdg-open
# zsh completions generated from the installed tools.
COPY --chmod=0755 image/gen_zsh_completions.sh /usr/local/sbin/gen-zsh-completions
RUN gen-zsh-completions

# --- Shell, prompt and git config -----------------------------------------------------------------
# Shared and root-owned, read-only to the user.
COPY config/zsh/ /usr/local/share/toolchain/zsh/
COPY config/starship/ /usr/local/share/toolchain/starship/
COPY config/git/gitconfig /etc/gitconfig
# The image's prompt marks a container shell: the Docker-blue palette, and the Docker whale (U+F308)
# instead of the Debian logo. Hosts that install the shell keep the repository's file as it is. The
# build fails if either line isn't found.
RUN f=/usr/local/share/toolchain/starship/starship.toml \
  && whale="$(printf '\357\214\210')" \
  && sed -i -e "s/^palette = 'one_dark'$/palette = 'one_dark_container'/" \
      -e "s/^Debian = .*/Debian = \"${whale}\"/" "${f}" \
  && grep -qx "palette = 'one_dark_container'" "${f}" \
  && grep -qx "Debian = \"${whale}\"" "${f}"

# --- The vscode home directory --------------------------------------------------------------------
# Seeded, user-owned files: .zshrc, .npmrc and ~/.config/k9s. The XDG directories are created first,
# so named volumes mounted there (gh, mise, zsh history) inherit vscode ownership. install -d only
# chowns the directories it is given, so the parents are listed too.
RUN for d in .config .config/gh .cache .local .local/bin .local/share .local/share/mise \
      .local/state .local/state/zsh; do \
      install -d -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/${d}" || exit 1; \
    done
COPY --chown=${USERNAME}:${USERNAME} config/home/ /home/${USERNAME}/

# --- Environment ----------------------------------------------------------------------------------
# The user's bin directories come AFTER the system ones, so a stray file in ~/.local/bin (from
# `npm -g`, a script or an agent) can't silently shadow the image's pinned tools.
ENV PATH=${PATH}:/home/${USERNAME}/.local/bin:/home/${USERNAME}/go/bin \
    COLORTERM=truecolor \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    GH_NO_UPDATE_NOTIFIER=1

# --- Build metadata (last on purpose) -------------------------------------------------------------
# For `welcome` and tooling: /etc/toolchain/release (version, revision, date, source, previous
# release), /etc/toolchain/versions (the pinned tools) and /etc/toolchain/previous (the previous
# release's tools, from scripts/previous_tools.sh; empty in local builds). It changes with every
# release, so it comes last and only this layer rebuilds.
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
      org.opencontainers.image.description="Dev container image: toolchain-ci plus dev conveniences"
