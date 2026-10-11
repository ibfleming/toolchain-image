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

.PHONY: help builder lint fmt spell lock firewall-snapshot pins scan check-commits
.PHONY: build bake-print shell shell-live shell-kube-demo
.PHONY: test test-structure test-smoke test-parity test-k9s test-starship test-firewall clean

help: ## List targets
  @grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

builder: ## Create the docker-container buildx builder (keeps attestations)
  @docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
    docker buildx create --name $(BUILDER) --driver docker-container --bootstrap >/dev/null
  @echo "builder: $(BUILDER)"

# Shell files for shfmt (bash + zsh) and shellcheck (bash only: it has no zsh support).
SH_SCRIPTS := $(wildcard scripts/*.sh tests/*.sh)
ZSH_FILES := config/zsh/zshrc $(wildcard config/zsh/*/*.zsh)

# editorconfig-checker's binary is `ec` or `editorconfig-checker` depending on the mise registry.
EC := $(or $(shell command -v editorconfig-checker 2>/dev/null),$(shell command -v ec 2>/dev/null),ec)

lint: ## Check formatting + lint on every file (CI gate; `make fmt` fixes most of it)
  $(EC)
  shfmt --diff $(SH_SCRIPTS) $(ZSH_FILES)
  shellcheck $(SH_SCRIPTS)
  RUST_LOG=warn taplo fmt --check
  prettier --check --log-level warn .
  hadolint Dockerfile

fmt: ## Apply the formatters in place (shfmt, taplo, prettier); settings come from .editorconfig
  shfmt --write $(SH_SCRIPTS) $(ZSH_FILES)
  RUST_LOG=warn taplo fmt
  prettier --write --log-level warn .

spell: ## Spell-check the repo with cspell (runs in the dev image; config: cspell.config.yaml)
  docker run --rm -u vscode -e NPM_CONFIG_UPDATE_NOTIFIER=false -v "$(CURDIR):/w:ro" -w /w $(DEV_IMG) \
    npx --yes cspell@10.3.6 lint --no-progress --gitignore '**/*' '.*' 'config/home/**/.*' 'config/home/.config/**'

lock: builder ## Regenerate toolchain/{,dev/}mise.lock using the image's pinned mise
  docker buildx build --builder $(BUILDER) --target mise --load -t $(MISE_IMG) -q . >/dev/null
  @for dir in toolchain toolchain/dev; do echo "== $$dir"; \
    docker run --rm -u $$(id -u):$$(id -g) -e HOME=/tmp -e MISE_DATA_DIR=/tmp/mise \
      -e MISE_CACHE_DIR=/tmp/cache -e MISE_LOCKED=0 -e MISE_GLOBAL_CONFIG_FILE=/m/mise.toml \
      -v "$(CURDIR)/$$dir:/m" -w / $(MISE_IMG) mise lock --global --platform linux-x64; done

firewall-snapshot: ## Refresh config/firewall/github-ipv4.txt (GitHub web/api/git IPv4 ranges) from the API
  @{ echo "# GitHub web/api/git IPv4 ranges from https://api.github.com/meta, fetched $$(date -u +%F)."; \
    echo "# Fallback for init-firewall when the API is unreachable. Refresh: make firewall-snapshot"; \
    scripts/github-meta.sh; } > config/firewall/github-ipv4.txt.tmp
  @test "$$(grep -vc '^#' config/firewall/github-ipv4.txt.tmp)" -gt 10
  @mv config/firewall/github-ipv4.txt.tmp config/firewall/github-ipv4.txt
  @echo "firewall-snapshot: $$(grep -vc '^#' config/firewall/github-ipv4.txt) ranges"

pins: ## Recompute Dockerfile-pinned checksums (mise, zsh plugins) for the versions set there
  scripts/update-pins.sh

scan: ## Vulnerability gate + markdown report for the local ci/dev images (Trivy)
  @rc=0; for img in $(CI_IMG) $(DEV_IMG); do scripts/scan.sh $$img || rc=1; done; exit $$rc

check-commits: ## Check commit subjects since origin/main follow Conventional Commits
  scripts/check-commits.sh "$$(git merge-base origin/main HEAD 2>/dev/null || true)" HEAD

bake-print: ## Show the resolved bake configuration
  docker buildx bake --print

build: builder ## Build ci + dev and load them as toolchain/{ci,dev}:local
  docker buildx bake --builder $(BUILDER) local

# Interactive dev shell: zsh as vscode, repo at /workspaces/<repo>, true color, host kubeconfig (read-only) if present.
WS := /workspaces/$(notdir $(CURDIR))
SHELL_RUN := docker run --rm -it -u vscode -e TERM -e COLORTERM=truecolor \
  -v "$(CURDIR):$(WS)" -w $(WS) \
  $(if $(wildcard $(HOME)/.kube/config),-v "$(HOME)/.kube/config:/home/vscode/.kube/config:ro")
LIVE_MOUNTS := \
  -v "$(CURDIR)/config/zsh:/usr/local/share/toolchain/zsh:ro" \
  -v "$(CURDIR)/config/starship:/usr/local/share/toolchain/starship:ro" \
  -v "$(CURDIR)/config/home/.config/k9s:/home/vscode/.config/k9s:ro"

shell: ## Interactive zsh in the built dev image (what you'd get in the devcontainer)
  $(SHELL_RUN) $(DEV_IMG) zsh -l

shell-live: ## Same, but config/{zsh,starship,k9s} are mounted from the repo: edit on the host, see it live
  $(SHELL_RUN) $(LIVE_MOUNTS) $(DEV_IMG) zsh -l

shell-kube-demo: ## shell-live with a fake multi-context kubeconfig (no cluster needed) to try the k8s prompt
  $(SHELL_RUN) $(LIVE_MOUNTS) -e KUBECONFIG=/tmp/kubeconfig-demo \
    -v "$(CURDIR)/tests/fixtures/kubeconfig.yaml:/fixtures/kubeconfig.yaml:ro" $(DEV_IMG) \
    bash -c 'cp /fixtures/kubeconfig.yaml /tmp/kubeconfig-demo && exec zsh -l'

test: test-structure test-smoke test-parity test-k9s test-starship test-firewall ## Run all image tests

test-structure:
  container-structure-test test --image $(CI_IMG)  --config tests/ci.structure.yaml
  container-structure-test test --image $(DEV_IMG) --config tests/dev.structure.yaml

test-smoke:
  @for img in $(CI_IMG) $(DEV_IMG); do echo "== $$img"; \
    docker run --rm -v "$(CURDIR)/tests/smoke.sh:/smoke.sh:ro" $$img bash /smoke.sh; done

test-parity:
  tests/parity.sh $(CI_IMG) $(DEV_IMG)

test-starship: ## Render the starship k8s segment against the fake kubeconfig
  docker run --rm -u vscode -e TERM=xterm-256color -v "$(CURDIR)/tests:/tests:ro" $(DEV_IMG) \
    bash /tests/starship-kube.sh /tests/fixtures/kubeconfig.yaml

test-firewall: ## Opt-in egress firewall: allow/deny, per-repo extras, tamper resistance (needs network)
  tests/firewall.sh $(DEV_IMG)

test-k9s: ## Validate the seeded k9s config against k9s's JSON schemas (needs network)
  docker run --rm -u vscode -v "$(CURDIR)/tests/k9s-config.sh:/t.sh:ro" \
    -v "$(CURDIR)/config/home/.config/k9s:/k:ro" $(DEV_IMG) bash /t.sh /k

clean: ## Remove local images
  -docker image rm $(CI_IMG) $(DEV_IMG) $(MISE_IMG)
