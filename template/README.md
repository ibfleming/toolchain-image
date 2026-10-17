# my-project

A repository set up for the toolchain dev container: every tool, the shell and the editor setup come
from the container, so a laptop needs almost nothing installed.

## Get started

You need [Git](https://git-scm.com), Docker, and [VS Code](https://code.visualstudio.com) with the
[Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
extension:

| Host                 | Docker                                                      | Notes                                                                             |
| -------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Linux                | Docker Engine                                               | Your user in the `docker` group                                                   |
| Windows 11           | Docker Desktop (WSL2 backend), or Docker Engine inside WSL2 | Clone into the WSL file system (`~/...`), not `/mnt/c`, and run `./dev.sh` in WSL |
| macOS (Intel, Apple) | Docker Desktop                                              | Run "Shell Command: Install 'code' command in PATH" in VS Code once               |

Then:

```sh
git clone <this repository>
cd <it>
./dev.sh
```

VS Code opens inside the dev container; the first time, the image is downloaded and the project's
dependencies are installed. `./dev.sh` waits until the container reports it's ready.

| Command              | What it does                                                              |
| -------------------- | ------------------------------------------------------------------------- |
| `./dev.sh`           | Open the repository in VS Code, inside its dev container, and wait for it |
| `./dev.sh --shell`   | A shell in the running container, in your current terminal                |
| `./dev.sh --status`  | The container's state: how setup went, and whether it's ready             |
| `./dev.sh --rebuild` | Throw the container away and start a fresh one (your volumes are kept)    |

Inside the container, `dev-status` shows the same state, and **Terminal → Run Task** has
"Container: status", "Container: reinstall dependencies" and "Container: re-run setup".

## What's where

| Path             | What it holds                                                                            |
| ---------------- | ---------------------------------------------------------------------------------------- |
| `.devcontainer/` | The container: image, mounts, ports, environment, and the setup scripts (see its README) |
| `.vscode/`       | Shared editor settings, recommended extensions, tasks and debug configurations           |
| `dev.sh`         | The one-command entrypoint above                                                         |

Personal preferences (theme, font, keybindings, shell tweaks) stay in your own VS Code settings, not
in the repository.

**A VS Code workspace file** (`*.code-workspace`) is optional and personal: create one if you want
to open this repository together with others, and keep it out of git (`.gitignore` already does).
Commit one only if the repository deliberately defines a multi-root workspace.

## Troubleshooting

| Symptom                                           | Fix                                                                                                  |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `dev.sh: Docker is installed but not reachable`   | Start Docker Desktop, or `sudo systemctl start docker`; `docker info` must work without sudo         |
| `dev.sh: VS Code's 'code' command is not on PATH` | Install VS Code; on macOS, run "Shell Command: Install 'code' command in PATH"                       |
| VS Code opens, but not in the container           | Install the Dev Containers extension, then run `./dev.sh` again                                      |
| `the container is not ready`                      | `./dev.sh --status` shows which step failed and where its log is; fix it, then reopen or `--rebuild` |
| Very slow on Windows                              | The repository is under `/mnt/c`: clone it inside WSL instead                                        |
| `git push` asks for credentials                   | Start an SSH agent on the host and add your key; VS Code forwards it into the container              |
