# Ship toolchains in images, Claude config in git

The setup that holds up best is a **thin, synced local VS Code profile that contains only the WSL and Dev Containers connectors plus UI-only extensions**. The **prebuilt `dev` image** provides toolchains, language extensions, language settings, a pinned and signature-verified Claude Code binary, and a managed-settings policy, all through its `devcontainer.metadata` label. Claude Code itself works best with state split into two kinds. **Authored configuration** (personal CLAUDE.md, rules, skills, agents, commands, hooks, base settings, and plugin and MCP bootstrap scripts) goes in a git-tracked dotfiles subtree that is copied into each environment. **Machine-generated state** (`.claude.json`, credentials, transcripts, auto memory, plugin cache) stays per environment: `~/.claude` in WSL, and in each container a named volume with `CLAUDE_CONFIG_DIR` pointed at it. Do **not** bind-mount one live `~/.claude` into both WSL and containers. Users have reported `.claude.json` lost-update races and OAuth refresh-token rotation races. That design also gives a compromised container write access to hooks and settings that later run unsandboxed on the WSL host. The cost of this design is that **chat transcripts do not flow live between WSL and containers**. Transcripts are keyed by absolute path and live in each config directory. Rebuilds do keep them, cross-project `--resume <id>` works inside one config directory, and aligning the workspace path plus an explicit `autoMemoryDirectory` can share auto memory across environments, though that last part is unverified. One concrete hazard needs attention before you copy Anthropic's reference container: **its firewall allowlist is out of date**. It lacks the current sign-in, token-refresh and download hosts and still lists retired telemetry hosts.

## Five homes for state, each with one owner

