#!/usr/bin/env bash
# Symlink every executable from the installed mise tools into /usr/local/bin.
#
# The image does not use mise shims at runtime: shims re-resolve versions from
# whatever mise.toml/.tool-versions the job's workspace contains, which brings back
# runtime resolution and drift. Plain symlinks keep the manifest's versions fixed.
set -euo pipefail

dest=/usr/local/bin
declare -A owner=()
linked=0

while IFS= read -r dir; do
  [[ -d "$dir" ]] || continue
  for exe in "$dir"/*; do
    [[ -f "$exe" && -x "$exe" ]] || continue
    name="$(basename "$exe")"
    if [[ -n "${owner[$name]:-}" ]]; then
      echo "link-tools: '$name' provided by both ${owner[$name]} and $dir" >&2
      exit 1
    fi
    owner[$name]="$dir"
    # Link the fully resolved target: tools like npm are themselves relative symlinks and
    # locate their modules from the path they were invoked through.
    target="$(readlink -f "$exe")"
    if [[ -e "$dest/$name" || -L "$dest/$name" ]]; then
      # Already linked by an earlier run (e.g. ci tools seen again from the dev stage).
      [[ "$(readlink "$dest/$name")" == "$target" ]] && continue
      echo "link-tools: $dest/$name already exists (refusing to shadow)" >&2
      exit 1
    fi
    ln -s "$target" "$dest/$name"
    ((++linked))
  done
done < <(cd / && mise bin-paths)

echo "link-tools: linked $linked new executables into $dest (${#owner[@]} seen)"
