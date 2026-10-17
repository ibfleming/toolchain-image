# Customizing

The `dev` image is opinionated so it works well out of the box: zsh with a modular config,
starship, a one-dark theme, k9s, git defaults and Claude Code. Each of these is a **default, not
a requirement**. This page lists every layer you can override, from lightest touch to heaviest.

| You want to change                          | Lightest way to do it                                |
| ------------------------------------------- | ---------------------------------------------------- |
| Editor extensions or settings               | Your repo's `devcontainer.json`                      |
| An environment default (e.g. `GOTOOLCHAIN`) | `containerEnv` in `devcontainer.json`                |
| Shell aliases, functions, options           | `~/.config/zsh/local.zsh` or `TOOLCHAIN_ZSH_SKIP`    |
| The prompt                                  | Your own `~/.config/starship.toml`                   |
| k9s settings, aliases, skin                 | Edit `~/.config/k9s/`                                |
| Git defaults                                | Your `~/.gitconfig`                                  |
| How Docker runs (host engine, DinD, none)   | The socket mount or a feature in `devcontainer.json` |
| Claude Code permissions                     | A derived image with your own managed policy         |
| Extra tools for yourself or a project       | `mise use -g <tool>`, or the project's `mise.toml`   |
| Different versions of the image's tools     | A derived image (`FROM` `ci` or `dev`)               |
| Everything                                  | Fork the repository and build your own family        |

Changes made only inside a running container (outside the mounted volumes) disappear on rebuild.
To make them stick, put them in your repo's `devcontainer.json` or in a derived image. Where each
kind of setting belongs is in [Architecture](architecture.md).

## Editor: `devcontainer.json`

The image ships its VS Code extensions and settings in its `devcontainer.metadata` label. Your
repository's `devcontainer.json` is merged on top and **wins on conflicts**:

```jsonc
{
  "customizations": {
    "vscode": {
      // a leading "-" removes an extension the image adds
      "extensions": ["-golang.go", "-anthropic.claude-code", "ms-azuretools.vscode-containers"],
      "settings": {
        "editor.formatOnSave": false,
        "terminal.integrated.defaultProfile.linux": "bash", // use bash instead of zsh
      },
    },
  },
}
```

Settings in your personal (synced) VS Code profile also apply inside containers. Keep
language-specific settings there to a minimum, or they'll override every project's.

## Environment defaults

The image sets a few environment variables to keep tool versions pinned to the image:

| Variable                | Image default          | Why                                                                    |
| ----------------------- | ---------------------- | ---------------------------------------------------------------------- |
| `GOTOOLCHAIN`           | `local`                | Go must not download another toolchain because a `go.mod` asks for one |
| `UV_PYTHON_DOWNLOADS`   | `never`                | uv uses the image's Python instead of downloading its own              |
| `UV_PYTHON_PREFERENCE`  | `only-system`          | Same, for uv's interpreter discovery                                   |
| `CLAUDE_CONFIG_DIR`     | `/home/vscode/.claude` | Claude Code's sign-in and conversations live in the per-project volume |
| `GH_NO_UPDATE_NOTIFIER` | `1`                    | The GitHub CLI changes version only with the image                     |

Override any of them per repository:

```jsonc
{ "containerEnv": { "GOTOOLCHAIN": "auto" } }
```

## Shell (zsh)

The login shell is zsh. `~/.zshrc` is a one-line loader for the shared, read-only config in
`/usr/local/share/toolchain/zsh/`:

```text
conf.d/     environment, history, options, theme, key bindings, completion, fzf
aliases/    general, git, kubernetes, tools
functions/  general, git
post.d/     prompt, plugins (autosuggestions, syntax highlighting, fzf-tab), zoxide
```

- **Add your own:** put files in `~/.config/zsh/conf.d/*.zsh` or `~/.config/zsh/local.zsh`.
  They load after the shared aliases and functions, so they can override them.
- **Skip shared modules:** list them by path without `.zsh`, above the `source` line in `~/.zshrc`:

  ```zsh
  TOOLCHAIN_ZSH_SKIP=(aliases/git post.d/10-prompt)
  source /usr/local/share/toolchain/zsh/zshrc
  ```

