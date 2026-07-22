# Changelog

All notable changes to tmux-lagput are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versions use q-style CalVer: `YYYY.MMDD.PATCH`. The date identifies the release
day and the zero-based patch component increments for additional releases on
that date. Git tags add a leading `v`, such as `v2026.0722.0`.

## [Unreleased]

No changes yet.

## [2026.0722.0] - 2026-07-22

### Added

- A tmux-native popup form for scheduling literal text against the pane and
  client captured when the binding fires.
- Human-readable delays, an optional trailing key, inline validation, and a
  review step before scheduling.
- A searchable pending-job manager with fzf, gum, and dependency-free Bash
  interfaces plus confirmed cancellation.
- Detached background scheduling on Linux and macOS, with optional persistent
  systemd user timers on Linux.
- Plaintext user-local job state, atomic execution and cancellation, socket and
  pane identity checks, and an outcome history log.
- TPM options for bindings, popup geometry, border style, state location, and
  scheduling backend.
- Behavioural, syntax, and ShellCheck coverage in Linux and macOS CI.
- UTC CalVer helpers, automated GitHub releases, and real-tmux smoke coverage
  against tmux 3.3a and current releases.

[Unreleased]: https://github.com/hongymagic/tmux-lagput/compare/v2026.0722.0...HEAD
[2026.0722.0]: https://github.com/hongymagic/tmux-lagput/releases/tag/v2026.0722.0
