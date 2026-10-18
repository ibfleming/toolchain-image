# Recipes are indented with two SPACES, not tabs (repo policy, see .editorconfig).
# GNU make >= 3.82 allows this via .RECIPEPREFIX, set here to a single space.
# Rule of thumb that comes with it: after a rule, ANY indented line is part of its recipe,
# so never indent make directives (ifeq, assignments, include) inside or right after a rule.
# Backslash-continued lines are joined first and are unaffected.
empty :=
.RECIPEPREFIX := $(empty) $(empty)

SHELL := bash
.SHELLFLAGS := -euo pipefail -c

BUILDER := toolchain
SOURCE_DATE_EPOCH ?= $(shell git log -1 --pretty=%ct 2>/dev/null || echo 0)
export SOURCE_DATE_EPOCH

CI_IMG  := toolchain/ci:local
DEV_IMG := toolchain/dev:local
MISE_IMG := toolchain/mise:local

.PHONY: help builder lint fmt spell lock scan check-commits check-pr-title screenshots changelog
.PHONY: build bake-print shell shell-live shell-kube-demo
.PHONY: test test-structure test-smoke test-parity test-k9s test-starship test-docker clean
.PHONY: test-log test-welcome test-mise test-lifecycle test-template test-clipboard test-release-version

help: ## List targets
  @grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

builder: ## Create the docker-container buildx builder (keeps attestations)
  @docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
    docker buildx create --name $(BUILDER) --driver docker-container --bootstrap >/dev/null
  @echo "builder: $(BUILDER)"

# Shell files for shfmt (bash + zsh) and shellcheck (bash only: it has no zsh support).
SH_SCRIPTS := $(wildcard image/*.sh image/lib/*.sh scripts/*.sh scripts/lib/*.sh tests/*.sh)
SH_SCRIPTS += $(wildcard template/.devcontainer/scripts/*.sh)
# template/dev.sh is POSIX sh (macOS still ships bash 3.2); shfmt and shellcheck read its shebang.
SH_SCRIPTS += template/dev.sh
ZSH_FILES := config/zsh/zshrc $(wildcard config/zsh/*/*.zsh)

# editorconfig-checker's binary is `ec` or `editorconfig-checker` depending on the mise registry.
EC := $(or $(shell command -v editorconfig-checker 2>/dev/null),$(shell command -v ec 2>/dev/null),ec)

lint: ## Check formatting + lint on every file (CI gate; `make fmt` fixes most of it)
  $(EC)
  shfmt --diff $(SH_SCRIPTS) $(ZSH_FILES)
  shellcheck --external-sources $(SH_SCRIPTS)
  RUST_LOG=warn taplo fmt --check
  prettier --check --log-level warn .
  markdownlint-cli2
  hadolint --config .config/hadolint.yaml Dockerfile

fmt: ## Apply formatters in place (shfmt, taplo, prettier, markdownlint fixes); policy from .editorconfig
  shfmt --write $(SH_SCRIPTS) $(ZSH_FILES)
  RUST_LOG=warn taplo fmt
  prettier --write --log-level warn .
  markdownlint-cli2 --fix

# Bind mounts are resolved by the Docker engine. Inside a dev container that uses the host's
# engine, the host doesn't have the container's paths: with LOCAL_WORKSPACE_FOLDER and
# CONTAINER_WORKSPACE_FOLDER set (the workspace on the host and in the container), translate.
# Elsewhere HOST_CURDIR is CURDIR.
HOST_CURDIR := $(if $(and $(LOCAL_WORKSPACE_FOLDER),$(CONTAINER_WORKSPACE_FOLDER),$(filter \
  $(CONTAINER_WORKSPACE_FOLDER) $(CONTAINER_WORKSPACE_FOLDER)/%,$(CURDIR))),$(patsubst \
  $(CONTAINER_WORKSPACE_FOLDER)%,$(LOCAL_WORKSPACE_FOLDER)%,$(CURDIR)),$(CURDIR))

