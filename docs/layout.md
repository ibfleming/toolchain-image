# Repository layout

What goes where in this repository, so the root shows what builds the image and everything else has
one obvious home.

```text
.
├── Dockerfile, docker-bake.hcl   the image build (ci and dev)
├── Makefile                      every task: build, test, lint, release helpers
├── README.md, LICENSE
├── config/                       files the image ships as they are (zsh, starship, git, home, policy, keys)
├── image/                        scripts the image installs (commands and shell libraries)
├── toolchain/                    the image's pinned tools (mise manifests and locks)
├── template/                     what a consumer repository copies
├── scripts/                      repository tooling: release, scan, screenshots, CI helpers
├── tests/                        image and template tests
├── docs/                         documentation and design records
├── .config/                      repository tool configuration (mise, cspell, commitlint, git-cliff, hadolint, jactionlint)
├── .github/                      workflows, Renovate, community files (security policy, contributing, templates)
└── .claude/                      instructions for Claude Code
```

## Deciding where something goes

| If it is…                                                      | It goes in                                  |
| -------------------------------------------------------------- | ------------------------------------------- |
| A file the image contains, unchanged                           | `config/`                                   |
| A script or library the image installs                         | `image/` (`image/lib/` for libraries)       |
| A tool version for the image                                   | `toolchain/` (a manifest, then `make lock`) |
| Something consumer repositories copy                           | `template/`                                 |
| A script that builds, releases, scans or checks the repository | `scripts/`                                  |
| A test                                                         | `tests/`                                    |
| Configuration for a repository tool                            | `.config/`, if the tool finds it there      |
| A workflow, Renovate setting or community file                 | `.github/`                                  |

The Dockerfile copies only from `config/`, `image/` and `toolchain/` (`.dockerignore` keeps
everything else out of the build). A file the image needs must live in one of those.

## Why some dotfiles stay at the root

Moving a configuration file only helps if every tool that reads it still finds it. These stay at
the root because editors look for them there, and a moved copy would make format-on-save disagree
with `make lint`:

| File                                  | Read by                                                  |
| ------------------------------------- | -------------------------------------------------------- |
| `.editorconfig`                       | every editor, editorconfig-checker, shfmt                |
| `.prettierrc.yaml`, `.prettierignore` | Prettier and its VS Code extension                       |
| `.markdownlint-cli2.jsonc`            | markdownlint-cli2 and the VS Code markdownlint extension |
| `.taplo.toml`                         | Taplo and the VS Code Even Better TOML extension         |
| `.gitignore`, `.dockerignore`         | git, and Docker (next to the build context)              |

In `.config/`, mise, cspell and git-cliff find their files on their own; commitlint, hadolint and
jactionlint are pointed there by the Makefile (`--config`, `--config-file`).

Hosts that install the shell read `config/zsh`, `config/starship`, `config/git` and
`toolchain/shell` from a pinned commit, so those paths are an interface: moving them breaks hosts at
their next update.
