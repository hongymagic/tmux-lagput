# tmux-lagput

`tmux-lagput` adds a popup command palette for sending text to a tmux pane after a human-readable delay. It captures the pane that opened the popup, so changing focus before the timer expires does not change the destination.

## Install with TPM

Add the plugin to `~/.tmux.conf`:

```tmux
set -g @plugin 'hongymagic/tmux-lagput'
```

Reload tmux, then press `prefix + I` to install it with [TPM](https://github.com/tmux-plugins/tpm). The plugin requires a tmux version with `display-popup` support and Bash. `gum` is optional.

## Use

Press `prefix + T` to open the scheduling popup. Enter:

1. Text to send.
2. A delay such as `90s`, `30m`, `5h`, or `1d2h`.
3. A tmux key name to send afterwards. This defaults to `Enter`; enter `none` to send only the literal text.

Empty text and invalid durations are reported in the popup without closing it. Press Esc at any field to cancel without creating a job.

Press `prefix + C-t` to list pending sends. Each row shows the captured `session:window.pane`, text, and remaining time. Choose a row to cancel it or press Esc to close the popup.

tmux represents uppercase `T` and Shift+T as the same key, so they cannot be separate defaults. The requested schedule key remains `T`; the list key therefore defaults to `C-t`. For a lowercase/uppercase pair, configure `t` and `T` explicitly.

## Options

Set options before the TPM initialisation line in `~/.tmux.conf`:

```tmux
# Open the schedule popup with prefix + t.
set -g @send-delayed-key 't'

# Open the pending-jobs popup with prefix + T.
set -g @send-delayed-list-key 'T'

# Linux only: prefer persistent systemd user timers.
set -g @send-delayed-use-systemd 'on'

# Optional absolute state directory.
set -g @send-delayed-state-dir '/home/me/.local/state/tmux-lagput'
```

| Option | Default | Purpose |
| --- | --- | --- |
| `@send-delayed-key` | `T` | Schedule-popup binding. |
| `@send-delayed-list-key` | `C-t` | Pending-jobs popup binding. |
| `@send-delayed-use-systemd` | `off` | Use a persistent systemd user timer when supported. Values `1`, `on`, `yes`, and `true` enable it. |
| `@send-delayed-state-dir` | `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-lagput` | Job and history storage. Configure this as an absolute path. |

## Optional gum interface

If [`gum`](https://github.com/charmbracelet/gum) is on `PATH`, the plugin uses it for input and job selection. Without gum, the built-in Bash interface provides the same validation and Esc-to-cancel behaviour; no TUI framework is required.

## Scheduling and state

Every pending job has a unique directory under:

```text
~/.local/state/tmux-lagput/
├── jobs/<job-id>/
├── running/
└── jobs-history.log
```

The default backend launches a detached worker with `nohup` and uses `setsid` when it is available. This works on Linux and macOS; the worker sleeps until the stored epoch time, atomically claims the job, verifies the captured tmux server and pane, then runs the equivalent of:

```sh
tmux send-keys -t <captured-pane-id> -l -- "<text>"
tmux send-keys -t <captured-pane-id> <key>
```

Job fields are stored as data files and are never evaluated as shell code. Atomic directory moves ensure execution and cancellation cannot both claim the same job.

With `@send-delayed-use-systemd on`, Linux installs a per-job service and timer under `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/` with `Persistent=true`. If user systemd is unavailable, setup fails, or the host is macOS, scheduling falls back to the detached worker.

A tmux pane does not survive a normal machine reboot. Persistent timers preserve the schedule and audit trail, but they cannot recreate the destination pane: the job records a failure instead of sending if the original tmux socket or pane no longer exists. Socket identity checks also prevent a pane ID reused by a later tmux server from receiving stale input.

`jobs-history.log` records UTC time, job ID, outcome, display target, and detail for sent, failed, and cancelled jobs. In particular, a missing target is recorded rather than failing silently.

## Development

Run the dependency-free test suite and shell syntax checks:

```sh
bash tests/test.sh
bash -n tmux-lagput.tmux scripts/*.sh tests/test.sh tests/fixtures/* tests/fixtures-*/*
shellcheck tmux-lagput.tmux scripts/*.sh tests/test.sh tests/fixtures/* tests/fixtures-*/*
```
