# Authentication

How credentials and identities reach a dev container: one recommended default per area, the
alternatives, and what not to do. The aim is that nobody copies a secret into a container by hand,
and that a rebuild never means signing in to everything again.

## Principles

1. **Never bake credentials in.** No keys, tokens, passwords or cloud credentials in a Dockerfile,
   an image, its `devcontainer.metadata` label, or a repository (template included). Anyone who can
   pull an image can read its label.
2. **Reuse the host's identity when it can be forwarded,** rather than copied: SSH signing happens
   on the host, git and Docker credentials are answered by the host. Nothing secret lands in the
   container.
3. **Otherwise, sign in once inside the container** and keep the result in a named volume, so it
   survives rebuilds. This works the same on every host.
4. **Mount host credential files only when you must.** Their paths and formats differ between
   Linux, macOS and Windows (some live in an OS keyring a Linux container can't read), and a mount
   gives the container write access to the host's copy.
5. **Prefer standard sign-in flows** (SSH keys, OAuth device code, OIDC, SSO) over long-lived static
   tokens.

## What VS Code forwards for you

When VS Code opens the container (checked in a dev container opened from VS Code):

| What                        | How                                                                                       | In the container                                            |
| --------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Git identity                | Copies your host `~/.gitconfig` when the container is created                             | `~/.gitconfig`                                              |
| Git HTTPS credentials       | A credential helper that asks the host's credential manager                               | `credential.helper` set to VS Code's helper                 |
| SSH agent                   | Forwards the host's SSH agent; keys never leave the host                                  | `SSH_AUTH_SOCK` in VS Code terminals                        |
| Docker registry credentials | A Docker credential helper that asks the host's Docker credentials (`docker login` there) | `~/.docker/config.json`: `"credsStore": "dev-containers-…"` |

These go through VS Code's connection to the container. A shell from `./dev.sh --shell` gets the
SSH agent only while a VS Code window is connected, and the git and Docker helpers not at all.

## Recommended defaults

| Capability                   | Default                                                                          | Alternatives                                                | Notes                                                                                     |
| ---------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| SSH                          | Agent forwarding (automatic)                                                     | -                                                           | Never mount `~/.ssh`. Passphrase-protected and hardware keys work: signing is on the host |
| Git identity                 | The copied host `~/.gitconfig`                                                   | `git config --global` in the container (lost on rebuild)    | Keep `user.name` and `user.email` in the host's `~/.gitconfig`                            |
| Git over HTTPS               | VS Code's forwarded credential helper                                            | `gh auth setup-git` after signing in to `gh`                | Prefer SSH remotes; no `.git-credentials` files                                           |
| GitHub CLI                   | `gh auth login` once, kept in the `toolchain-gh-config` volume (in the template) | `GH_TOKEN` in the environment for one session               | Containers have no keyring, so the token is a file in that volume                         |
| Docker registries            | `docker login` on the host; VS Code forwards it                                  | `docker login` in the container                             | A login inside lasts until a rebuild, unless `~/.docker` is a volume                      |
| Kubernetes                   | Mount the host's `~/.kube` (see below)                                           | A read-only mount plus `KUBECONFIG`, or sign in inside      | Exec plugins (`kubelogin`, `aws`, `gke-gcloud-auth-plugin`) must be in the container      |
| Cloud CLIs (az, aws, gcloud) | Sign in inside with a device-code flow, kept in a named volume                   | Mount the host's config folder (Linux and macOS hosts only) | Not in the image: add them with mise or a derived image                                   |
| Package registries           | Config in the repository that reads a token from the environment                 | A personal config file outside the repository               | The token comes from the host (see below), never from a committed file                    |
| AI tools                     | Sign in through the VS Code extension; kept in a volume                          | API keys from the host environment                          | Copilot uses VS Code's GitHub account; Claude Code keeps its sign-in in `~/.claude`       |

### SSH

The host needs a running SSH agent with your key loaded. VS Code forwards the agent of the machine
it runs on: on Linux your session's agent (for example systemd's `ssh-agent.socket`), on macOS the
built-in agent (`ssh-add --apple-use-keychain`), and on Windows the OpenSSH Authentication Agent
service. Check with `ssh-add -l` in a container terminal; `ssh -T git@github.com` should greet you.

### GitHub CLI

Run `gh auth login` once in any container that mounts the `toolchain-gh-config` volume (the
template does), choosing SSH for git operations. The sign-in is then shared by all of them. Ask for
the scopes you need, not more. Don't pass the host's token in: it usually has broader scopes than a
container needs, and it would sit in every process's environment.

### Kubernetes

Mount the host's kubeconfig in the repositories that need a cluster:

```jsonc
"mounts": ["source=${localEnv:HOME}/.kube,target=/home/vscode/.kube,type=bind"]
```

