# Personal mise layer: your own extra tools, next to (never instead of) the pinned ones.
#
# The image's mise settings (Docker ENV) serve the image: its tools in /opt/mise, its manifests in
# /etc/mise, locked. Interactive shells point mise at your own layer instead, so `mise use -g`
# and a project's mise.toml install into your home directory:
#   config  ~/.config/mise/config.toml (global config: mise trusts it without asking)
#   tools   ~/.local/share/mise        (a volume in the devcontainer template, so rebuilds keep it)
# The image's /etc/mise manifests are hidden from this layer (MISE_SYSTEM_DIR), so they are never
# downloaded again into your home.
#
# Its shims go on PATH AFTER the system's in the dev image, so an extra tool can't replace an
# image tool (another version of one means a derived image), and BEFORE them on a host, which has
# no image toolchain. Skip this module (TOOLCHAIN_ZSH_SKIP=(conf.d/05-mise-user)) to keep mise as
# the image sets it.
(($+commands[mise])) || return 0

unset MISE_GLOBAL_CONFIG_FILE MISE_LOCKED
export MISE_DATA_DIR="$XDG_DATA_HOME/mise"
export MISE_CACHE_DIR="$XDG_CACHE_HOME/mise"
export MISE_SYSTEM_DIR="$XDG_CONFIG_HOME/mise/system"

if [[ -r /etc/toolchain/release ]]; then
  path+=("$MISE_DATA_DIR/shims")
else
  path=("$MISE_DATA_DIR/shims" $path)
fi
