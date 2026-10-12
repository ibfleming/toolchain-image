// Conventional Commits 1.0.0 (https://www.conventionalcommits.org/en/v1.0.0/), enforced with
// commitlint's standard ruleset. Tools are pinned in mise.toml; run `make check-commits` or
// `make check-pr-title TITLE='...'`. With squash-merge, the PR title becomes the commit on main.
export default {
  extends: ["@commitlint/config-conventional"],
};
