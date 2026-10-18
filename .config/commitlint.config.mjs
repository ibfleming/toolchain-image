// Conventional Commits 1.0.0 (https://www.conventionalcommits.org/en/v1.0.0/), enforced with
// commitlint's standard ruleset. Tools are pinned in mise.toml; run `make check-commits` or
// `make check-pr-title TITLE='...'`. With squash-merge, the PR title becomes the commit on main.
export default {
  extends: ["@commitlint/config-conventional"],
  rules: {
    // The spec sets no body/footer length limit, and URLs or table rows can't be wrapped
    // (squash commits carry them from PR branches). Headers stay fully enforced.
    "body-max-line-length": [0],
    "footer-max-line-length": [0],
  },
};
