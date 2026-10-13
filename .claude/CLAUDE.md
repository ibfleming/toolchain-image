# toolchain-image

One Dockerfile builds two images from one pinned tool manifest:

- `ci`: base + pinned toolchain. Root by default, no `ENTRYPOINT`/`WORKDIR`, glibc, `bash`/`grep`/`sudo`/`which`/`groupadd` present (GitHub Actions and Azure DevOps container-job requirements).
- `dev`: `FROM ci` + dev conveniences: zsh config, starship, k9s config, dev-only tools, a signature-verified Claude Code with a managed policy, and the `devcontainer.metadata` label. `remoteUser: vscode` (UID 1000, passwordless sudo).

Both are built by one `docker buildx bake` run, released to `ghcr.io/<owner>/toolchain/{ci,dev}`, and consumed by digest.

Read first: [README.md](../README.md) (usage, development, releases), [docs/customizing.md](../docs/customizing.md) (override layers), [docs/design/](../docs/design/README.md) (research records and the decisions that differ from them).

## Invariants (don't break without the maintainer's agreement)

- `dev` only _adds_ to `ci`; it never substitutes a tool. Parity test: `ci ⊆ dev` with identical versions.
- Tool versions live only in `toolchain/mise.toml` (+ `toolchain/dev/mise.toml` for dev-only tools) and their locks. The exceptions are pinned in the Dockerfile: the base image (digest), mise and Claude Code (version; verified by signature against vendored keys in `config/keys/`) and the zsh plugins (git commit).
- The base image is pinned by multi-arch index digest. Every download is checksum- or signature-verified. No `curl | sh`.
- Secrets only via `RUN --mount=type=secret`, never `ARG`/`ENV` (`mode=max` provenance publishes build args).
- Nothing secret in the image label (`remoteEnv`/`containerEnv`): anyone who can pull the image can read it.
- Project-neutral: no owner names, personal hosts, networks or machine paths in code or docs. The owner comes from CI (`github.repository_owner`, `SOURCE_URL`).
- Machine-written Claude Code state (`.claude.json`, credentials, `projects/`, history) never goes in git or into the image.

## Layout and commands

