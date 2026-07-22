# Repository Guide

## Scope

This repository contains a dependency-light tmux plugin written in Bash. Keep
changes focused on delayed pane input, popup interaction, scheduling, and job
state management.

## Layout

- `tmux-lagput.tmux` registers TPM key bindings.
- `scripts/popup-schedule.sh` captures the triggering pane and renders the form.
- `scripts/popup-list.sh` lists and cancels pending jobs.
- `scripts/schedule-job.sh` persists, executes, and cancels scheduled jobs.
- `scripts/parse-duration.sh` parses human-readable delays.
- `tests/test.sh` is the dependency-free behavioural test suite.
- `tests/fixtures*/` contains fake tmux, platform, fzf, and gum commands used by the tests.

## Development

- Preserve compatibility with macOS Bash 3 and current Linux Bash.
- Keep `fzf`, `gum`, `setsid`, and systemd optional; the plain Bash and `nohup`
  fallbacks must continue to work.
- Capture `#{pane_id}` and `#{client_name}` when the binding fires. Never
  retarget a job based on the focused pane or client at execution time.
- Keep tmux as the only popup owner. Run fzf inside that popup rather than
  opening a nested fzf popup.
- Keep pending-job selection ordered as fzf, gum filter, then plain Bash.
- Treat text, keys, paths, and state files as data. Do not use `eval` or source
  persisted job metadata.
- Keep execution and cancellation mutually exclusive through atomic directory
  moves.
- Update `README.md` when options, bindings, dependencies, or storage behaviour
  change.

## Verification

Run before committing:

```sh
bash tests/test.sh
bash -n tmux-lagput.tmux scripts/*.sh tests/test.sh tests/fixtures/* tests/fixtures-*/*
shellcheck tmux-lagput.tmux scripts/*.sh tests/test.sh tests/fixtures/* tests/fixtures-*/*
```

Use conventional, imperative commit messages. Do not commit secrets, local tmux
state, or generated systemd units.