- **Welcome screen:** the first interactive terminal after each container start shows the image
  version and build, the repository and branch, a status row, the main tool versions (marked `↑`
  updated or `+` new since the previous release), shortcuts and a tip of the day.
  - `welcome` shows it again, `welcome tools` lists every pinned tool, `welcome keys` every alias
    and key binding. `--plain` (or `NO_COLOR`) prints without color or box.
  - Status dots are green when set up: `claude` (signed in or an API key set), `gh` (signed in or `GH_TOKEN` set), `git` (an email
    in your git config), `ssh` (a forwarded agent) and `kube` (a current context).
  - `TOOLCHAIN_WELCOME` in `remoteEnv` or `~/.zshrc`: `once` (default), `always` (every new
    terminal) or `off`.
  - It's pure zsh: it reads files written at build time under `/etc/toolchain/` and runs no tools,
    so it adds a few milliseconds to the first shell.
- **Replace it entirely:** write your own `~/.zshrc` without the `source` line.
- **Use bash:** set `terminal.integrated.defaultProfile.linux` to `bash` (see above). The image's
  tools don't depend on zsh.

## Logging in your scripts

Both images ship the logging library their own scripts use, at
`/usr/local/lib/toolchain/log.sh`. Source it from any Bash script (4.2 or newer) to get leveled,
timestamped lines in the One Dark colors:

```bash
source /usr/local/lib/toolchain/log.sh
log::info "deploying ${service}"   # 2026-10-12T13:09:31-0700 INFO  deploy: deploying api
log::warn "no cache, building from scratch"
log::fatal "missing KUBECONFIG"   # logs, then exits 1
```

- **Levels:** `log::debug`, `log::info`, `log::ok` (green, info level), `log::warn`, `log::error`
  and `log::fatal`. Everything goes to STDERR, so STDOUT stays free for your script's data.
- **Settings:**
  - `TOOLCHAIN_LOG_LEVEL`: `debug`, `info` (default), `warn` or `error`.
  - `TOOLCHAIN_LOG_COLOR`: `auto` (default; color when STDERR is a terminal or in GitHub
    Actions), `always` or `never`. `NO_COLOR` turns color off in `auto` mode.
  - `TOOLCHAIN_LOG_TAG`: the name shown in each line (default: the script's file name).
- **GitHub Actions:** warnings and errors also become annotations on the workflow run.
- **Colors:** `/usr/local/lib/toolchain/palette.sh` defines the palette (`PALETTE_BLUE='#61afef'`,
  and so on, each with a 256-color fallback) if you want to match it elsewhere.

## Prompt (starship)

The shared prompt is `/usr/local/share/toolchain/starship/starship.toml`. A personal
`~/.config/starship.toml` takes precedence automatically, and so does an explicit
`STARSHIP_CONFIG`. To turn the prompt off, skip `post.d/10-prompt`.

In the dev image, the prompt's first segment is **Docker blue with the Docker whale** instead of
orange with the OS logo, so a shell in a container can't be mistaken for one on the host. The repo
holds one file: the image's copy selects its `one_dark_container` palette and the whale at build
time, and hosts that install the shell use the file as it is. `make shell-live` mounts the repo's
file, so it shows the host look.

## k9s

`~/.config/k9s/` is seeded with a config, aliases, hotkeys and a one-dark skin. It's owned by
`vscode`, so you can edit or replace any of it. Set `ui.skin` in `config.yaml` to change the skin.

## Git

`/etc/gitconfig` sets system-level defaults: the delta pager, `zdiff3` conflict style,
`pull.rebase` and `fetch.prune`. Any value in your `~/.gitconfig` overrides them. VS Code copies
your host `.gitconfig` into the container by default.

The GitHub CLI (`gh`) ships signed out, and the image never contains a token. Sign in once per
container with `gh auth login` (the token is stored in `~/.config/gh/`, inside the container), or
set `GH_TOKEN` for the session. To keep the sign-in across rebuilds, mount a volume at
`/home/vscode/.config/gh` in `devcontainer.json`.

## Docker

The `dev` image has the Docker CLI with the buildx and compose plugins, but no engine. Pick where
the engine comes from in `devcontainer.json`.

**The host's engine (the template's default).** The template mounts your host's socket at
`/var/run/docker-host.sock`. On every start, the image serves it to `vscode` as
`/var/run/docker.sock`, using a small socat proxy (`docker-socket-init`, run by the image's
`postStartCommand`). The proxy leaves the host's socket and its permissions alone.
`docker ps` then shows your host's containers, and builds share the host's image cache.

- **Bind mounts** in `docker run -v` or compose files are resolved on the host, so use host
  paths: the template sets `LOCAL_WORKSPACE_FOLDER` to the workspace's host path
  (`docker run -v "$LOCAL_WORKSPACE_FOLDER:/src" …`).
- **Rootless Docker or Podman:** change the mount's source to your socket, e.g.
  `source=${localEnv:XDG_RUNTIME_DIR}/docker.sock`.
