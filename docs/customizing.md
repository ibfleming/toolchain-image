# Customizing

The `dev` image is opinionated so it works well out of the box: zsh with a modular config,
starship, a one-dark theme, k9s, git defaults and Claude Code. Each of these is a **default, not
a requirement**. This page lists every layer you can override, from lightest touch to heaviest.

| You want to change                          | Lightest way to do it                             |
| ------------------------------------------- | ------------------------------------------------- |
| Editor extensions or settings               | Your repo's `devcontainer.json`                   |
| An environment default (e.g. `GOTOOLCHAIN`) | `containerEnv` in `devcontainer.json`             |
| Shell aliases, functions, options           | `~/.config/zsh/local.zsh` or `TOOLCHAIN_ZSH_SKIP` |
| The prompt                                  | Your own `~/.config/starship.toml`                |
| k9s settings, aliases, skin                 | Edit `~/.config/k9s/`                             |
| Git defaults                                | Your `~/.gitconfig`                               |
| Claude Code permissions                     | A derived image with your own managed policy      |
| Tools or tool versions                      | A derived image (`FROM` `ci` or `dev`)            |
| Everything                                  | Fork the repository and build your own family     |

Changes made only inside a running container (outside the mounted volumes) disappear on rebuild.
To make them stick, put them in a dotfiles repo (see [Personal config](#personal-config-that-follows-you)),
in your repo's `devcontainer.json`, or in a derived image.

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

| Variable               | Image default          | Why                                                                    |
| ---------------------- | ---------------------- | ---------------------------------------------------------------------- |
| `GOTOOLCHAIN`          | `local`                | Go must not download another toolchain because a `go.mod` asks for one |
| `UV_PYTHON_DOWNLOADS`  | `never`                | uv uses the image's Python instead of downloading its own              |
| `UV_PYTHON_PREFERENCE` | `only-system`          | Same, for uv's interpreter discovery                                   |
| `DISABLE_UPDATES`      | `1`                    | Claude Code changes version only with the image                        |
| `CLAUDE_CONFIG_DIR`    | `/home/vscode/.claude` | Claude Code state lives in the per-project volume                      |

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

- **Replace it entirely:** write your own `~/.zshrc` without the `source` line.
- **Use bash:** set `terminal.integrated.defaultProfile.linux` to `bash` (see above). The image's
  tools don't depend on zsh.

## Prompt (starship)

The shared prompt is `/usr/local/share/toolchain/starship/starship.toml`. A personal
`~/.config/starship.toml` takes precedence automatically, and so does an explicit
`STARSHIP_CONFIG`. To turn the prompt off, skip `post.d/10-prompt`.

## k9s

`~/.config/k9s/` is seeded with a config, aliases, hotkeys and a one-dark skin. It's owned by
`vscode`, so you can edit or replace any of it. Set `ui.skin` in `config.yaml` to change the skin.

## Git

`/etc/gitconfig` sets system-level defaults: the delta pager, `zdiff3` conflict style,
`pull.rebase` and `fetch.prune`. Any value in your `~/.gitconfig` overrides them. VS Code copies
your host `.gitconfig` into the container by default.

## Claude Code

| Aspect            | Default                                                                                                                  | How to change it                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Version           | Pinned in the `Dockerfile` (`CLAUDE_CODE_VERSION`), verified by signature                                                | Build your own image with a different version                                            |
| Policy            | `/etc/claude-code/managed-settings.json`: deny reading credential locations and `.env` files, no bypass-permissions mode | Replace it in a derived image (below). The policy outranks all user and project settings |
| Everything else   | Claude Code defaults                                                                                                     | User settings (`~/.claude/settings.json`) and project settings (`.claude/settings.json`) |
| Not wanted at all | Installed                                                                                                                | Remove the extension (`-anthropic.claude-code`) and ignore the CLI, or build without it  |

The managed policy is a **secure default**, not an enforcement boundary: `vscode` has passwordless
sudo, so it can be changed inside a running container. Organizations that need a policy users
can't change should publish a derived image with their own policy _and_ remove sudo there.

```dockerfile
FROM ghcr.io/<owner>/toolchain/dev:<version>@sha256:<digest>
COPY managed-settings.json /etc/claude-code/managed-settings.json
```

## Tools and versions

- **One-off, at runtime:** `sudo apt-get install …` works, but is lost on rebuild.
- **Per repository:** derive from the image in the repo's own Dockerfile and point
  `devcontainer.json` at it (`"build": {"dockerfile": "Dockerfile"}`):

  ```dockerfile
  FROM ghcr.io/<owner>/toolchain/dev:<version>@sha256:<digest>
  RUN sudo apt-get update && sudo apt-get install -y --no-install-recommends postgresql-client \
   && sudo rm -rf /var/lib/apt/lists/*
  ```

  CI jobs can do the same with `FROM …/ci`, so both stay in step.

- **For everyone using your images:** add the tool to `toolchain/mise.toml` (CI and dev) or
  `toolchain/dev/mise.toml` (dev only) in your fork, run `make lock`, and add a probe to
  `tests/smoke.sh`.

Tools live in a root-owned mise data directory and are linked into `/usr/local/bin`. A
repository's own `mise.toml` isn't activated automatically, so different versions per project
mean a derived image.

## Personal config that follows you

Personal settings, such as your global Claude Code instructions and permission rules, belong in a
dotfiles repository rather than in the image or in each project. The template supports mounting a
local dotfiles clone **read-only** and running its installer on every container start, so it needs
no Git credentials inside the container. See the commented blocks in
[`devcontainer/devcontainer.json`](../devcontainer/devcontainer.json).

## Your own image family

Fork the repository to change the defaults for everyone who uses your images: tools, theme, policy
or base image. The CI and release workflows publish to `ghcr.io/<your-owner>/toolchain/{ci,dev}`
automatically. See the [README](../README.md#running-your-own-copy).
