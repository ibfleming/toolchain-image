# shellcheck shell=bash
#
# Host paths for `docker run -v` from inside a dev container that uses the
# host's Docker engine: the engine resolves a bind mount's source on the
# host, where the container's paths don't exist. A devcontainer.json that
# sets LOCAL_WORKSPACE_FOLDER (the workspace on the host) and
# CONTAINER_WORKSPACE_FOLDER (where it is in the container) lets a path
# inside the workspace be translated. Anywhere else, paths are unchanged.
#
# Library: source it, don't run it. Sourcing it twice is harmless.

[[ -n "${_TOOLCHAIN_HOST_PATH_LOADED:-}" ]] && return 0
readonly _TOOLCHAIN_HOST_PATH_LOADED=1

#######################################
# Print the host path of a path, for use as a bind mount's source.
# Globals:
#   LOCAL_WORKSPACE_FOLDER
#   CONTAINER_WORKSPACE_FOLDER
# Arguments:
#   An absolute path.
# Outputs:
#   The host path to STDOUT: translated when it is inside the container's
#   workspace and both variables are set, unchanged otherwise.
#######################################
host_path::of() {
  local path="$1"
  local local_root="${LOCAL_WORKSPACE_FOLDER:-}"
  local container_root="${CONTAINER_WORKSPACE_FOLDER:-}"
  if [[ -n "${local_root}" && -n "${container_root}" &&
    ("${path}" == "${container_root}" ||
    "${path}" == "${container_root}/"*) ]]; then
    echo "${local_root}${path#"${container_root}"}"
  else
    echo "${path}"
  fi
}
