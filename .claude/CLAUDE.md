# toolchain-image

One Dockerfile produces two images from one pinned manifest:

- `ci`: base + pinned toolchain. Root by default, no `ENTRYPOINT`/`WORKDIR`, glibc, `bash`/`grep`/`sudo`/`which`/`groupadd` present.
- `dev`: `FROM ci` + dev conveniences, pinned and GPG-verified Claude Code at `/usr/local/bin/claude`, `/etc/claude-code/managed-settings.json`, firewall script, and the `devcontainer.metadata` label. `remoteUser: vscode` (UID 1000).

Both are built by one `docker buildx bake` run and published to GHCR by digest. Consumers pin `@sha256`, never a tag.

Design sources, which are authoritative unless the user overrides them:

- `.claude/design-primary.md`: image family, build, supply chain, CI consumption.
- `.claude/design-secondary.md`: VS Code profile, Claude Code in the image, config/state split, firewall.

## Invariants (do not break without asking)

- `dev` only _adds_ to `ci`; it never substitutes a tool. Parity test: `ci ⊆ dev` with identical versions.
- Every tool version lives in one manifest (`mise.toml` + `mise.lock`). No versions anywhere else, except the base digest, mise itself, and Claude Code.
- Base image is pinned by multi-arch index digest. Every download is checksum- or signature-verified. No `curl | sh`.
- Secrets only via `RUN --mount=type=secret`, never `ARG`/`ENV` (`mode=max` provenance publishes build args).
- No secrets in `remoteEnv`/`containerEnv` inside the image label (the label is readable by anyone who pulls).
- Machine-written Claude state (`.claude.json`, credentials, `projects/`, history) never goes in git and is never bind-mounted between WSL and containers.

## Local environment facts

- Host: WSL2 Ubuntu 26.04, user `ian` UID/GID 1000, Docker CE inside WSL (no Docker Desktop). VS Code uses `dev.containers.executeInWSL: true`.
- The default buildx builder uses the `docker` driver, which drops attestations. Use a `docker-container` builder for any build that needs SBOM/provenance.
- GitHub user: `ibfleming`. Registry target: `ghcr.io/ibfleming/...`.

## Decisions (2026-10-10)

- Platforms: `linux/amd64` only for now (`PLATFORMS` bake variable).
- Container Claude auth: `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` via `--env-file` from a 0600 file in WSL. Not `/login` per volume.
- Workspace path: the default `/workspaces/<repo>`, not WSL path alignment. The long-term plan is an umbrella `~/repos` devcontainer built on this image.
- Image manifest lives in `toolchain/mise.toml` + `toolchain/mise.lock`, not at the repo root. The root `mise.toml` holds only repo tooling (hadolint, container-structure-test), so the user's shell mise doesn't activate the image toolchain.
- No mise shims at runtime: `scripts/link-tools.sh` symlinks resolved binaries into `/usr/local/bin`. `node.npm_shim = false` is required for that.
- Node is on the active LTS line (24.x). Python stays one minor behind the newest release (3.14.x).
- Image size is not a constraint for now: the user wants the images well loaded.
- C/C++: compilers come from apt in `ci` (build-essential, clang, lld, clang-format/tidy, ccache). cmake and ninja are pinned in mise. clangd, lldb and valgrind are dev-only.
- Dev-only tools live in `toolchain/dev/mise.toml` (+ lock), are installed only in `dev`, and are listed by `print-versions`. Parity stays `ci ⊆ dev`.
- The dev shell is zsh with a modular config of our own, inspired by smeltery/zsh. smeltery is under PolyForm Shield, so never copy code from it. Plugins are pinned tarballs with checksums (ARGs in the Dockerfile). No plugin manager and no runtime clones. The theme is one-dark across vivid/LS_COLORS, fzf, bat, delta and k9s.

## Layout and commands