The design rests on one rule: every piece of state has exactly one authoritative home, and nothing machine-written is synced through git. VS Code makes the editor half of this straightforward. **Settings Sync never syncs extensions to or from remote windows** (WSL, containers, SSH) ([VS Code: Settings Sync](https://code.visualstudio.com/docs/configure/settings-sync)). Settings in a container's `customizations.vscode.settings` are written to a machine-specific Remote settings file that **overrides synced User settings** ([containers.dev: Supporting tools](https://containers.dev/supporting); [VS Code: Settings](https://code.visualstudio.com/docs/configure/settings)). Claude Code needs more care, because its home directory mixes three kinds of data. The first is user-authored config: `settings.json`, `CLAUDE.md`, `rules/`, `skills/`, `agents/`, `commands/`, `output-styles/` and `keybindings.json`. The second is credentials: `.credentials.json` at mode 0600 on Linux. The third is generated data: `projects/` transcripts and auto memory, `history.jsonl`, `file-history/`, `plugins/` and `sessions/` ([.claude directory](https://code.claude.com/docs/en/claude-directory)). A separate file, `~/.claude.json`, holds the OAuth session, per-project trust, user- and local-scope MCP servers, and UI toggles. **Setting `CLAUDE_CONFIG_DIR` moves all of it, including `.claude.json`, into one directory** ([Settings](https://code.claude.com/docs/en/settings); [Dev containers](https://code.claude.com/docs/en/devcontainer)). That makes a single named volume a complete persistence unit.

| Item | Authoritative home | Notes |
|---|---|---|
| Language runtimes, linters, formatters (Python, Ruff binary, Terraform, etc.) | `ci` stage of the image (inherited by `dev`) | CI and dev containers get identical tools |
| Claude Code CLI binary (pinned, GPG/SHA256-verified) | `dev` image, `/usr/local/bin/claude` | Root-owned path, so the agent can't replace it; `DISABLE_UPDATES=1` |
| Claude Code policy (`managed-settings.json`) | `dev` image, `/etc/claude-code/` | Highest settings precedence |
| VS Code language extensions (Ruff, Python, Claude Code, …) and language settings | `dev` image `devcontainer.metadata` label | Remote settings override synced User settings |
| `remoteUser`, `containerEnv` (`CLAUDE_CONFIG_DIR`, `DISABLE_UPDATES`), `capAdd`, firewall `postStartCommand` | `dev` image label | Merged with the repo's devcontainer.json, which is applied last |
| Image reference **by digest**, `workspaceMount`/`workspaceFolder`, Claude volume mount, `--env-file`, per-repo extension opt-outs | Repo `.devcontainer/devcontainer.json` | Project-specific, reviewed in PRs |
| Team instructions and config: `CLAUDE.md`, `.claude/settings.json`, `.claude/{skills,agents,commands,rules}`, `.mcp.json` | Repo (committed) | Shared with collaborators and CI |
| `CLAUDE.local.md`, `.claude/settings.local.json` | Repo checkout, gitignored | Visible to WSL and container through the bind mount |
| Personal `CLAUDE.md`, `rules/`, `skills/`, `agents/`, `commands/`, `output-styles/`, `keybindings.json`, `settings.base.json` (hooks, `enabledPlugins`, `extraKnownMarketplaces`), hook scripts, MCP/plugin bootstrap scripts | Dotfiles repo, `claude/` subtree | Copied (not live-linked) into each config dir by `install.sh` |
| `.claude.json`, `.credentials.json`, `projects/` (transcripts + auto memory), `history.jsonl`, `file-history/`, `plugins/` cache, `sessions/`, `backups/` | **Per environment**: WSL `~/.claude`; container named volume | Never in git; plaintext at rest |
| `CLAUDE_CODE_OAUTH_TOKEN` (if used) | 0600 file in WSL outside any repo, injected at container start | Never baked into the image or committed |
| GHCR pull credential | WSL Docker credential store | Classic PAT `read:packages`, or the `gh` token with that scope |
| WSL/Dev Containers connectors, theme, font, `dev.containers.*`, `dotfiles.*` | Local Windows synced profile | Nothing language-specific |

The table encodes a security position as well as a tidy layout. The image and the managed policy are the only places that define what tools and permissions exist. The repo defines project behavior. The dotfiles repo defines personal behavior. Volumes hold only what Claude Code writes itself. **Transcripts and history are not encrypted at rest; "OS file permissions are the only protection"** ([.claude directory](https://code.claude.com/docs/en/claude-directory)). That fact alone rules out syncing `projects/` or `history.jsonl` through git.

## Two connectors and a theme make up the local profile

VS Code places each extension by its kind. **UI extensions (themes, keymaps, snippets, grammars) always run locally. Workspace extensions (language servers, linters, debuggers) run wherever the workspace is**, and locally installed workspace extensions appear disabled in remote windows until you install them there ([VS Code: Supporting Remote Development](https://code.visualstudio.com/api/advanced-topics/remote-extensions); [VS Code: Developing inside a Container](https://code.visualstudio.com/docs/devcontainers/containers)). A WSL window is itself a remote with its own `~/.vscode-server/extensions`, and every container has its own server, so nothing installed in one leaks into another. Claude Code behaves as a workspace extension. Anthropic states that the panel and the integrated-terminal `claude` "both run inside the container and share the same `~/.claude` configuration" ([Dev containers](https://code.claude.com/docs/en/devcontainer)). A March 2026 report found that forcing `anthropic.claude-code` to `["ui"]` through `remote.extensionKind` breaks its sidebar in dev containers ([issue #39288 mirror](https://claudeissues.com/issue/39288-remote-extensionkind-ui-causes-sidebar-restoration-error-in-devcontainer)). So Claude Code belongs in the image label and, if you use it outside containers, in the WSL remote. It does not belong in the local Windows extension list.

The local extension list is therefore `ms-vscode-remote.remote-wsl` and `ms-vscode-remote.remote-containers`, both confirmed IDs ([Marketplace: Remote Development](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.vscode-remote-extensionpack)). Optional additions are Remote - SSH and Tunnels, plus a theme, icon pack or keymap of your choice. Leave Python, Pylance, Ruff, Terraform, YAML and similar extensions out. Locally they only affect Windows-native folders, and you shouldn't keep code there anyway. **Leave GitHub Copilot uninstalled locally unless you want it everywhere.** Since VS Code 1.85, a locally installed Copilot, Copilot Chat or GitHub Pull Requests is auto-installed into every dev container through `dev.containers.defaultExtensionsIfInstalledLocally` ([remote release notes 1.85](https://github.com/microsoft/vscode-docs/blob/main/remote-release-notes/v1_85.md)). In the WSL remote, install only `anthropic.claude-code`, and only if you run Claude in WSL windows. Running `claude` in a VS Code integrated terminal auto-installs the extension unless `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1` is set ([VS Code](https://code.claude.com/docs/en/vs-code)).

The synced user `settings.json` should contain only editor and UI preferences plus Dev Containers plumbing:

```jsonc
{
  // UI-only: safe to sync to every machine and to apply in every remote
  "workbench.colorTheme": "Default Dark Modern",
  "editor.fontFamily": "Cascadia Code, Consolas, monospace",
  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true,
  // Deliberately absent: "[python]", "[terraform]", editor.defaultFormatter,
  // formatOnSave, interpreter paths. The image's Remote settings own these.

  // Containers are authoritative for extensions
  "dev.containers.defaultExtensions": [],
  "dev.containers.defaultExtensionsIfInstalledLocally": [],   // opt out of Copilot/PR auto-install (see unverified list)
  "dev.containers.dockerCredentialHelper": true,               // host GHCR auth inside VS Code-spawned processes

  // Personal shell + Claude config arrive via dotfiles at container creation
  "dotfiles.repository": "<you>/dotfiles",
  "dotfiles.targetPath": "~/dotfiles",
  "dotfiles.installCommand": "install.sh",

  // Machine-specific: enable only if Docker CE runs inside WSL (no Docker Desktop)
  // "dev.containers.executeInWSL": true,
  // "dev.containers.dockerPath": "/usr/bin/docker",
  "settingsSync.ignoredSettings": [
    "dev.containers.executeInWSL",
    "dev.containers.executeInWSLDistro",
    "dev.containers.dockerPath"
  ]
}
```

The rationale for leaving out language settings is a specific leak mechanism. A synced `"[python]": {"editor.defaultFormatter": "charliermarsh.ruff"}` applies as the User layer in **every** container, including ones without Ruff. `settingsSync.ignoredSettings` only stops cross-machine propagation, not application to containers on the same machine ([VS Code: Settings Sync](https://code.visualstudio.com/docs/configure/settings-sync)). Keep a single thin Default profile. Profiles and dev containers have historically interacted badly: extensions declared for containers were once installed only into the default profile, which a later fix addressed, and devcontainer.json has no property for choosing a profile ([microsoft/vscode #176678](https://github.com/microsoft/vscode/issues/176678); [containers.dev: Supporting tools](https://containers.dev/supporting)). Do not put `CLAUDE_CONFIG_DIR` in `claudeCode.environmentVariables` locally. That setting does not reach the extension host's session listing ([issue #30538](https://github.com/anthropics/claude-code/issues/30538)), and in containers `containerEnv` is the right channel.

## The dev image carries a pinned Claude, policy and VS Code metadata

Anthropic's Dev Container Feature is the wrong tool for a prebuilt, reproducible image. **Feature v1.0.5 has no options, runs an unpinned `npm install -g @anthropic-ai/claude-code`, and installs Node 18 when Node is missing**. Node 18 is below the npm package's stated Node 22 floor ([devcontainer-feature.json](https://github.com/anthropics/devcontainer-features/blob/main/src/claude-code/devcontainer-feature.json); [install.sh](https://github.com/anthropics/devcontainer-features/blob/main/src/claude-code/install.sh); [Setup](https://code.claude.com/docs/en/setup)). The docs themselves say: "To pin a specific Claude Code version for reproducible builds, install it from your Dockerfile … instead of using the feature" ([Dev containers](https://code.claude.com/docs/en/devcontainer)). A Feature listed in the repo's devcontainer.json would also force a local derived build, which defeats digest pinning. For integrity, **each release publishes a `manifest.json` of per-platform SHA256 checksums signed with an Anthropic GPG key (fingerprint `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`), for releases from 2.1.89 onward**. Linux binaries are not individually code-signed ([Setup](https://code.claude.com/docs/en/setup)). The snippet uses 2.1.296, the newest CHANGELOG entry seen during research. Treat it as a placeholder and pin whatever version you have actually validated.

```dockerfile
# ---- dev stage: FROM the ci stage, so CI and dev share one toolchain ----
FROM ci AS dev
ARG TARGETARCH
ARG USERNAME=vscode
ARG CLAUDE_CODE_VERSION=2.1.296          # exact version; bump deliberately via PR
ARG CLAUDE_GPG_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
USER root

# UNVERIFIED: the binary path "$base/$plat/claude" and manifest field ".platforms[$p].checksum" below
# are assumptions; check them against a real manifest.json before relying on this.
# (No inline comments inside the RUN: a '#' would swallow the backslash-joined lines.)
# Vendored public key, committed to the image repo after you check its fingerprint out-of-band
COPY claude-code-release.asc /tmp/claude-code-release.asc
RUN set -eu; \
    apt-get update; apt-get install -y --no-install-recommends ca-certificates curl gnupg jq sudo iptables ipset dnsutils bubblewrap socat; \
    rm -rf /var/lib/apt/lists/*; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --import /tmp/claude-code-release.asc; \
    gpg --batch --with-colons --fingerprint | grep -q "^fpr:::::::::${CLAUDE_GPG_FPR}:"; \
    case "$TARGETARCH" in amd64) plat=linux-x64 ;; arm64) plat=linux-arm64 ;; *) exit 1 ;; esac; \
    base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}"; \
    curl -fsSLo /tmp/manifest.json     "$base/manifest.json"; \
    curl -fsSLo /tmp/manifest.json.sig "$base/manifest.json.sig"; \
    gpg --batch --verify /tmp/manifest.json.sig /tmp/manifest.json; \
    curl -fsSLo /usr/local/bin/claude "$base/$plat/claude"; \
    want="$(jq -r --arg p "$plat" '.platforms[$p].checksum' /tmp/manifest.json)"; \
    echo "${want}  /usr/local/bin/claude" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/claude; \
    rm -rf "$GNUPGHOME" /tmp/manifest.json* /tmp/claude-code-release.asc; \
    /usr/local/bin/claude --version

# Policy at highest precedence; volume mountpoint pre-owned so the new named volume inherits ownership
RUN install -d -m 0755 /etc/claude-code \
 && install -d -o ${USERNAME} -g ${USERNAME} -m 0700 /home/${USERNAME}/.claude
COPY --chmod=0644 managed-settings.json /etc/claude-code/managed-settings.json
COPY --chmod=0755 init-firewall.sh /usr/local/bin/init-firewall.sh
RUN echo "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/claude-firewall \
 && chmod 0440 /etc/sudoers.d/claude-firewall

ENV DISABLE_UPDATES=1 \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude
USER ${USERNAME}
# LABEL devcontainer.metadata='<minified JSON below>'
```

Install into `/usr/local/bin` rather than the native installer's `~/.local/share/claude/versions/` for two reasons. The binary becomes root-owned and immutable to the agent running as `vscode`. A home-directory volume also cannot shadow it. Use **`DISABLE_UPDATES` rather than `DISABLE_AUTOUPDATER`**: the latter "only stops the background check; `claude update` and `claude install` still work" ([Setup](https://code.claude.com/docs/en/setup)). If the binary-download details above don't match the release bucket, fall back to one of two documented routes. One is the signed apt repo (`deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main`). The other is the docs' own Dockerfile recipe, `npm install -g @anthropic-ai/claude-code@X.Y.Z`. That route installs the same native binary through an optional dependency, but it warns on Node below 22 and gives you no GPG check ([Setup](https://code.claude.com/docs/en/setup); [Dev containers](https://code.claude.com/docs/en/devcontainer)). A minimal `managed-settings.json` might look like this:

```json
{
  "permissions": {
    "deny": ["Read(~/.ssh/**)", "Read(**/.env)", "Read(**/.env.*)"],
    "disableBypassPermissionsMode": "disable"
  },
  "sandbox": {
    "enabled": true,
    "enableWeakerNestedSandbox": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false
  }
}
```

Each key is documented. **Deny rules block in every mode, including bypass**. `disableBypassPermissionsMode` blocks `--dangerously-skip-permissions`. In an unprivileged container, bubblewrap needs `enableWeakerNestedSandbox`, which is acceptable only "when the outer container already provides the isolation boundary" ([Permission modes](https://code.claude.com/docs/en/permission-modes); [Sandboxing](https://code.claude.com/docs/en/sandboxing)). The sandbox block is optional. It covers shell commands only, not file tools, MCP servers or hooks. Anthropic notes that a repo-built image is "a convention rather than an enforcement boundary" ([Sandbox environments](https://code.claude.com/docs/en/sandbox-environments)). Baking the policy into a CI-built GHCR image is stronger than the in-repo Dockerfile example, because only the image publisher controls it. That holds only while sudo stays limited to the firewall script.

The image label carries the VS Code half. A prebuilt image's `devcontainer.metadata` label is "merged with any local devcontainer.json file contents at the time the container is created". **`containerEnv` and `remoteEnv` resolve last-value-wins per variable, `mounts` and `capAdd` are collected, `customizations` merging "is left to the tools", and "the devcontainer.json is considered last"** ([containers.dev spec: merge logic](https://containers.dev/implementors/spec/#merge-logic)). Before serializing it into the `LABEL`, the payload looks like this:

```json
[{
  "remoteUser": "vscode",
  "containerEnv": { "CLAUDE_CONFIG_DIR": "/home/vscode/.claude", "DISABLE_UPDATES": "1" },
  "capAdd": ["NET_ADMIN", "NET_RAW"],
  "postStartCommand": "sudo /usr/local/bin/init-firewall.sh",
  "waitFor": "postStartCommand",
  "customizations": { "vscode": {
    "extensions": ["anthropic.claude-code", "ms-python.python", "charliermarsh.ruff",
                   "hashicorp.terraform", "redhat.vscode-yaml"],
    "settings": {
      "[python]": { "editor.defaultFormatter": "charliermarsh.ruff", "editor.formatOnSave": true,
                    "editor.codeActionsOnSave": { "source.fixAll": "explicit", "source.organizeImports": "explicit" } },
      "[terraform]": { "editor.defaultFormatter": "hashicorp.terraform", "editor.formatOnSave": true },
      "python.defaultInterpreterPath": "/usr/local/bin/python"
    }
  } }
}]
```

The consuming repo's devcontainer.json stays short. It pins the image by digest, because **GHCR has no immutable tags: as of September 2026 the feature request was unanswered and "a pushed tag can always be retargeted"** ([GitHub discussion #181783](https://github.com/orgs/community/discussions/181783)). It also declares the Claude volume, keyed per project as Anthropic recommends ([Dev containers](https://code.claude.com/docs/en/devcontainer)):

```jsonc
{
  "name": "myrepo",
  // ghcr.io/<you>/dev:2026.10.1 — update this digest via a Renovate/Dependabot PR; never use a bare tag
  "image": "ghcr.io/<you>/dev@sha256:<digest>",

  // Path alignment: identical absolute path in WSL and container (see trade-off below)
  "workspaceMount": "source=${localWorkspaceFolder},target=${localWorkspaceFolder},type=bind",
  "workspaceFolder": "${localWorkspaceFolder}",

  // Per-project Claude state that survives rebuilds; CLAUDE_CONFIG_DIR points .claude.json inside it
  "mounts": ["source=claude-code-config-${devcontainerId},target=/home/vscode/.claude,type=volume"],
  "containerEnv": { "CLAUDE_CONFIG_DIR": "/home/vscode/.claude" },

  // Optional: setup-token auth from a 0600 file in WSL (docker run fails if the file is missing)
  "runArgs": ["--env-file", "${localEnv:HOME}/.config/claude-code/container.env"],

  "customizations": { "vscode": { "extensions": ["-hashicorp.terraform"] } }   // per-repo opt-out
}
```

The two ownership details matter. **A new named volume copies ownership from the image path if the path exists**, which is why the Dockerfile pre-creates `/home/vscode/.claude`. Without that, users report root-owned mounts that need a `chown` ([warski.org](https://warski.org/blog/secure-dangerous-claude-code-vs-code-setup/)). Also keep the image user at **UID 1000** to match the usual WSL user. `updateRemoteUserUID` otherwise rewrites the UID at create time, and that produces a local derived image instead of the exact pinned digest ([VS Code: Add a non-root user](https://code.visualstudio.com/remote/advancedcontainers/add-nonroot-user)).

Path alignment is a real trade-off, not a free win. **Transcripts live at `projects/<path with every non-alphanumeric replaced by '->`**, so WSL's `/home/ian/src/repo` and the container's `/workspaces/repo` are different buckets ([Sessions](https://code.claude.com/docs/en/sessions)). Mounting at `${localWorkspaceFolder}` gives the same key, absolute path and `git worktree list` output on both sides. It sidesteps the worktree key mismatch reported in issue #33665, where `/resume` found "No conversations found" ([#33665 mirror](https://claudeissues.com/issue/33665-bug-internal-project-path-key-inconsistency-in-git-worktrees-inside-devcontainer)). It also makes Docker-outside-of-Docker bind paths match the host ([VS Code: Use Docker from a container](https://code.visualstudio.com/remote/advancedcontainers/use-docker-kubernetes)). The costs: it breaks the `/workspaces/<name>` convention that Features and Codespaces assume, it creates root-owned `/home/ian` parent directories in the container, and nothing in the repo can hard-code that path. **No official source recommends it**; it follows from documented `--mount` semantics. Adopt it if you use worktrees or want the cross-environment memory trick in the next section. Otherwise the default `/workspaces/<repo>` with a per-project volume is fine, because the volume already isolates projects.

The VS Code panel adds a version wrinkle. **The extension bundles its own CLI, and "the extension's version number is the Claude Code version it bundles"** ([VS Code](https://code.claude.com/docs/en/vs-code)). Pinning `/usr/local/bin/claude` therefore pins the terminal, not the panel. `claudeCode.claudeProcessWrapper` can redirect the panel to a separate binary, but "the bundled binary path is passed as an argument when present". Pointing it straight at `/usr/local/bin/claude` would hand Claude a stray argument. A small wrapper that drops a leading executable path and runs `exec /usr/local/bin/claude "$@"` is the likely fix. It is untested here. Don't use managed `requiredMaximumVersion` to force alignment either: it could stop a newer bundled panel CLI from starting.

## Claude configuration travels by git; Claude state stays in volumes

Personal Claude customization is plain files, which suits git. VS Code's dotfiles support clones **one** repository into every new container and runs its install command ([VS Code: Developing inside a Container](https://code.visualstudio.com/docs/devcontainers/containers)). So put the Claude config in a `claude/` subtree of the same dotfiles repo instead of a second repo:

```
dotfiles/
├── install.sh                  # shell dotfiles + runs claude/install.sh
├── .gitignore                  # whitelist: ignore everything except listed paths
└── claude/
    ├── install.sh              # copies into ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
    ├── CLAUDE.md               # personal global instructions
    ├── rules/*.md              # user-level rules (paths: frontmatter allowed)
    ├── skills/<name>/SKILL.md
    ├── agents/*.md             # personal subagents
    ├── commands/*.md
    ├── output-styles/
    ├── keybindings.json
    ├── hooks/*.sh              # referenced from settings as "$HOME/.claude/hooks/x.sh"
    ├── settings.base.json      # hooks, enabledPlugins, extraKnownMarketplaces, cleanupPeriodDays, autoMemoryEnabled
    └── bootstrap/
        ├── plugins.sh          # claude plugin marketplace add … ; claude plugin install …@… --scope user
        └── mcp-user.sh         # claude mcp add --scope user … (user MCP lives in .claude.json, not a dotfile)
# NEVER: .credentials.json, .claude.json, projects/, history.jsonl, file-history/,
#        plugins/, sessions/, backups/, paste-cache/, skills/synced/, plugins/synced/
```

**Copy, don't symlink, `settings.json`.** The docs warn that if the file is "linked to a read-only copy, the change applies to the current session and is gone in the next one" ([Settings](https://code.claude.com/docs/en/settings)). A community report shows Claude Code saving credentials via temp file plus atomic `rename()`, which turned a symlink into a regular file ([issue #76561](https://github.com/anthropics/claude-code/issues/76561)). The installer should deep-merge `settings.base.json` into any existing `settings.json` (for example `jq -s '.[0] * .[1]'`), so that `/config` and `/model` edits made inside an environment survive. It should copy directory trees without deleting, so it doesn't wipe `skills/synced/`, which claude.ai account sync owns ([Skills](https://code.claude.com/docs/en/skills)). Copying `rules/` into the config dir also avoids the approval prompt that symlinked rules pointing outside the working directory can trigger ([Memory](https://code.claude.com/docs/en/memory)). Inside containers, `CLAUDE_CONFIG_DIR` is already set when the dotfiles hook runs, so the same script targets the volume there and `~/.claude` in WSL. Because `CLAUDE_CONFIG_DIR` equals `$HOME/.claude` in the container, hook commands written as `$HOME/.claude/hooks/…` resolve in both places.

MCP and plugins each need a bootstrap step, because their state lives in files that don't belong in git. **User- and local-scope MCP servers are stored in `.claude.json`. Local scope is keyed by absolute project path, so it won't follow a repo between path layouts. Project scope is the committed `.mcp.json`, which expands `${VAR}` and `${VAR:-default}`** ([MCP](https://code.claude.com/docs/en/mcp)). Put team servers in `.mcp.json`, with their binaries installed in the image as Anthropic recommends ([Dev containers](https://code.claude.com/docs/en/devcontainer)). Script personal servers with `claude mcp add --scope user`. Plugins enabled through `enabledPlugins` are not downloaded automatically: "Committing that entry … doesn't download it to their machines" ([Plugins install](https://code.claude.com/docs/en/plugins/install)). So `bootstrap/plugins.sh` must run `claude plugin marketplace add` and `claude plugin install …@… --scope user` once per config dir. The per-project volume then caches the result across rebuilds. For plugins you want baked into the image, `CLAUDE_CODE_PLUGIN_SEED_DIR` takes read-only, pre-populated plugin directories built "into a container image" ([Env vars](https://code.claude.com/docs/en/env-vars)).

Sessions are where expectations need resetting. Within one environment the design works well. **The per-project volume keeps transcripts across rebuilds. `--resume <session-id>` searches "every other project on this machine" (v2.1.223+) and resolves when exactly one match exists. Ctrl+A widens the picker to all projects. `--resume <absolute .jsonl path>` resumes an arbitrary transcript** ([Sessions](https://code.claude.com/docs/en/sessions)). Panel and terminal share history inside a container ([VS Code](https://code.claude.com/docs/en/vs-code)). Across environments there is no live sync, and **Anthropic offers no feature that syncs local transcripts between machines**. The cross-device features are cloud sessions with one-way `--teleport`, plus Remote Control ([Cloud/web](https://code.claude.com/docs/en/claude-code-on-the-web)). The practical handoff is manual: copy a `.jsonl` into a gitignored folder of the bind-mounted checkout and run `claude --resume <path>` on the other side. Keep in mind that the transcript format "is internal to Claude Code and changes between versions" ([Sessions](https://code.claude.com/docs/en/sessions)). Auto memory carries knowledge forward better than transcripts do. By default it lives at `~/.claude/projects/<project>/memory/` and is "machine-local". `autoMemoryDirectory` is settable at any scope ([Memory](https://code.claude.com/docs/en/memory)). An absolute `autoMemoryDirectory` in the checkout's gitignored `.claude/settings.local.json`, pointing at something like `/home/ian/src/repo/.claude/auto-memory`, would be visible to both WSL and the container through the aligned bind mount, so both environments would share one memory directory. This design is inferred and untested. It also creates a **persistence channel for prompt injection**: a compromised container session can write memory that a later WSL session loads. Review that directory the way you would review code. Finally, `cleanupPeriodDays` defaults to **30 days** and sweeps transcripts. Raise it in `settings.base.json` if you value long history, and remember that the history is plaintext.

## Sharing one live ~/.claude invites races and a container escape route

The tempting shortcut, bind-mounting WSL's `~/.claude` into every container, has three documented or reported failure classes. First, **`~/.claude.json` is rewritten whole-file**. One report on v2.1.198 describes concurrent sessions clobbering trust flags, and a maintainer "could not reproduce on 2.1.233", saying protections predate 2.1.198 ([issue #73364](https://github.com/anthropics/claude-code/issues/73364)). That report follows a cluster of v2.1.59-era corruption reports ([claudeissues.com](https://claudeissues.com/issue/29111-claude-json-write-race-condition-with-multiple-concurrent-sessions-v2-1-59)). Second, **OAuth refresh tokens rotate**. One process's refresh can invalidate another's token, and on failure the CLI writes a logged-out stub that, through a shared file, logs out every client. This was reported on WSL2 with no maintainer reply ([issue #76561](https://github.com/anthropics/claude-code/issues/76561)). Third, path-keyed state from the host confuses the container. Issue #16250's suggested workaround is literally "Don't share `~/.claude/projects/` between host and container" ([#16250 mirror](https://claudeissues.com/issue/16250-bug-resume-shows-sessions-from-wrong-project-directory-in-devcontainer)). Add version skew to these: an auto-updating WSL CLI, a pinned image CLI and an extension-bundled CLI would all write the same files. Add `ide/<port>.lock` files that point at ports unreachable from the other side. The most serious problem is security. **Writable config paths "can persist hooks, permission rules, or MCP servers that run unsandboxed"** ([Sandbox environments](https://code.claude.com/docs/en/sandbox-environments)). A prompt-injected agent inside the container could plant a hook that runs on the WSL host the next time you start `claude` there. That defeats the container boundary through configuration.

Authentication in containers therefore comes down to two acceptable options. **Option A: `claude setup-token` produces a one-year token for `CLAUDE_CODE_OAUTH_TOKEN`. It "does not save the token anywhere", ranks above `/login` credentials, and "can only make model requests, so it can't establish Remote Control sessions or fetch claude.ai connectors"** ([Authentication](https://code.claude.com/docs/en/authentication)). It keeps containers off the shared refresh-token chain, which is the workaround named in #76561. Store it in a 0600 env file in WSL outside any repo and inject it with `--env-file`. Accept that every process in the container, including commands Claude runs, can read it, and that `docker inspect` shows it. **Option B: run `/login` inside each container, persisted in its volume.** You get full features (connectors, Remote Control, claude.ai skill and plugin sync into `skills/synced/` and `plugins/synced/`). You also re-login once per project volume, and each volume becomes another device in the refresh-rotation pool. One unconfirmed report describes cross-device invalidation on a three-machine Max account ([issue #80292](https://github.com/anthropics/claude-code/issues/80292)). Where the localhost callback doesn't route, paste the code at "Paste code here if prompted" ([Dev containers](https://code.claude.com/docs/en/devcontainer)). In WSL itself, a normal `/login` with the file at `~/.claude/.credentials.json` (mode 0600; Linux has no keyring) is the right choice. Whichever option you pick, follow Anthropic's baseline. Run non-root (bypass mode is refused as root). **Never mount `~/.ssh` or cloud credential files; prefer "repository-scoped or short-lived tokens"**. Remember that with bypass enabled, a malicious repo can exfiltrate "the Claude Code credentials stored in `~/.claude`" ([Dev containers](https://code.claude.com/docs/en/devcontainer)). Don't mount the Docker socket into the dev container: socket access is equivalent to root on the Docker host. That is general Docker knowledge; the Claude docs don't state it.

If you want a single login and cross-project `--resume` among containers only, a **shared named volume** (`claude-code-config` with no `${devcontainerId}`) is the middle option Anthropic documents ([Dev containers](https://code.claude.com/docs/en/devcontainer)). It requires a unique workspace path per repo. Otherwise every project collapses into one `-workspace` bucket, as in the reference config's `/workspace`. It inherits the same concurrent-writer risks when two containers run at once, and one compromised container can read every project's transcripts. For a solo developer who usually runs one container at a time, that is a defensible choice. It is not the default here.

## The reference firewall allowlist has fallen behind current hosts

Anthropic's reference `init-firewall.sh` is a sound pattern with a stale list. It resolves A records once at start for `registry.npmjs.org`, `api.anthropic.com`, `sentry.io`, `statsig.com` and three VS Code hosts. It adds GitHub's published CIDRs, allows the host /24, outbound port 22 and DNS, and drops everything else ([init-firewall.sh](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh)). The current network-requirements page lists hosts that are missing from that script: **`claude.ai`, `claude.com` (sign-in redirect), `platform.claude.com` (OAuth token exchange and refresh), `downloads.claude.ai` (installer, updater, plugin executables), and `mcp-proxy.anthropic.com` (claude.ai connectors)**. It also lists `raw.githubusercontent.com`, and it names Datadog intake hosts for telemetry instead of Sentry or Statsig ([Network config](https://code.claude.com/docs/en/network-config)). The likely consequence is that in-container `/login` and token refresh fail under the stock script unless another rule happens to cover those hosts. This is inference, not a tested result, and the script's commit history couldn't be retrieved to date the drift. The reference also runs on `node:20` against a Node 22+ npm requirement. Anthropic itself frames the setup as "a working example rather than a maintained base image" ([Dev containers](https://code.claude.com/docs/en/devcontainer)).

When you copy the script, treat the allowlist as your own code. Add the hosts above. Drop the retired telemetry hosts unless you decide to allow Datadog. Add the GHCR, package-index and marketplace hosts your toolchain needs. Then decide whether outbound 22 to any address and the whole host /24 are acceptable, because both are exfiltration paths. Option A auth narrows the needs further: a model-requests-only token plausibly needs `api.anthropic.com` and not the OAuth hosts, which is another untested inference. Two structural weaknesses remain. DNS is resolved once, so long-lived containers can lose CDN-backed hosts when their IPs rotate. And any allowed broad domain, `github.com` especially, remains an exfiltration channel ([Sandboxing](https://code.claude.com/docs/en/sandboxing)).

### Decision points

| Decision | Default recommended here | Switch when |
|---|---|---|
| Container Claude state scope | Per-project volume `claude-code-config-${devcontainerId}` | You want one login and cross-project resume, and rarely run containers concurrently → shared volume |
| Container auth | `setup-token` via `--env-file` | You need connectors, Remote Control or claude.ai skill sync → `/login` per volume |
| Workspace path | Aligned to the WSL path | You use Codespaces or rely on `/workspaces` conventions → default path |
| Claude install method | Native binary, GPG + SHA256 verified, `/usr/local/bin` | Download layout differs from the snippet → signed apt repo or documented `npm …@X.Y.Z` |
| Bypass permissions | Disabled in managed settings | Unattended runs on trusted repos behind an updated firewall → allow, keep deny rules |
| WSL CLI updates | Pin the same version as the image and set `DISABLE_UPDATES` | You prefer freshness in WSL → `autoUpdatesChannel: "stable"` (config dirs are separate, so skew is tolerable) |
| Copilot | Not installed locally | You want it in every container → install locally; 1.85+ propagates it |
| Docker engine | Docker Desktop (the only Windows engine VS Code documents) | Licensing or overhead pushes you to Docker CE in WSL → `executeInWSL` + `dockerPath` (works, but outside the support matrix) |

### Unverified items

| # | Claim used above | Status |
|---|---|---|
| 1 | Release bucket layout `…/claude-code-releases/<ver>/<platform>/claude` and manifest field `.platforms[<p>].checksum`; where to obtain the GPG public key | Not confirmed in fetched docs; only the manifest/sig URLs and fingerprint are documented |
| 2 | Native binary runs correctly from `/usr/local/bin` without the installer's launcher | Plausible, undocumented |
| 3 | `${devcontainerId}` is substituted inside `mounts` taken from an image label, and is stable across rebuilds | Not confirmed; if in doubt keep the mount in the repo devcontainer.json |
| 4 | `claudeProcessWrapper` argument convention and the shift-and-exec wrapper | Inferred from the setting's description |
| 5 | The extension honors `CLAUDE_CONFIG_DIR` from `containerEnv` (issue #30538 concerns local macOS) | Expected, untested |
| 6 | `autoMemoryDirectory` set from `.claude/settings.local.json` with an absolute path shares memory across WSL and container | Design inference |
| 7 | Stock firewall breaks in-container `/login` and refresh; `setup-token` needs only `api.anthropic.com` | Inference from host lists, untested |
| 8 | Whether `setup-token` auth receives claude.ai skill and plugin sync; whether tokens can be revoked individually | Not documented in fetched pages |
| 9 | `${localEnv:HOME}` resolves to the WSL home in the WSL-window flow; `updateRemoteUserUID` behavior in that flow | Not documented explicitly |
| 10 | `dev.containers.defaultExtensionsIfInstalledLocally: []` fully opts out; current default list beyond Copilot and PRs | Only the 1.85 notes confirmed |
| 11 | Marketplace IDs `ms-python.python`, `charliermarsh.ruff`, `hashicorp.terraform`, `redhat.vscode-yaml` | Standard IDs, not fetched |
| 12 | Exact `permissions.deny` path syntax and nesting of `enableWeakerNestedSandbox` under `sandbox` | Keys documented; exact shapes not confirmed |
| 13 | Atomic rename replacing a symlinked `settings.json` (shown only for credentials) | Extrapolated |
| 14 | File-locking and concurrency safety of `.claude.json` and `history.jsonl` across WSL↔container bind mounts | Undocumented; maintainer says same-machine protections exist |
| 15 | `claudeCode.initialPermissionMode` read from synced User settings vs container Remote settings | Docs say user settings only; Remote layer behavior unknown |

## Conclusion

The central finding is that "consistent across all environments" should mean **consistent configuration, not shared state**. Claude Code keys everything that matters for continuity (transcripts, auto memory, trust, local MCP servers) by absolute path, and it guards its live files with mechanisms built for one machine. Sharing state across WSL and containers turns ordinary use into a concurrency and trust problem. Distributing configuration from git and letting each environment keep its own state removes those problems. The leftover gap, live transcript continuity across environments, is narrow. Path alignment, explicit resume by ID or file, and a deliberately placed auto-memory directory cover most of it.

The second takeaway is that the image is the right enforcement point for more than toolchains. Building the label, the pinned and verified CLI, the managed policy and the firewall into a digest-pinned GHCR image lets one CI pipeline govern editor behavior and agent behavior together. Doing this well means owning the parts Anthropic labels as examples: rewrite the firewall allowlist against the current network page, and bump the CLI version, the digest and the allowlist together in one reviewed change.
