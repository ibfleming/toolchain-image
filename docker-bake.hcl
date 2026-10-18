// One bake run builds both published targets from the same commit and base digest.
//   docker buildx bake            -> ci + dev (default group)
//   docker buildx bake local      -> both, loaded into the local (containerd) image store

// Where `ci`/`dev` are pushed (staging/<target>:<VERSION>). CI sets ghcr.io/<owner>/toolchain;
// the default suits a local registry (`docker run -d -p 5000:5000 registry:2`).
variable "REGISTRY" { default = "localhost:5000/toolchain" }
variable "VERSION" { default = "0.0.0-dev" }
variable "SOURCE_DATE_EPOCH" { default = "0" }
variable "PLATFORMS" { default = "linux/amd64" }
// Registry cache ref prefix, e.g. "${REGISTRY}/buildcache". Empty = no registry cache (local builds).
variable "CACHE_REF" { default = "" }
// "1" = also write the registry cache (release pipeline only; CI and laptops only read it).
variable "CACHE_TO" { default = "" }
// Git commit the image is built from (org.opencontainers.image.revision).
variable "REVISION" { default = "" }
// Repository URL (org.opencontainers.image.source); GHCR uses it to link packages to the repo.
variable "SOURCE_URL" { default = "" }
// The previous release and its tools (`tool=version ...`), from scripts/previous_tools.sh. The dev
// image's `welcome` marks what changed since then; empty = no marks (local builds).
variable "PREVIOUS_VERSION" { default = "" }
variable "PREVIOUS_TOOLS" { default = "" }
// A new value per release run (the release workflow passes its run ID): rebuilds the apt layers,
// so each release ships Debian's current security fixes instead of cached packages. Empty = cache.
variable "APT_REFRESH" { default = "" }

function "cache_from" {
  params = [names]
  result = CACHE_REF == "" ? [] : [for n in names : "type=registry,ref=${CACHE_REF}:${n}"]
}
function "cache_to" {
  params = [name]
  result = CACHE_REF == "" || CACHE_TO != "1" ? [] : ["type=registry,ref=${CACHE_REF}:${name},mode=max"]
}

target "_common" {
  context   = "."
  platforms = split(",", PLATFORMS)
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
  inherits   = ["_common"]
  target     = "ci"
  tags       = ["${REGISTRY}/staging/ci:${VERSION}"]
  cache-from = cache_from(["ci"])
  cache-to   = cache_to("ci")
}

target "dev" {
  inherits   = ["_common"]
  target     = "dev"
  tags       = ["${REGISTRY}/staging/dev:${VERSION}"]
  cache-from = cache_from(["ci", "dev"])
  cache-to   = cache_to("dev")
  labels = {
    // Merged with the consuming repo's devcontainer.json at create time (repo file wins).
    // Never put secrets here: anyone who can pull the image can read this label.
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
            "python.defaultInterpreterPath" = "/usr/local/bin/python3"
            "[python]" = {
              "editor.defaultFormatter" = "charliermarsh.ruff"
              "editor.formatOnSave"     = true
              "editor.codeActionsOnSave" = {
                "source.fixAll"          = "explicit"
                "source.organizeImports" = "explicit"
              }
            }
            "[go]" = {
              "editor.defaultFormatter" = "golang.go"
              "editor.formatOnSave"     = true
            }
            "go.toolsManagement.autoUpdate" = false
            "clangd.path"                   = "/usr/bin/clangd"
            "cmake.generator"               = "Ninja"
            "[cpp]" = {
              "editor.defaultFormatter" = "llvm-vs-code-extensions.vscode-clangd"
            }
            "[c]" = {
              "editor.defaultFormatter" = "llvm-vs-code-extensions.vscode-clangd"
            }
            "[opentofu]" = {
              "editor.defaultFormatter" = "opentofu.vscode-opentofu"
              "editor.formatOnSave"     = true
            }
            "terminal.integrated.defaultProfile.linux" = "zsh"
          }
        }
      }
    }])
  }
}

group "default" { targets = ["ci", "dev"] }

// Local iteration: load into the image store under stable local tags. Attestations are
// disabled explicitly: the classic Docker image store (e.g. GitHub runners) cannot load the
// manifest list they create. Release builds (`ci`, `dev` targets) keep SBOM + provenance.
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