- `Dockerfile`: stages `base → mise → ci → dev`. `docker-bake.hcl`: `ci`/`dev` (attested, staging tags), `local` group (`toolchain/{ci,dev}:local`). The devcontainer label is defined in bake.
- `make build` (creates the `toolchain` docker-container builder), `make test` (structure + smoke + parity + k9s schemas + starship k8s segment), `make lint`, `make lock` (regenerates the lock with the image's pinned mise).
- To add a tool: edit `toolchain/mise.toml`, run `make lock`, add a probe to `tests/smoke.sh` (the test fails without one), then `make build test`.
- `config/zsh` → `/usr/local/share/toolchain/zsh` (root-owned, shared). `config/starship` → `/usr/local/share/toolchain/starship`. `config/git/gitconfig` → `/etc/gitconfig`. `config/home/` is seeded into `/home/vscode` (owned by vscode).
- `make shell` runs the built dev image. `make shell-live` bind-mounts `config/{zsh,starship,k9s}` over the baked copies, so host edits apply without a rebuild (starship and k9s re-read their config on the next prompt or refresh).
- `make test-k9s` validates the k9s YAML against k9s's JSON schemas at the pinned version. k9s itself silently ignores unknown keys. `make spell` runs cspell (`cspell.config.yaml`) in the dev image.
- Gotcha: zsh modules must be sourced from the top-level loop in `config/zsh/zshrc`, never from inside a function. A `typeset` in a module would otherwise become function-local; this once emptied `$path` and `$fpath`.
- Gotcha: fzf's `--zsh` script fails without a TTY ("can't change option: zle"), so it's gated on `-t 0`.
- Gotcha: `install -d -o` only chowns the dirs it's given, not created parents. The dev structure test asserts that everything under /home/vscode is owned by vscode.
- Gotcha: mise also reads `/etc/mise/` as system config, so ci tools show up when dev's global config is active. `link-tools` and `print-versions` tolerate this.
- `make shell-kube-demo` / `make test-starship` use `tests/fixtures/kubeconfig.yaml` (fake contexts, all servers `https://127.0.0.1:1`). Never use `.invalid` hostnames in fixtures: the user's LAN DNS resolves them to a real host. Offline namespace switching uses `kubectl config set-context --current --namespace=…`, because kubens queries the API.
- Gotcha: container-structure-test expands `$VARS` in `args`, so keep `$` out of `tests/*.structure.yaml`. Its regexes need `\n?` for trailing newlines.

## Formatting policy (enforced in CI; no local hooks)

- `.editorconfig` is the single source of truth: **spaces only, never tabs** (every file, the Makefile included), 2-space indent (Python 4), LF, UTF-8, final newline, no trailing whitespace, **max 120 columns**. Markdown is exempt from the column limit and the even-indent check. Lock files and the vendored k9s skin are exempt from the column limit.
- `make lint` is the gate. CI runs it in Step 3; there is no git hook, by the user's choice. It runs: `ec` (editorconfig-checker) → `shfmt --diff` (bash + zsh) → `shellcheck` (bash scripts only; it has no zsh support) → `taplo fmt --check` → `prettier --check` (YAML/JSON/Markdown) → hadolint. `make fmt` applies shfmt, taplo and prettier.
- shfmt and prettier read indent and width from `.editorconfig`. shfmt style: case arms indented, binary operators (`|`, `&&`) start the continuation line. Prettier keeps Markdown prose unwrapped (`proseWrap: preserve`). The design docs, lock files and the vendored skin are in `.prettierignore`.
- All lint/format tools (and node for prettier) are pinned in the root `mise.toml`. They activate only inside this repo.
- The Makefile uses `.RECIPEPREFIX` set to a single space, so recipes are indented with 2 spaces. A tab-indented recipe now fails to parse. **After a rule, any indented line is recipe**, so never indent make directives there.
- Dockerfile `RUN` continuations start with two spaces and then `&&`. `.vscode/` is not versioned (user preference): the EditorConfig extension (shipped in the dev image label) overrides VS Code's tab-forcing Makefile default, and `make lint` is the backstop.
- A URL that can't be wrapped gets `# editorconfig-checker-disable-next-line` on the line above it (as in the k9s yaml-language-server headers). Never append the marker to the URL line itself.
- Gotcha: an `.editorconfig` section containing `/` anywhere is anchored to the repo root as a whole. Mixed lists must use `**.ext`, not `*.ext`; `*.ext` there silently matches only root-level files.
- Gotcha: the user's WSL mise (2026.5.14) can't install editorconfig-checker 4.x (registry too old), so it's pinned at 3.x (binary `ec`) until mise is updated.

## Git commits: Conventional Commits 1.0.0 (required)

Every commit follows https://www.conventionalcommits.org/en/v1.0.0/:

```
<type>[optional scope][!]: <description>

[optional body]

[optional footer(s)]
```

- **Types:** `feat` (new capability: tool, segment, config option) and `fix` (bug fix) are the spec's own. Also use `build` (Dockerfile, bake, manifests, locks), `ci` (pipelines), `test`, `docs`, `refactor`, `perf`, `style`, `chore` and `revert`.
- **Scopes** (optional, lowercase, one area): `toolchain` (mise manifests and locks), `image` (Dockerfile and bake), `zsh`, `starship`, `k9s`, `git`, `tests`, `claude` (`.claude/`), `deps`.
- **Description:** imperative, lowercase, no trailing period, about 72 chars max. For example, `feat(starship): add kubernetes segment with prod highlighting`.
- **Body:** explain _why_, wrapped at about 72 columns, separated from the subject by a blank line.
- **Breaking changes:** add `!` after the type or scope, _and_ a `BREAKING CHANGE: <what and how to migrate>` footer. Removing a tool or making a major version bump of one is breaking, because it breaks the image contract.
- **Footers** use `Token: value` (e.g. `Refs: #12`). Required trailers, such as the Co-Authored-By attribution, go in the footer block.
- **One logical change per commit.** Split unrelated changes rather than using a vague type.
- Commit types map onto the image's semver (design-primary §5): `fix` → patch, `feat` → minor, breaking → major. Release tooling in Step 3 can derive versions and the CHANGELOG from history.

## Working conventions

- `.claude/.scratch/` is gitignored, disposable working space for agent artifacts that should be visible in the IDE or survive across sessions (drafts, probe output, transcript handoffs). Nothing there is load-bearing. Anything worth keeping gets promoted into the repo proper.
- Throwaway, single-session files go in the session scratchpad (`/tmp/claude-*/...`), not `.scratch`.
- Mark unverified claims from the design docs as such when implementing them, and verify against real artifacts (e.g. a real Claude release `manifest.json`) before relying on them.
