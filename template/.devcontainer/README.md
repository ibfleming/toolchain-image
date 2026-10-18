# .devcontainer

This repository's dev container, on the toolchain `dev` image. The image owns the tools, the shell,
the editor defaults and the lifecycle libraries; this folder owns only what's specific to this
repository.

## Files

| File                     | Runs                                | Put here                                                                  |
| ------------------------ | ----------------------------------- | ------------------------------------------------------------------------- |
| `devcontainer.json`      | -                                   | The image pin, mounts, forwarded ports, `containerEnv`, the hooks         |
| `scripts/post-create.sh` | Once, when the container is created | Dependencies and project bootstrap (`npm ci`, `uv sync`, migrations, ...) |
| `scripts/post-start.sh`  | Every start                         | Quick checks that the container has what the project needs; marks ready   |
| `scripts/post-attach.sh` | Each time VS Code attaches          | Information only: the container's state and sign-ins                      |

**Not here:** OS packages and tools everyone needs (they belong in the image, or a derived image),
long-running services (Compose, or a task), and anything personal.

## What the image sets for you

The `dev` image carries part of its dev container setup itself, in its `devcontainer.metadata`
label. VS Code, the Dev Containers CLI and Codespaces merge it with `devcontainer.json` when they
create the container, so these apply here without appearing in this folder:

| Setting            | Value                                                                                                                      |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `remoteUser`       | `vscode`                                                                                                                   |
| `postStartCommand` | `sudo /usr/local/sbin/docker-socket-init`: serves the mounted host Docker socket (does nothing without one)                |
| Extensions         | Claude Code, EditorConfig, Python and Ruff, Go, clangd, CMake Tools, OpenTofu, YAML, Even Better TOML                      |
| Editor settings    | The image's Python and clangd paths, format on save (Ruff, Go, OpenTofu), clangd for C/C++, Ninja for CMake, zsh terminals |

How `devcontainer.json` combines with it:

| In `devcontainer.json`                        | Result                                                                     |
| --------------------------------------------- | -------------------------------------------------------------------------- |
| `remoteUser`, `containerEnv` and other values | Yours win                                                                  |
| Editor settings                               | Merged; yours win per setting                                              |
| Extensions                                    | Added to the image's; `"-golang.go"` removes one                           |
| Lifecycle commands (`postStartCommand`, ...)  | Both run: the image's first, then yours. The image's can't be switched off |
| Mounts                                        | Added to the image's                                                       |

To see exactly what an image carries:

```sh
docker image inspect <image> --format '{{index .Config.Labels "devcontainer.metadata"}}' | jq
```

## Hook order

On a new container: `initializeCommand` (on the host) → `onCreateCommand` → `updateContentCommand` →
`post-create.sh` → `post-start.sh` → `post-attach.sh`. On a restart, only `post-start.sh` and
`post-attach.sh` run (after `initializeCommand`). The image's own commands for a hook run before
these, and a failing hook skips the ones after it.

VS Code opens the window before `post-create.sh` has finished, so the first terminal may appear
while dependencies are still installing: `dev-wait` blocks until the container is ready.

**`initializeCommand` isn't used, on purpose:** it runs on the host, in whatever shell that is
(including Windows), without the image's tools, so it breaks the "host needs only Git, Docker and
VS Code" promise. Add one only for what must exist before the container starts, such as a
bind-mount source, and prefer its array form (`["git", "submodule", "update", "--init"]`), which
runs without a shell. `onCreateCommand` and `updateContentCommand` matter only for prebuilt
environments such as Codespaces prebuilds.

## The scripts

They use the image's libraries in `/usr/local/lib/toolchain/` instead of their own logging and
state, so every repository's setup reads and behaves the same:

- `lifecycle::stage <name> <function>` runs a step and records it; `dev-status` shows the result.
- `lifecycle::once <name> <command>` runs something once per container (for example installing
  dependencies); `dev-reset <name>` makes it run again.
- `validate::tool`, `validate::env`, `validate::mount` and `validate::check` log a fix for each
  failure; `validate::report` fails the stage if any check did.
- `log::info`, `log::ok`, `log::warn` and `log::error` for anything else.

Call `lifecycle::stage` and `lifecycle::once` as plain commands, never from `if` or `||`: bash
switches off `set -e` there, so they refuse to run.

## Time zone

Containers run on UTC unless the host's `TZ` variable is set (`containerEnv` passes it on). To
follow your machine's clock settings on Linux, or on WSL with Docker running inside WSL, uncomment
the `/etc/localtime` mount in `devcontainer.json` and set `"TZ": ":/etc/host-localtime"`. Clocks,
`date` and the lifecycle logs then show your local time; `TZ=UTC` still means UTC.

## When something fails

```sh
dev-status                          # which stage failed, and where its log is
dev-reset dependencies              # forget that dependencies were installed
.devcontainer/scripts/post-create.sh && .devcontainer/scripts/post-start.sh
```

Or rebuild: **Dev Containers: Rebuild Container** in VS Code, or `./dev.sh --rebuild`.
