// Build definitions for the two published images (what each contains is in the Dockerfile).
//
//   docker buildx bake          ci + dev (the default group): attested, tagged REGISTRY/<target>:VERSION
//   docker buildx bake local    ci + dev loaded into the local image store as toolchain/*:local
//
// Every variable below can be set from the environment (CI) or passed as a bake variable (the
// release builds each target through docker/github-builder, which sets its own outputs, tags,
// provenance and cache, and builds dev on the pushed ci digest: see .github/workflows/release.yml).


// =================================================================================================
// Variables
// =================================================================================================

// --- Where images go -----------------------------------------------------------------------------
// Tagged REGISTRY/<target>:VERSION by a plain `docker buildx bake`; the default suits a local
// registry (`docker run -d -p 5000:5000 registry:2`).
variable "REGISTRY" { default = "localhost:5000/toolchain" }
variable "VERSION" { default = "0.0.0-dev" }

// --- Image metadata ------------------------------------------------------------------------------
// Git commit the image is built from (org.opencontainers.image.revision).
variable "REVISION" { default = "" }
// Repository URL (org.opencontainers.image.source); GHCR uses it to link packages to the repo.
variable "SOURCE_URL" { default = "" }
// Build date for reproducible builds (the commit's time in releases; 0 locally).
variable "SOURCE_DATE_EPOCH" { default = "0" }
// The previous release and its tools (`tool=version ...`), from scripts/previous_tools.sh. The dev
// image's `welcome` marks what changed since then; empty = no marks (local builds).
variable "PREVIOUS_VERSION" { default = "" }
variable "PREVIOUS_TOOLS" { default = "" }

// --- Build behaviour -----------------------------------------------------------------------------
// Comma-separated, e.g. "linux/amd64,linux/arm64". Empty = the builder's native platform, so local
// builds and CI's per-architecture jobs never run under emulation.
variable "PLATFORMS" { default = "" }
// A new value per release run (the release workflow passes its run ID): rebuilds the apt layers,
// so each release ships Debian's current security fixes instead of cached packages. Empty = cache.
variable "APT_REFRESH" { default = "" }


// =================================================================================================
// Published targets: ci and dev
// =================================================================================================

// Shared by both: build args, SBOM and provenance attestations, the BuildKit secret for mise's
// GitHub downloads (never a build arg: mode=max provenance publishes build args), OCI labels.
target "_common" {
  context   = "."
  platforms = PLATFORMS == "" ? null : split(",", PLATFORMS)
  args = {
    SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH
    VERSION           = VERSION
    REVISION          = REVISION
    SOURCE_URL        = SOURCE_URL
    PREVIOUS_VERSION  = PREVIOUS_VERSION
    PREVIOUS_TOOLS    = PREVIOUS_TOOLS
    APT_REFRESH       = APT_REFRESH
  }
  attest    = ["type=provenance,mode=max", "type=sbom"]
  secret    = ["id=github_token,env=GITHUB_TOKEN"]
  labels = {
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = REVISION
    "org.opencontainers.image.source"   = SOURCE_URL
  }
}

target "ci" {
  inherits = ["_common"]
  target   = "ci"
  tags     = ["${REGISTRY}/ci:${VERSION}"]
}

// The release passes `dev.contexts.ci=docker-image://<ci>@<digest>`: the named context replaces the
// Dockerfile's ci stage, so dev is built on the exact ci image that was pushed and tested.
target "dev" {
  inherits = ["_common"]
  target   = "dev"
  tags     = ["${REGISTRY}/dev:${VERSION}"]
  labels = {
    // The dev container setup that ships with the image. Merged with the consuming repo's
    // devcontainer.json when the container is created (the repo's file wins on conflicts).
    // Never put secrets here: anyone who can pull the image can read this label.
    // template/.devcontainer/README.md summarizes it for consumers: keep that table in step.
    "devcontainer.metadata" = jsonencode([{
      remoteUser = "vscode"
      // Serves a mounted host Docker socket to vscode; a no-op without one (see the template).
      postStartCommand = "sudo /usr/local/sbin/docker-socket-init"
      customizations = {
        vscode = {
          extensions = [
            "anthropic.claude-code",
            "editorconfig.editorconfig",
            "ms-python.python",
            "charliermarsh.ruff",
            "golang.go",
            "llvm-vs-code-extensions.vscode-clangd",
            "ms-vscode.cmake-tools",
            "opentofu.vscode-opentofu",
            "redhat.vscode-yaml",
            "tamasfe.even-better-toml",
          ]
          settings = {
            // Python: the image's interpreter; Ruff formats, fixes and sorts imports on save.
            "python.defaultInterpreterPath" = "/usr/local/bin/python3"
            "[python]" = {
              "editor.defaultFormatter" = "charliermarsh.ruff"
              "editor.formatOnSave"     = true
              "editor.codeActionsOnSave" = {
                "source.fixAll"          = "explicit"
                "source.organizeImports" = "explicit"
              }
            }
            // Go: format on save; the image provides the Go tools, so the extension leaves them.
            "[go]" = {
              "editor.defaultFormatter" = "golang.go"
              "editor.formatOnSave"     = true
            }
            "go.toolsManagement.autoUpdate" = false
            // C and C++: the image's clangd; CMake builds with Ninja.
            "clangd.path"     = "/usr/bin/clangd"
            "cmake.generator" = "Ninja"
            "[cpp]" = {
              "editor.defaultFormatter" = "llvm-vs-code-extensions.vscode-clangd"
            }
            "[c]" = {
              "editor.defaultFormatter" = "llvm-vs-code-extensions.vscode-clangd"
            }
            // OpenTofu: format on save.
            "[opentofu]" = {
              "editor.defaultFormatter" = "opentofu.vscode-opentofu"
              "editor.formatOnSave"     = true
            }
            // Terminals open the image's zsh.
            "terminal.integrated.defaultProfile.linux" = "zsh"
          }
        }
      }
    }])
  }
}

group "default" { targets = ["ci", "dev"] }


// =================================================================================================
// Local builds: toolchain/ci:local and toolchain/dev:local
// =================================================================================================

// Loaded into the local image store under stable tags. Attestations are disabled explicitly: the
// classic Docker image store (e.g. GitHub runners) can't load the manifest list they create.
// Release builds (the ci and dev targets) keep SBOM and provenance.
target "_local" {
  // Uncompressed: these images only go into the local image store, so compressing their layers
  // (about 2 GB each, gzip on one core) only to unpack them again is wasted time.
  output = ["type=docker,compression=uncompressed"]
  attest = ["type=provenance,disabled=true", "type=sbom,disabled=true"]
}

target "ci-local" {
  inherits = ["ci", "_local"]
  tags     = ["toolchain/ci:local"]
}

target "dev-local" {
  inherits = ["dev", "_local"]
  tags     = ["toolchain/dev:local"]
}

group "local" { targets = ["ci-local", "dev-local"] }