- `Dockerfile`: stages `base → mise → ci → dev`. `docker-bake.hcl`: `ci`/`dev` (attested, `REGISTRY/staging/*`) and the `local` group (`toolchain/{ci,dev}:local`, attestations off so the classic Docker image store can load them). The devcontainer label is defined in bake.
- `toolchain/`: tool manifests and locks. The root `mise.toml` holds only repo tooling (linters, test/release tools, commitlint, git-cliff), so a contributor's shell never activates the image toolchain.
- `config/zsh` → `/usr/local/share/toolchain/zsh` (shared, root-owned). `config/starship` → `/usr/local/share/toolchain/starship`. `config/git/gitconfig` → `/etc/gitconfig`. `config/home/` is seeded into `/home/vscode` (vscode-owned). `config/claude/` holds the managed policy; `config/keys/` the vendored release-signing keys (Claude Code, mise; fingerprints pinned in the Dockerfile).
- `/etc/toolchain/{release,versions,previous}` (dev): image version/revision/build date/source/previous release, the `print-versions` output, and the previous release's tools. The last Dockerfile layer writes them from bake's `VERSION`/`REVISION`/`SOURCE_URL`/`PREVIOUS_*`. The release workflow gets `PREVIOUS_*` from `scripts/previous_tools.sh` (the previous GitHub Release's toolchain table); local builds leave them empty. The zsh `welcome` function (`functions/welcome.zsh`, shown by `post.d/95-welcome.zsh`) only reads files and variables. Keep it free of tool invocations and subshells (`$(<file)` is fine) so startup stays at a few ms. After changing what it shows, run `make screenshots` (sample fixtures, so nothing personal appears) to refresh `docs/assets/welcome*.png` in the README. shfmt formats zsh here as bash: no arithmetic subscripts like `$a[i+1]` and no `for k v in`.
- Docker (dev): the CLI from Docker's signed apt repo (key vendored, fingerprint pinned; Renovate `deb` datasource), buildx/compose from the dev mise manifest, linked into `/usr/local/lib/docker/cli-plugins`. The template mounts the host socket at `/var/run/docker-host.sock`; `scripts/docker_socket_init.sh` (the label's `postStartCommand`, via sudo) serves it as `/var/run/docker.sock` (group `docker`) through socat. Never chmod/chown the mounted socket: it's the host's file. `make test-docker` covers it.
- `devcontainer/devcontainer.json`: template for consuming repositories.
- `scripts/setup_host.sh`: the dev shell on an Ubuntu/Debian host, from a clone (symlinks the config, installs the pinned tools through mise with the two locks merged into `~/.config/mise/mise.lock` and `MISE_LOCKED=1`, plugins at the Dockerfile's commits). Tested on fresh `ubuntu:24.04` and `debian:trixie` containers; keep it idempotent. Global mise config uses that one lock file, not per-file locks next to `conf.d/*.toml`.
- `make build test` is the inner loop; see `make help` and the README for every target. To add a tool: edit a manifest, run `make lock`, add a probe to `tests/smoke.sh` (the test fails without one), then `make build test`.
- `make shell-live` mounts `config/{zsh,starship,k9s}` over the image so edits apply without a rebuild; `make shell-kube-demo` adds a fake multi-context kubeconfig.
- Release flow (`.github/workflows/release.yml`): bake push to staging → `make test` on the pushed digests → `scripts/scan.sh` gate → promote by digest copy (asserts the digest is unchanged) → keyless cosign sign and verify → GitHub Release (notes from `scripts/release_notes.sh` + git-cliff, `CHANGELOG.md` attached). It runs on a `vX.Y.Z` tag, weekly, or manually from `main`; the last two take the next version from the Conventional Commits since the last tag (`scripts/release_version.sh`: breaking → major, minor below 1.0, `feat` → minor, else patch). Release notes use the explicit `prev..tag` range: a no-change weekly tag shares its commit with the previous one, which breaks `git-cliff --latest`.
- Renovate (`renovate.json`) updates the mise manifests **and their locks**, the base digest, Action SHAs and annotated Dockerfile ARGs, with no manual follow-up. Single-version ARGs (`# renovate:`) are mise and Claude Code, verified at build time by signature. Tag + commit pairs (`# renovate: … pin=commit`) are the zsh plugins, fetched by commit. Python minor bumps wait for dashboard approval.

## Conventions

- **Commits and PR titles:** [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/), enforced by commitlint (`config-conventional`). PRs are squash-merged: the **PR title becomes the commit title** (so it must conform) and the branch's commit messages become the body (put `BREAKING CHANGE:` footers in commits, not only the PR description). Body/footer line length is not limited (URLs can't wrap). Scopes in use: `toolchain`, `image`, `zsh`, `starship`, `k9s`, `git`, `claude`, `devcontainer`, `tests`, `actions`, `deps`. Breaking changes use `!` plus a `BREAKING CHANGE:` footer; removing a tool is breaking. `fix` → patch, `feat` → minor, breaking → major.
- **Bash scripts:** [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html), plus a `main` function in every script (the last line is `main "$@"`). `#!/bin/bash` (bash 4.2+; no macOS `/bin/bash` 3.2 support), 80 columns, `"${var}"` braces, `local` in functions, `readonly` constants at the top, function headers (Description/Globals/Arguments/Outputs/Returns). Source files are `lower_snake.sh`; installed command names keep their hyphens (`print-versions`, `link-tools`, ...), since they're interfaces. Log through `scripts/lib/log.sh` (installed at `/usr/local/lib/toolchain/`): every level goes to STDERR, because several scripts' STDOUT is data (`$GITHUB_OUTPUT`, `$GITHUB_ENV`, release notes, `print-versions`). Libraries are `.sh`, not executable, change no shell options and are `::`-namespaced. Avoid standalone `(( ))` (a zero result exits under `set -e`).
- **Formatting:** `.editorconfig` is the policy: spaces only (the Makefile uses `.RECIPEPREFIX`), 120 columns, LF. `make lint` is the gate (editorconfig-checker, shfmt, shellcheck, taplo, prettier, markdownlint, hadolint); `make fmt` fixes most of it. Markdown: Prettier formats it (tables aligned; code samples untouched via `embeddedLanguageFormatting: off`), and markdownlint (`.markdownlint-cli2.jsonc`, Prettier-compatible preset) checks headings, lists, fenced-code languages and table shape and alignment. A URL that can't wrap gets `# editorconfig-checker-disable-next-line` on the line above it.
- **Scratch space:** `.claude/.scratch/` (gitignored) for agent artifacts worth seeing in the IDE or keeping across sessions; nothing there is load-bearing. Throwaway single-session files go in the session scratchpad.
- **Verify, don't assume:** check claims from the design records against real artifacts before relying on them (they were point-in-time research).

## Gotchas (each one has bitten before)

- **Makefile:** after a rule, _any_ indented line is recipe (`.RECIPEPREFIX` is a space), so never indent make directives there.
- **`.editorconfig`:** a section containing `/` anywhere is anchored to the repo root as a whole. Mixed lists must use `**.ext`, not `*.ext`.
- **zsh config:** modules must be sourced from the top-level loop in `config/zsh/zshrc`, never inside a function, or a `typeset` becomes function-local (this once emptied `$path`). fzf's `--zsh` script fails without a TTY, so it's gated on `-t 0`.
- **Docker build:**
  - `COPY --chmod=0644` also applies that mode to directories it _creates_ (no search bit), so pre-create them with `install -d -m 0755`.
  - `install -d -o` only chowns the dirs it's given, not the parents it creates.
  - Test file readability **as vscode**, not root.
- **mise:**
  - The image uses no shims: `scripts/link_tools.sh` symlinks resolved binaries into `/usr/local/bin` (`node.npm_shim = false` is required).
  - mise also reads `/etc/mise/` as system config, so `ci` tools appear when dev's config is active; `link-tools` and `print-versions` tolerate this.
- **container-structure-test:** expands `$VARS` in `args`, so keep `$` out of `tests/*.structure.yaml`. Its regexes need `\n?` for trailing newlines.
- **Test fixtures:** never use `.invalid` hostnames. Inherited DNS search domains can make them resolve to real hosts; point fake servers at `https://127.0.0.1:1`.
- **CI:**
  - GitHub runners use the classic image store, which can't load attested images (hence `_local` disables attestations).
  - The images are large: Trivy runs once per image, and workflows free disk space first.
- **Renovate's local dry run** (`renovate --platform=local --dry-run=extract`) only sees git-tracked files.
- **Third-party zsh config:** the zsh setup was _inspired by_ smeltery/zsh, which is PolyForm Shield licensed. Never copy code from it.
- **Known gap:** the VS Code Claude panel runs the extension's bundled CLI version, not the pinned binary.
