# syntax=docker/dockerfile:1.19
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

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
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
ARG MISE_VERSION=2026.10.7
ARG MISE_SHA256_AMD64=6eb1b890e90818417ca34c90dbbd47881917d5cd199f31b63b062ea9c6b18d85
RUN case "${TARGETARCH}" in \
      amd64) arch=x64; sum="${MISE_SHA256_AMD64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSLo /usr/local/bin/mise \
      "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${arch}" \
  && echo "${sum}  /usr/local/bin/mise" | sha256sum -c - \
  && chmod 0755 /usr/local/bin/mise \
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
COPY toolchain/mise.toml toolchain/mise.lock /etc/mise/
COPY --chmod=0755 scripts/link-tools.sh /usr/local/sbin/link-tools
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN,required=false \
    --mount=type=cache,target=/var/cache/mise,sharing=locked \
    mise -C / install --locked \
  && link-tools \
  && chmod -R a+rX /opt/mise
COPY --chmod=0755 scripts/print-versions.sh /usr/local/bin/print-versions

# Keep language tooling from fetching its own toolchains at runtime (parity with the manifest).
ENV GOTOOLCHAIN=local \
    UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-system \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

LABEL org.opencontainers.image.title="toolchain-ci" \
      org.opencontainers.image.description="Pinned CI toolchain (root default, no entrypoint)" \
      org.opencontainers.image.source="https://github.com/ibfleming/toolchain-image"
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
      bash-completion clangd dnsutils gdb htop ipset iptables less lldb locales openssh-client \
      procps valgrind vim-tiny zsh \
  && usermod --shell /usr/bin/zsh "${USERNAME}" \
  && echo 'skip_global_compinit=1' >> /etc/zsh/zshenv

# Dev-only tools (separate manifest; never in ci).
COPY toolchain/dev/mise.toml toolchain/dev/mise.lock /etc/mise/dev/
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN,required=false \
    --mount=type=cache,target=/var/cache/mise,sharing=locked \
    export MISE_GLOBAL_CONFIG_FILE=/etc/mise/dev/mise.toml \
  && mise -C / install --locked \
  && link-tools \
  && chmod -R a+rX /opt/mise

# zsh plugins: pinned release tarballs, checksum-verified (no plugin manager, no runtime clones).
# renovate: datasource=github-tags depName=zsh-users/zsh-autosuggestions
ARG ZSH_AUTOSUGGESTIONS_VERSION=v0.7.1
ARG ZSH_AUTOSUGGESTIONS_SHA256=0df7affff21cd87ed298e6a3970ed08a1dd66a6efa676454ee5b091ad503badf
# renovate: datasource=github-tags depName=zsh-users/zsh-syntax-highlighting
ARG ZSH_SYNTAX_HIGHLIGHTING_VERSION=0.8.0
ARG ZSH_SYNTAX_HIGHLIGHTING_SHA256=5981c19ebaab027e356fe1ee5284f7a021b89d4405cc53dc84b476c3aee9cc32
# renovate: datasource=github-tags depName=zsh-users/zsh-completions
ARG ZSH_COMPLETIONS_VERSION=0.36.0
ARG ZSH_COMPLETIONS_SHA256=5aa68be2999a7be2eb56de8e4acff8f3bba4a66b9acbb233752536857408fb2e
# renovate: datasource=github-tags depName=Aloxaf/fzf-tab
ARG FZF_TAB_VERSION=v1.3.0
ARG FZF_TAB_SHA256=d75ac08c2c8af5a6a0478787b0f11fabbe24951973b7841ae963431e2070ee9a
RUN fetch() { \
      name="$1"; repo="$2"; ref="$3"; sum="$4"; tgz="/tmp/$1.tar.gz"; \
      curl -fsSLo "$tgz" "https://github.com/${repo}/archive/refs/tags/${ref}.tar.gz"; \
      echo "${sum}  ${tgz}" | sha256sum -c -; \
      mkdir -p "/usr/local/share/zsh-plugins/${name}"; \
      tar -xzf "$tgz" --strip-components=1 -C "/usr/local/share/zsh-plugins/${name}"; \
      rm -f "$tgz"; \
    } \
  && fetch zsh-autosuggestions zsh-users/zsh-autosuggestions \
      "${ZSH_AUTOSUGGESTIONS_VERSION}" "${ZSH_AUTOSUGGESTIONS_SHA256}" \
  && fetch zsh-syntax-highlighting zsh-users/zsh-syntax-highlighting \
      "${ZSH_SYNTAX_HIGHLIGHTING_VERSION}" "${ZSH_SYNTAX_HIGHLIGHTING_SHA256}" \
  && fetch zsh-completions zsh-users/zsh-completions \
      "${ZSH_COMPLETIONS_VERSION}" "${ZSH_COMPLETIONS_SHA256}" \
  && fetch fzf-tab Aloxaf/fzf-tab \
      "${FZF_TAB_VERSION}" "${FZF_TAB_SHA256}"

