# Dev container lifecycle

The `dev` image gives every repository the same way to set up a container and to tell when it's
ready: two shell libraries for your lifecycle scripts, and three commands that read the state they
record.

## What goes in which hook

Keep each hook in `devcontainer.json` to a single script call, such as
`"postCreateCommand": ".devcontainer/scripts/post-create.sh"`, and put the logic in that script.
[`template/.devcontainer/`](../template/.devcontainer/) has all three, ready to extend.

| Hook         | Runs                                     | Put here                                                                     | Not here                                      |
| ------------ | ---------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------- |
| `postCreate` | Once, when the container is created      | Dependencies (`npm ci`, `uv sync`), project bootstrap, pre-commit hooks      | Anything that must re-run on every start      |
| `postStart`  | On every start                           | Validation, readiness checks, light state reconciliation; then mark it ready | Reinstalling dependencies, long-running setup |
| `postAttach` | Each time VS Code attaches               | Status for the developer: sign-ins, branch, cluster context                  | Anything that changes state                   |
| The image    | At build time, once for every repository | OS packages, tools, runtimes, system configuration                           | Anything specific to one repository           |

Long-running services belong in Compose or a task, not in a hook.

## Hook order

Every hook but `initializeCommand` runs inside the container. For each hook, the image's own
command (from its `devcontainer.metadata` label, such as the Docker socket setup) runs before
yours, and a failing command skips every hook after it.

| When                                  | Hooks, in order                                                                                                                          |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| The container is created (or rebuilt) | `initializeCommand` (host) → `onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand` → `postAttachCommand` |
| It starts again                       | `initializeCommand` (host) → `postStartCommand` → `postAttachCommand`                                                                    |
| VS Code attaches to it                | `postAttachCommand`                                                                                                                      |

**VS Code doesn't wait for all of them.** By default (`"waitFor": "updateContentCommand"`) the
window opens once `updateContentCommand` is done, while `postCreateCommand` may still be running.
That's what `dev-status` and `dev-wait` are for. Setting `"waitFor": "postCreateCommand"` holds the
window until dependencies are installed, at the cost of a blank window for that long.

**`onCreateCommand` and `updateContentCommand`** matter for prebuilt environments (Codespaces
prebuilds, `devcontainer build`), whose result includes what they did. Locally they behave like an
earlier `postCreateCommand`, so the template doesn't use them; move dependency installation there
if you adopt prebuilds.

### `initializeCommand`: on the host

`initializeCommand` runs on the host, before the container is created or started, every time the
folder is opened. The template leaves it out, and it's best kept out:

- **It runs in the host's shell,** whatever that is: `sh` on Linux and macOS, and on Windows the
  Windows command line, unless the Dev Containers extension runs in WSL. A command that works on one
  host breaks on another, against the promise that a host needs only Git, Docker and VS Code.
- **The image's tools and libraries aren't there:** no logger, no lifecycle state.

Use it only for what must happen before Docker starts the container. The usual case is making sure
a bind-mount source exists, since a missing source makes container creation fail (an optional
`~/.kube`, or a `.env` copied from `.env.example`). Prefer the array form, which runs one program
directly, without a shell, so a program every host has behaves the same everywhere:

```jsonc
"initializeCommand": ["git", "submodule", "update", "--init"]
```

## The libraries

Both live in `/usr/local/lib/toolchain/` next to `log.sh`, and log through it (to STDERR). Source
them rather than copying them, so every repository's output and state look the same.

### `lifecycle.sh`: state and readiness

```bash
#!/bin/bash
set -euo pipefail
source /usr/local/lib/toolchain/lifecycle.sh

install_dependencies() {
  lifecycle::once dependencies npm ci
}

main() {
  lifecycle::stage post-create install_dependencies
}

main "$@"
```

| Function                              | What it does                                                                                                                                   |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `lifecycle::stage <stage> <command…>` | Runs the command with errexit on, records `<stage>.started`, then `.done` or `.failed`, and keeps its output in `<stage>.log`. Clears `ready`. |
| `lifecycle::once <marker> <command…>` | Runs the command only if `<marker>.done` doesn't exist yet in this container, and writes it on success                                         |
| `lifecycle::ready`                    | Marks the container ready                                                                                                                      |
| `lifecycle::state`                    | Sets `REPLY` to `created`, `bootstrapping`, `partial`, `failed` or `ready`                                                                     |

Call `lifecycle::stage` and `lifecycle::once` as plain commands. From a condition (`if`, `||`, `!`),
bash ignores errexit inside them, so a failing step would carry on; they refuse to run there.

### `validate.sh`: checks with a fix in the message

```bash
source /usr/local/lib/toolchain/validate.sh

validate::tool kubectl
validate::mount ~/.kube "mount ~/.kube read-only in devcontainer.json"
validate::env DATABASE_URL "set it in containerEnv"
validate::report  # fails if any check failed
```

Every check logs OK, or ERROR with its hint, and returns 0, so a script runs them all before
`validate::report` decides. `validate::check <what> <hint> <command…>` is the general form.
`validate::sign_ins` reports git, the SSH agent, the GitHub CLI and Claude Code as warnings, never
failures.

## State and commands

State is kept inside the container, in `~/.local/state/toolchain/lifecycle/` (or
`$TOOLCHAIN_STATE_DIR`), not in the workspace. A rebuild starts from nothing, like the container
itself, so a marker never claims work that the new container doesn't have.

| Command                 | What it does                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------------ |
| `dev-status [-q]`       | Prints the overall state and each stage. Exits 0 when ready, 1 when a stage failed, 2 otherwise  |
| `dev-wait [-t SECONDS]` | Waits until ready (0) or failed (1), or times out (2). Default 600 seconds; 0 waits forever      |
| `dev-reset [MARKER…]`   | Clears the named markers, or all state, so `once` steps run again the next time their stage runs |

To redo work without a rebuild, clear its marker and run the stage scripts again, in order:

```sh
dev-reset dependencies
.devcontainer/scripts/post-create.sh
.devcontainer/scripts/post-start.sh  # marks the container ready again
```

Starting any stage clears `ready`, so after re-running `post-create.sh` alone, `dev-status` says
`partial` until `post-start.sh` (or a restart) marks it ready.

```text
$ dev-status
ready
  ✓ post-create    done     2026-10-17T06:01:13+0000 41s
  ✓ post-start     done     2026-10-17T06:01:15+0000 1s
  ✓ dependencies   once     2026-10-17T06:01:12+0000
```