Read-write, because `kubectx`, `kubens` and token caches write to it. To protect the host's file,
mount it read-only at another path and point `KUBECONFIG` at it; context switches then need
`--context` instead of `kubectx`. Clusters that sign in through an exec plugin need that plugin
in the container, and OIDC logins work through a device code or VS Code's port forwarding. The
prompt turns the Kubernetes segment red for production contexts.

### Cloud CLIs

Sign in inside the container and keep the result in a named volume:

| CLI    | Sign in                                   | Volume target                 |
| ------ | ----------------------------------------- | ----------------------------- |
| Azure  | `az login --use-device-code`              | `/home/vscode/.azure`         |
| AWS    | `aws configure sso`, then `aws sso login` | `/home/vscode/.aws`           |
| Google | `gcloud auth login --no-launch-browser`   | `/home/vscode/.config/gcloud` |

Mounting the host's folder instead works on Linux and macOS hosts. On Windows, the Azure CLI
encrypts its token cache with Windows APIs, so a Linux container can't use it.

### Package registries

Commit the registry configuration and leave the token out of it:

| Tool      | Committed config                                            | Token from                                        |
| --------- | ----------------------------------------------------------- | ------------------------------------------------- |
| npm, pnpm | `.npmrc`: `//registry.example.com/:_authToken=${NPM_TOKEN}` | `NPM_TOKEN`                                       |
| pip, uv   | The index URL in `pyproject.toml` or `uv.toml`              | `UV_INDEX_<NAME>_USERNAME` / `_PASSWORD`          |
| Poetry    | The source in `pyproject.toml`                              | `POETRY_HTTP_BASIC_<NAME>_USERNAME` / `_PASSWORD` |
| Maven     | `settings.xml` with `${env.REPO_TOKEN}`                     | `REPO_TOKEN`                                      |
| Gradle    | Repository credentials read from project properties         | `ORG_GRADLE_PROJECT_<name>`                       |
| NuGet     | `nuget.config` with `%NUGET_TOKEN%`                         | `NUGET_TOKEN`                                     |

Get the token into the container from the host's environment, in `devcontainer.json`:

```jsonc
"remoteEnv": { "NPM_TOKEN": "${localEnv:NPM_TOKEN}" }
```

Set the variable on the machine VS Code runs on (for VS Code on Windows, that's Windows, even for a
folder in WSL). `remoteEnv` is read when VS Code connects, so the value isn't in the image or the
repository. Don't put secrets in `containerEnv` with literal values: that file is committed.

### AI tools

GitHub Copilot signs in with VS Code's GitHub account, on your machine: nothing to do in the
container. The Claude Code extension signs in once with `/login`; the sign-in lives in
`~/.claude`, a per-container volume in the template, so it survives rebuilds. Tools that need an
API key (OpenAI, Azure OpenAI, Anthropic and others) get it like a package registry token:
`remoteEnv` from the host's environment.

## Mounting strategy

| Mount                        | When                                      | Security                                          | Platform notes     |
| ---------------------------- | ----------------------------------------- | ------------------------------------------------- | ------------------ |
| Named volume                 | Sign-ins made inside (gh, cloud CLIs, AI) | Lives in Docker, not in your home folder          | Same on every host |
| Host Docker socket           | Docker from the container (the template)  | Root on the host's engine                         | Same on every host |
| Host folder, read-write      | Kubernetes config                         | The container can change the host's copy          | See below          |
| Host folder, read-only       | Config to use but protect                 | Read-only, but readable by everything inside      | See below          |
| `~/.ssh`, cloud token caches | Never                                     | Private keys and tokens copied into the container | -                  |

A bind mount's source is a path on the machine that runs the Docker engine, while `${localEnv:…}`
is read on the machine that runs VS Code:

- **Linux, macOS:** the same machine; `${localEnv:HOME}/.kube` works.
- **Windows with Docker inside WSL, VS Code on Windows:** `${localEnv:HOME}` is read from Windows,
  where it's usually unset, but the source must be a WSL path. Open the folder from a WSL window
  (`code .` in WSL, then Reopen in Container) so that `localEnv` is WSL's, or write the WSL path.
- **Windows with Docker Desktop:** sources can be Windows paths, such as
  `${localEnv:USERPROFILE}/.kube`.

A missing source makes container creation fail. For optional mounts, see
[`initializeCommand`](lifecycle.md#initializecommand-on-the-host).

## Never

- Private keys, tokens, passwords or cloud credentials in a Dockerfile, image, image label,
  repository or template.
- `ARG` or `ENV` for build secrets: use `RUN --mount=type=secret`. Provenance records build args.
- Literal secrets in `devcontainer.json` (`containerEnv`, `remoteEnv` or `runArgs`): it's committed.
- Mounting `~/.ssh` into a container: forward the agent.
- `.git-credentials` or plain-text tokens in the workspace: it's a bind mount of the repository.