# Claude Code: pinned native binary, verified end to end (vendored release key -> fingerprint ->
# signed manifest -> per-platform SHA-256). Root-owned in /usr/local/bin, so the agent (running
# as vscode) cannot replace it; DISABLE_UPDATES also blocks `claude update` / `claude install`.
# Pin the `stable` channel: https://downloads.claude.ai/claude-code-releases/stable
ARG CLAUDE_CODE_VERSION=2.1.287
ARG CLAUDE_CODE_GPG_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
ARG TARGETARCH
COPY config/claude/claude-code-release.asc /tmp/claude-code-release.asc
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

# Config dirs are created explicitly: `COPY --chmod=0644` would otherwise create them 0644
# (no search bit), leaving the policy unreadable to vscode and so silently unenforced.
RUN install -d -m 0755 /etc/claude-code /etc/toolchain /etc/toolchain/firewall

# Managed policy (highest settings precedence; root-owned). Per-project Claude state lives in
# a volume at ~/.claude (CLAUDE_CONFIG_DIR); pre-creating it makes the volume vscode-owned.
COPY --chmod=0644 config/claude/managed-settings.json /etc/claude-code/managed-settings.json
RUN install -d -o "${USERNAME}" -g "${USERNAME}" -m 0700 "/home/${USERNAME}/.claude"

# Opt-in egress firewall. vscode's ONLY sudo right: run init-firewall with no arguments.
COPY --chmod=0644 config/firewall/allowlist.txt config/firewall/github-ipv4.txt /etc/toolchain/firewall/
COPY --chmod=0755 scripts/init-firewall.sh /usr/local/sbin/init-firewall
COPY --chmod=0755 scripts/toolchain-firewall.sh /usr/local/bin/toolchain-firewall
RUN echo "${USERNAME} ALL=(root) NOPASSWD: /usr/local/sbin/init-firewall \"\"" > /etc/sudoers.d/toolchain-firewall \
  && chmod 0440 /etc/sudoers.d/toolchain-firewall \
  && visudo -cf /etc/sudoers.d/toolchain-firewall

COPY --chmod=0755 scripts/gen-zsh-completions.sh /usr/local/sbin/gen-zsh-completions
RUN gen-zsh-completions

# Shared shell/prompt/git config (root-owned, read-only to the user) ...
COPY config/zsh/ /usr/local/share/toolchain/zsh/
COPY config/starship/ /usr/local/share/toolchain/starship/
COPY config/git/gitconfig /etc/gitconfig
# ... and seeded, user-owned home files (.zshrc, .npmrc, ~/.config/k9s). Pre-creating the
# XDG dirs makes named volumes mounted there inherit vscode ownership.
# (install -d only chowns the dirs it is given, so parents are listed explicitly.)
RUN for d in .config .cache .local .local/bin .local/share .local/state .local/state/zsh; do \
      install -d -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/${d}"; \
    done
COPY --chown=${USERNAME}:${USERNAME} config/home/ /home/${USERNAME}/

# User bin dirs come AFTER the system ones, so nothing running as vscode (an agent included)
# can shadow root-owned tools like claude, git or kubectl by dropping a file in ~/.local/bin.
ENV PATH=${PATH}:/home/${USERNAME}/.local/bin:/home/${USERNAME}/go/bin \
    COLORTERM=truecolor \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_UPDATES=1

LABEL org.opencontainers.image.title="toolchain-dev" \
      org.opencontainers.image.description="Dev container image: toolchain-ci plus dev conveniences" \
      io.github.ibfleming.toolchain.claude-code.version="${CLAUDE_CODE_VERSION}"