- **Security:** access to the Docker socket is root on the host. Anything in the container,
  including an agent, can use it. If that's not acceptable, use Docker-in-Docker or no Docker.

**Docker-in-Docker (opt-in).** A separate engine runs inside the container, isolated from the
host's containers and images. It needs a privileged container and starts a little slower. Remove
the socket mount and add the feature (`moby: false` installs Docker CE, which supports Debian 13):

```jsonc
{
  "features": { "ghcr.io/devcontainers/features/docker-in-docker:2": { "moby": false } }
}
```

The feature installs its own CLI in `/usr/bin`, but the image's pinned CLI comes first on `PATH`.
`docker-socket-init` does nothing in this mode.

**No Docker.** Remove the socket mount. The CLI stays, with nothing to talk to.

## Claude Code

| Aspect            | Default                                                                                                                  | How to change it                                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| CLI               | Not installed: the VS Code extension (in the image's label) runs its own bundled CLI                                     | Install it in your container (`mise use -g` or Anthropic's installer) if you want `claude` in a terminal |
| Policy            | `/etc/claude-code/managed-settings.json`: deny reading credential locations and `.env` files, no bypass-permissions mode | Replace it in a derived image (below). The policy outranks all user and project settings                 |
| Everything else   | Claude Code defaults                                                                                                     | User settings (`~/.claude/settings.json`) and project settings (`.claude/settings.json`)                 |
| Not wanted at all | The extension is installed                                                                                               | Remove it per repository (`-anthropic.claude-code`)                                                      |

The managed policy is a **secure default**, not an enforcement boundary: `vscode` has passwordless
sudo, so it can be changed inside a running container. Organizations that need a policy users
can't change should publish a derived image with their own policy _and_ remove sudo there.

```dockerfile
FROM ghcr.io/<owner>/toolchain/dev:<version>@sha256:<digest>
COPY managed-settings.json /etc/claude-code/managed-settings.json
```

## Tools and versions

- **Your own extra tools (mise):** in the dev container's shell, `mise use -g <tool>` installs a
  tool for you, and a project's own `mise.toml` installs its tools. Both go into a personal mise
  layer in your home directory, kept apart from the image's:
  - **Config:** `~/.config/mise/config.toml` for your tools (mise trusts it as global config), and
    the project's `mise.toml`. The template trusts the
    opened workspace folder (`MISE_TRUSTED_CONFIG_PATHS`), so a project's `mise.toml` with `[env]`
    or hooks works without `mise trust`; any other folder still asks.
  - **Tools:** `~/.local/share/mise`, a volume in the template shared by your containers, so a
    rebuild doesn't download them again.
  - **Extras only:** these tools come _after_ the image's on `PATH`, so they can't replace an image
    tool; a different version of one means a derived image (below). The image's own manifests
    are hidden from this layer, so nothing of the toolchain is downloaded twice, and `versions`
    still lists the image's tools.
  - The zsh module `conf.d/05-mise-user` sets this up; skip it (`TOOLCHAIN_ZSH_SKIP`) to keep mise
    as the image configures it.
- **One-off, at runtime:** `sudo apt-get install …` works, but is lost on rebuild.
- **Per repository:** derive from the image in the repo's own Dockerfile and point
  `devcontainer.json` at it (`"build": {"dockerfile": "Dockerfile"}`):

  ```dockerfile
  FROM ghcr.io/<owner>/toolchain/dev:<version>@sha256:<digest>
  RUN sudo apt-get update && sudo apt-get install -y --no-install-recommends postgresql-client \
   && sudo rm -rf /var/lib/apt/lists/*
  ```

  CI jobs can do the same with `FROM …/ci`, so both stay in step.

- **For everyone using your images:** add the tool to `toolchain/mise.toml` (CI and dev),
  `toolchain/dev/mise.toml` (dev only) or `toolchain/shell/mise.toml` (the shell's own tools:
  starship, fzf, eza, ...) in your fork, run `make lock`, and add a probe to `tests/smoke.sh`.

The image's tools live in a root-owned mise data directory and are linked into `/usr/local/bin`,
so they are on `PATH` in every process, not only in interactive shells.

## Personal settings

Themes, fonts, keybindings and other personal preferences are yours, not the platform's: keep them
in your VS Code user settings (Settings Sync carries them into every container) and outside the
repository. See [Architecture](architecture.md#what-belongs-where).

## Your own image family

Fork the repository to change the defaults for everyone who uses your images: tools, theme, policy
or base image. The CI and release workflows publish to `ghcr.io/<your-owner>/toolchain/{ci,dev}`
automatically. See the [README](../README.md#running-your-own-copy).
