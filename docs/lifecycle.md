# Dev container lifecycle

The `dev` image gives every repository the same way to set up a container and to tell when it's
ready: two shell libraries for your lifecycle scripts, and three commands that read the state they
record.

## What goes in which hook

Keep each hook in `devcontainer.json` to a single script call, such as
`"postCreateCommand": ".devcontainer/scripts/post-create.sh"`, and put the logic in that script.

| Hook         | Runs                                     | Put here                                                                     | Not here                                      |
| ------------ | ---------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------- |
| `postCreate` | Once, when the container is created      | Dependencies (`npm ci`, `uv sync`), project bootstrap, pre-commit hooks      | Anything that must re-run on every start      |
| `postStart`  | On every start                           | Validation, readiness checks, light state reconciliation; then mark it ready | Reinstalling dependencies, long-running setup |
| `postAttach` | Each time VS Code attaches               | Status for the developer: sign-ins, branch, cluster context                  | Anything that changes state                   |
| The image    | At build time, once for every repository | OS packages, tools, runtimes, system configuration                           | Anything specific to one repository           |

Long-running services belong in Compose or a task, not in a hook.

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

```text
$ dev-status
ready
  ✓ post-create    done     2026-10-17T06:01:13+0000 41s
  ✓ post-start     done     2026-10-17T06:01:15+0000 1s
  ✓ dependencies   once     2026-10-17T06:01:12+0000
```
