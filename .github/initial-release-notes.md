tmux-lagput is a tmux-native command palette for scheduling literal text against
the pane that opened it, then reviewing or cancelling pending sends from a
second popup.

Highlights:

- Captures the triggering pane and tmux server instead of following focus.
- Accepts human-readable delays such as `90s`, `30m`, `5h`, and `1d2h`.
- Uses fzf or gum when available, with a dependency-light Bash fallback.
- Supports detached jobs on Linux and macOS, plus optional persistent systemd
  user timers on Linux.
- Records sent, failed, cancelled, and uncertain outcomes in local history.

Requirements: tmux 3.3a+, Bash 3.2+, and `nohup`. fzf, gum, setsid, and systemd
are optional.

> [!CAUTION]
> The default trailing `Enter` can execute the scheduled text. Pending text and
> job history are stored locally as plaintext. A captured pane and tmux server
> must still exist when a job runs; lagput never retargets a replacement pane.

See the [installation and upgrade guide](https://github.com/hongymagic/tmux-lagput#install),
[security and data model](https://github.com/hongymagic/tmux-lagput/security/policy),
and [full changelog](https://github.com/hongymagic/tmux-lagput/blob/main/CHANGELOG.md).
