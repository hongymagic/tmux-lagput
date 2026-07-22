# Contributing

Thanks for helping improve tmux-send-later. Bug reports, focused changes, tests,
documentation, and accessibility improvements are welcome.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
Report vulnerabilities through the private process in [SECURITY.md](SECURITY.md),
not in a public issue or pull request.

## Before you start

- Search existing issues before opening a new one.
- Use the bug form for reproducible defects and the feature form for proposals.
- For a substantial behaviour or interface change, open an issue before doing
  extensive work so the approach can be agreed first.

## Development setup

The plugin requires tmux 3.3a or newer and Bash. `shellcheck` and `ripgrep` are
needed for the full verification suite; `fzf`, `gum`, `setsid`, and systemd are
optional.

```sh
git clone https://github.com/hongymagic/tmux-send-later.git
cd tmux-send-later
bash tests/test.sh
```

Keep the implementation compatible with macOS Bash 3 and current Linux Bash.
In particular, do not introduce Bash 4-only features. The plain Bash interface
and `nohup` scheduler must remain usable when optional tools are absent.

## Make a change

Create a focused branch from `main`, match the existing shell style, and add a
behavioural regression test for changed behaviour. Preserve these invariants:

- Capture the pane ID and client when the binding fires; never retarget later.
- Keep tmux as the only popup owner, including when fzf is available.
- Prefer fzf, then gum, then plain Bash for pending-job selection.
- Treat input, paths, and persisted metadata as data; never evaluate them.
- Keep job execution and cancellation mutually exclusive through atomic moves.
- Keep optional dependencies optional on both macOS and Linux.

Update user-facing documentation and `CHANGELOG.md` when behaviour, options,
bindings, dependencies, or state storage changes.

## Verify

Run every check before submitting a pull request:

```sh
bash tests/test.sh
bash tests/test-calver.sh
bash tests/smoke-tmux.sh
bash -n tmux-send-later.tmux scripts/*.sh tests/*.sh tests/fixtures/* tests/fixtures-*/*
shellcheck tmux-send-later.tmux scripts/*.sh tests/*.sh tests/fixtures/* tests/fixtures-*/*
```

CI repeats these checks on Linux and macOS. Include any additional manual tmux
testing in the pull request description.

## Commits and pull requests

Use clear, imperative conventional commits where they fit, such as
`fix: preserve the captured tmux socket`. Keep pull requests small enough to
review, explain why the change is needed, link related issues, and complete the
pull request checklist.

Releases use q-style CalVer: `YYYY.MMDD.PATCH`, with a leading `v` in Git tags.
For example, the first release on 22 July 2026 is `2026.0722.0` and its tag is
`v2026.0722.0`; another release on that date increments the patch component.
Maintainers assign release versions during release preparation.
