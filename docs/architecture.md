# Architecture: who owns what

A repository that uses the toolchain has four layers of configuration. Each one has a single owner,
and each setting belongs in the layer shared by exactly the people who need it.

| Layer         | Owner                   | Lives in                             | Holds                                                                                                   |
| ------------- | ----------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| Image         | This repository         | `ghcr.io/<owner>/toolchain/{ci,dev}` | OS packages, language runtimes, CLI and Kubernetes tooling, the shell, logging, editor defaults         |
| Dev container | The consumer repository | `.devcontainer/`                     | Image pin, mounts, ports, environment, lifecycle scripts, project dependencies and bootstrap            |
| Editor        | The consumer repository | `.vscode/`                           | `settings.json`, `extensions.json` (recommendations), `tasks.json`, `launch.json`                       |
| Personal      | Each developer          | Outside version control              | Themes, keybindings, fonts, shell preferences, personal tools, an optional `*.code-workspace`, sign-ins |

[`template/`](../template/) has all of this ready to copy, and each release attaches it with the
image reference filled in (`template.tar.gz`).

```text
Consumer repository
├── .devcontainer/       dev container: image pin, mounts, lifecycle scripts
├── .vscode/             editor: settings, recommended extensions, tasks, launch
├── src/ ...             the application
└── *.code-workspace     optional and personal (gitignored)
```

## What belongs where

| Belongs in       | Examples                                                                                                    | Not here                                                       |
| ---------------- | ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| The image        | `git`, `gh`, Docker CLI, `kubectl`, `helm`, `jq`, `lazygit`, `lazydocker`, language runtimes, the logger    | Anything one project needs, credentials, personal preferences  |
| `.devcontainer/` | The image reference, mounts, forwarded ports, `containerEnv`, `postCreateCommand`, project-specific tooling | OS packages for everyone (image), editor settings (`.vscode/`) |
| `.vscode/`       | Format on save, formatters, recommended extensions, shared tasks and debug configurations                   | Machine paths, themes, fonts, secrets                          |
| Outside git      | Personal themes and keybindings, local workspace state, `*.code-workspace`, shell preferences               | Anything a teammate needs to build, run or debug the project   |

Two rules decide the borderline cases:

- **Needed to build, run or debug the project?** Then it's versioned in the repository, never only
  on one developer's machine.
- **The same in every repository?** Then it belongs in the image, not copied into each one.

## The consumer contract

Repositories own their application and everything specific to it. The platform owns the
development environment that every repository shares.

**A consumer repository owns:**

- `.devcontainer/devcontainer.json`: the image pin (by digest), ports, mounts, environment,
  features.
- Its lifecycle scripts: dependency installation (`npm ci`, `uv sync`, ...), migrations, project
  checks.
- `.vscode/`: settings, extension recommendations, tasks and launch configurations.
- Its build, test, lint and run commands, and its own documentation.

**The platform owns, and consumers use rather than copy:**

- The tools and their versions (a different version means a derived image; see
  [Customizing](customizing.md#tools-and-versions)).
- The logger (`/usr/local/lib/toolchain/log.sh`): consistent, leveled output on STDERR.
- The shell, prompt and git defaults.
- The authentication patterns: SSH agent forwarding, sign-ins kept in volumes, no secrets in images
  or repositories.

**Escalation:** when several repositories need the same customization, it's a candidate for the
platform. Open an issue here rather than copying it into a third repository.

## Host requirements

A host needs only:

- Git
- Docker (Docker Desktop on Windows and macOS; Docker Engine on Linux, including inside WSL2)
- VS Code with the Dev Containers extension

Everything else comes from the image. Supported hosts:

| Host                           | Status                                                        |
| ------------------------------ | ------------------------------------------------------------- |
| Linux + Docker Engine          | Supported; the images are tested in CI                        |
| Windows 11 + WSL2 (+ Docker)   | Supported; clone into the WSL file system, not `/mnt/c`       |
| macOS (Intel) + Docker Desktop | Expected to work (amd64 image); not yet validated             |
| macOS (Apple Silicon)          | Runs the amd64 image under emulation until arm64 images exist |
