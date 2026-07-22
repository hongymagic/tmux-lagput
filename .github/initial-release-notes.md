tmux-send-later is the tmux-native, cancellable scheduler for literal pane
input. It schedules text for a foreground application or TUI, then sends it to
the pane that opened the popup even if focus has moved elsewhere.

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
> must still exist when a job runs; tmux-send-later never retargets a
> replacement pane.

See the [installation and upgrade guide](https://github.com/hongymagic/tmux-send-later#install),
[security and data model](https://github.com/hongymagic/tmux-send-later/security/policy),
and [full changelog](https://github.com/hongymagic/tmux-send-later/blob/main/CHANGELOG.md).