spell: ## Spell-check the repo with cspell (runs in the dev image; config: .config/cspell.config.yaml)
  docker run --rm -u vscode -e NPM_CONFIG_UPDATE_NOTIFIER=false -v "$(HOST_CURDIR):/w:ro" -w /w $(DEV_IMG) \
    npx --yes cspell@10.3.6 lint --no-progress --gitignore '**/*' '.*' 'config/home/**/.*' 'config/home/.config/**' \
    'template/.*' 'template/.devcontainer/**' 'template/.vscode/**' '.config/**' '.github/**'

lock: builder ## Regenerate toolchain/{,dev/,shell/}mise.lock using the image's pinned mise
  docker buildx build --builder $(BUILDER) --target mise --load -t $(MISE_IMG) -q . >/dev/null
  @for dir in toolchain toolchain/dev toolchain/shell; do echo "== $$dir"; \
    docker run --rm -u $$(id -u):$$(id -g) -e HOME=/tmp -e MISE_DATA_DIR=/tmp/mise \
      -e MISE_CACHE_DIR=/tmp/cache -e MISE_LOCKED=0 -e MISE_GLOBAL_CONFIG_FILE=/m/mise.toml \
      -v "$(HOST_CURDIR)/$$dir:/m" -w / $(MISE_IMG) mise lock --global --platform linux-x64 \
      && chmod 0644 "$$dir/mise.lock"; done

screenshots: ## Render the README screenshots of `welcome` from the local dev image (FONT=<Nerd Font Mono .ttf>)
  scripts/screenshots.sh

changelog: ## Write CHANGELOG.md from Conventional Commits (git-cliff; also attached to each release)
  git-cliff --output CHANGELOG.md

# The images `make scan` checks. CI scans only dev, which contains everything in ci.
SCAN_IMGS ?= $(CI_IMG) $(DEV_IMG)

scan: ## Vulnerability gate + markdown report for the local images (Trivy; SCAN_IMGS=... to pick)
  @rc=0; for img in $(SCAN_IMGS); do scripts/scan.sh $$img || rc=1; done; exit $$rc

# Commits to lint: COMMITS_FROM..HEAD (default: since the merge-base with origin/main).
# An empty or all-zero COMMITS_FROM (e.g. a brand-new branch push) lints only HEAD.
COMMITS_FROM ?= $(shell git merge-base origin/main HEAD 2>/dev/null)

check-commits: ## Lint commit messages (Conventional Commits, commitlint) from COMMITS_FROM to HEAD
  @if [ -z "$(COMMITS_FROM)" ] || [ -z "$$(echo '$(COMMITS_FROM)' | tr -d 0)" ]; then \
    commitlint --config .config/commitlint.config.mjs --last --verbose; \
  else \
    commitlint --config .config/commitlint.config.mjs --from "$(COMMITS_FROM)" --to HEAD --verbose; \
  fi

check-pr-title: ## Lint a PR title (it becomes the squash commit): TITLE='feat: ...' make check-pr-title
  @test -n "$$TITLE" || { echo "check-pr-title: set TITLE" >&2; exit 2; }
  @printf '%s\n' "$$TITLE" | commitlint --config .config/commitlint.config.mjs --verbose

bake-print: ## Show the resolved bake configuration
  docker buildx bake --print

build: builder ## Build ci + dev and load them as toolchain/{ci,dev}:local
  docker buildx bake --builder $(BUILDER) local

# Interactive dev shell: zsh as vscode, repo at /workspaces/<repo>, true color, host kubeconfig (read-only) if present.
WS := /workspaces/$(notdir $(CURDIR))
SHELL_RUN := docker run --rm -it -u vscode -e TERM -e COLORTERM=truecolor \
  -v "$(HOST_CURDIR):$(WS)" -w $(WS) \
  $(if $(wildcard $(HOME)/.kube/config),-v "$(HOME)/.kube/config:/home/vscode/.kube/config:ro")
LIVE_MOUNTS := \
  -v "$(HOST_CURDIR)/config/zsh:/usr/local/share/toolchain/zsh:ro" \
  -v "$(HOST_CURDIR)/config/starship:/usr/local/share/toolchain/starship:ro" \
  -v "$(HOST_CURDIR)/config/home/.config/k9s:/home/vscode/.config/k9s:ro"

