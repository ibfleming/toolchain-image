// One bake run builds both published targets from the same commit and base digest.
//   docker buildx bake            -> ci + dev (default group)
//   docker buildx bake local      -> both, loaded into the local (containerd) image store

variable "REGISTRY" { default = "ghcr.io/ibfleming/toolchain" }
variable "VERSION" { default = "0.0.0-dev" }
variable "SOURCE_DATE_EPOCH" { default = "0" }
variable "PLATFORMS" { default = "linux/amd64" }
// Registry cache ref prefix, e.g. "${REGISTRY}/buildcache". Empty = no registry cache (local builds).
variable "CACHE_REF" { default = "" }

function "cache_from" {
  params = [names]
  result = CACHE_REF == "" ? [] : [for n in names : "type=registry,ref=${CACHE_REF}:${n}"]
}
function "cache_to" {
  params = [name]
  result = CACHE_REF == "" ? [] : ["type=registry,ref=${CACHE_REF}:${name},mode=max"]
}

target "_common" {
  context   = "."
  platforms = split(",", PLATFORMS)
  args      = { SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH }
  attest    = ["type=provenance,mode=max", "type=sbom"]
  secret    = ["id=github_token,env=GITHUB_TOKEN"]
  labels = {
    "org.opencontainers.image.version" = VERSION
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
      customizations = {
        vscode = {
          extensions = [
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

// Local iteration: load into the image store under stable local tags.
target "_local" {
  output = ["type=docker"]
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
