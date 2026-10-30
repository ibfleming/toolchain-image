# Contributing

Thanks for helping. The [README](../README.md#develop) covers the tools and every `make` target;
this page is the short version of how a change gets in.

## The inner loop

```sh
mise install          # every lint, test and release tool at its pinned version
make build test       # build ci + dev, run the image tests
make lint spell       # the formatting, lint and spelling gates (`make fmt` fixes most lint)
```

CI runs the same targets, so a green local run is a green CI run (except tests that need the
network or a display, which CI has).

## Pull requests

- **The PR title becomes the commit on `main`** (squash merge), so it must follow
  [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):
  `type(scope): description`. `fix` releases a patch, `feat` a minor, and a breaking change (`!` plus
  a `BREAKING CHANGE:` footer in a commit message) a major. Removing a tool is breaking.
- One logical change per PR. The branch's commit messages become the body of the squash commit.
- Check a title locally: `TITLE='feat: ...' make check-pr-title`.

## Common changes

- **Add or bump a tool:** edit a manifest in `toolchain/`, run `make lock`, add a probe to
  `tests/smoke.sh` (the test fails without one), then `make build test`.
- **Change a workflow:** `make lint` audits workflows with jactionlint. Pin actions to a full
  commit SHA with a version comment; an action from a new owner must be added to
  `.config/jactionlint.yaml`.
- **Change the shell config:** `make shell-live` mounts `config/` over the image, so edits apply
  without a rebuild.

Where files belong: [Layout](../docs/layout.md). Why things are the way they are:
[Architecture](../docs/architecture.md) and the [design records](../docs/design/README.md).

## Reporting

- Bugs and tool requests: open an issue with one of the forms.
- Vulnerabilities: privately, see [SECURITY.md](SECURITY.md).