shell: ## Interactive zsh in the built dev image (what you'd get in the devcontainer)
  $(SHELL_RUN) $(DEV_IMG) zsh -l

shell-live: ## Same, but config/{zsh,starship,k9s} are mounted from the repo: edit on the host, see it live
  $(SHELL_RUN) $(LIVE_MOUNTS) $(DEV_IMG) zsh -l

shell-kube-demo: ## shell-live with a fake multi-context kubeconfig (no cluster needed) to try the k8s prompt
  $(SHELL_RUN) $(LIVE_MOUNTS) -e KUBECONFIG=/tmp/kubeconfig-demo \
    -v "$(HOST_CURDIR)/tests/fixtures/kubeconfig.yaml:/fixtures/kubeconfig.yaml:ro" $(DEV_IMG) \
    bash -c 'cp /fixtures/kubeconfig.yaml /tmp/kubeconfig-demo && exec zsh -l'

TESTS := test-structure test-smoke test-parity test-k9s test-starship test-docker test-log test-welcome
TESTS += test-lifecycle test-template test-clipboard test-release-version
TESTS += test-mise
test: $(TESTS) ## Run all image tests

test-structure:
  container-structure-test test --image $(CI_IMG)  --config tests/ci.structure.yaml
  container-structure-test test --image $(DEV_IMG) --config tests/dev.structure.yaml

test-smoke:
  @for img in $(CI_IMG) $(DEV_IMG); do echo "== $$img"; \
    docker run --rm -v "$(HOST_CURDIR)/tests/smoke.sh:/smoke.sh:ro" $$img bash /smoke.sh; done

test-parity:
  tests/parity.sh $(CI_IMG) $(DEV_IMG)

test-docker: ## Docker outside of Docker: the dev user reaches the host engine via the socket proxy
  tests/docker_socket.sh $(DEV_IMG)

test-starship: ## Render the starship k8s segment against the fake kubeconfig
  docker run --rm -u vscode -e TERM=xterm-256color -v "$(HOST_CURDIR)/tests:/tests:ro" $(DEV_IMG) \
    bash /tests/starship_kube.sh /tests/fixtures/kubeconfig.yaml

test-mise: ## The personal mise layer: extras install for vscode, never replace image tools (network)
  tests/mise_user.sh $(DEV_IMG)

test-welcome: ## The welcome box's borders line up for long rows and narrow terminals
  tests/welcome_width.sh $(DEV_IMG)

test-lifecycle: ## Lifecycle state, validation checks and dev-status/dev-wait/dev-reset, as vscode
  docker run --rm -u vscode -v "$(HOST_CURDIR)/tests/lifecycle.sh:/t.sh:ro" $(DEV_IMG) bash /t.sh

test-template: ## The consumer template end to end: devcontainer up, lifecycle ready, dev.sh (host; Node.js)
  tests/template.sh $(DEV_IMG)

test-clipboard: ## Clipboard and browser bridges: OSC 52, the real xclip on a display (network), xdg-open
  docker run --rm -u vscode -v "$(HOST_CURDIR)/tests/clipboard.sh:/t.sh:ro" $(DEV_IMG) bash /t.sh

test-release-version: ## Release versioning: bumps, tag pushes, refusals, re-runs after a tag push (host)
  tests/release_version.sh

test-log: ## The logging library as installed in the image (levels, colors, annotations)
  docker run --rm -v "$(HOST_CURDIR)/tests/log.sh:/t.sh:ro" $(CI_IMG) bash /t.sh /usr/local/lib/toolchain

test-k9s: ## Validate the seeded k9s config against k9s's JSON schemas (needs network)
  docker run --rm -u vscode -v "$(HOST_CURDIR)/tests/k9s_config.sh:/tests/k9s_config.sh:ro" \
    -v "$(HOST_CURDIR)/config/home/.config/k9s:/k:ro" $(DEV_IMG) bash /tests/k9s_config.sh /k

clean: ## Remove local images
  -docker image rm $(CI_IMG) $(DEV_IMG) $(MISE_IMG)
