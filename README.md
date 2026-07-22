# tmux-send-later

[![CI](https://github.com/hongymagic/tmux-send-later/actions/workflows/ci.yml/badge.svg)](https://github.com/hongymagic/tmux-send-later/actions/workflows/ci.yml)
[![Latest CalVer release](https://img.shields.io/github/v/release/hongymagic/tmux-send-later?display_name=tag&label=CalVer)](https://github.com/hongymagic/tmux-send-later/releases/latest)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

**The tmux-native, cancellable scheduler for literal pane input.**

Use it when a foreground application or TUI will need input later: schedule the
literal text now, switch away, and let tmux-send-later send it back to that exact
pane when it is due.

![The tmux-send-later schedule form and pending-send palette](.github/assets/demo.svg)

## Why tmux-send-later?

- **Native:** schedule and manage sends without leaving tmux.
- **Predictable:** jobs stay attached to the captured pane and tmux server;
  they never follow your current focus.
- **Cancellable:** inspect pending sends and cancel them before they run.
- **Portable:** the Bash interface works on Linux and macOS. fzf, gum, setsid,
  and systemd are optional enhancements.

## Install

### TPM

Add the plugin before TPM's initialisation line in `~/.tmux.conf`:

```tmux
set -g @plugin 'hongymagic/tmux-send-later'

# Keep this as the final plugin line.
run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux, then press `prefix + I`:

```sh
tmux source-file ~/.tmux.conf
```

### Manual

```sh
git clone --depth 1 https://github.com/hongymagic/tmux-send-later.git \
  ~/.tmux/plugins/tmux-send-later
```

Add this to `~/.tmux.conf`, then reload it:

```tmux
run-shell ~/.tmux/plugins/tmux-send-later/tmux-send-later.tmux
```

## Use

| Binding | Action |
| --- | --- |
| `prefix + T` | Schedule a send. |
| `prefix + C-t` | Inspect and cancel pending sends. |

### Schedule a send

Press `prefix + T`, then enter:

1. The literal text to send.
2. A delay such as `90s`, `30m`, `5h`, or `1d2h`.
3. An optional trailing key. The default is `Enter`; use `none` to send only
   the text.
4. Review the captured target and submit.

Invalid values stay in the popup for correction. Press Esc at any point to
cancel without creating a job.

> [!CAUTION]
> A trailing `Enter` can execute the scheduled text. Check the target and text
> before submitting.

### Manage pending sends

Press `prefix + C-t` to see each job's remaining time, captured target, and
text. Select one to review its details and confirm cancellation.

The palette uses fzf when available, then gum, then a numbered Bash interface:

| Interface | Controls |
| --- | --- |
| fzf | `Enter`/`Ctrl-X`: review; `Ctrl-R`: refresh; Esc: close. |
| gum | Filter and select a row, then confirm. |
| Plain Bash | Number: review; `r`: refresh; `q`/Esc: close. |

## Configure

Set options before TPM's initialisation line, then reload `~/.tmux.conf`:

```tmux
# Use prefix + t to schedule and prefix + T to manage.
set -g @send-later-key 't'
set -g @send-later-list-key 'T'

# Linux only: prefer persistent systemd user timers.
set -g @send-later-use-systemd 'on'
```

| Option | Default | Purpose |
| --- | --- | --- |
| `@send-later-key` | `T` | Schedule-popup binding; `none` or `off` disables it. |
| `@send-later-list-key` | `C-t` | Pending-jobs binding; `none` or `off` disables it. |
| `@send-later-popup-width` | `70%` | Schedule-popup width. |
| `@send-later-popup-height` | `16` | Schedule-popup height. |
| `@send-later-list-popup-width` | `80%` | Pending-jobs popup width. |
| `@send-later-list-popup-height` | `70%` | Pending-jobs popup height. |
| `@send-later-popup-border-lines` | `rounded` | Popup border style; `default` inherits tmux's setting. |
| `@send-later-use-systemd` | `off` | Prefer persistent user timers on Linux. |
| `@send-later-state-dir` | `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-send-later` | Absolute state and history directory. |

When `XDG_STATE_HOME` is unset, the state directory defaults to
`~/.local/state/tmux-send-later`.

tmux treats uppercase `T` and Shift+T as the same key. Stock tmux also uses
lowercase `prefix + t` for `clock-mode`, so choosing `t` replaces that binding.

## Requirements

- tmux 3.3a or newer.
- Bash 3.2 or newer, including the Bash shipped with macOS.
- `nohup` for the default background worker.
- Optional: fzf, gum, setsid, and a Linux systemd user manager.

CI tests current Ubuntu and macOS runners, the dependency-free fallbacks, and
the minimum supported tmux 3.3a release.

## How it works

The key binding captures the triggering pane ID, client, and tmux socket
identity. At delivery time, tmux-send-later verifies the pane and server still
match. If either has disappeared or changed, the job fails instead of sending
somewhere else.

The default backend runs a detached worker with `nohup` and uses `setsid` when
available. Scheduling, execution, and cancellation claim jobs through atomic
directory moves. On Linux, `@send-later-use-systemd on` prefers persistent
per-job user timers and falls back to the detached worker when it can do so
safely.

## State and safety

Pending input, target identifiers, backend metadata, and `jobs-history.log`
are stored as plaintext under the configured state directory. New state uses a
user-only `umask 077`, but custom directories and backups remain your
responsibility. Avoid scheduling secrets when plaintext storage is unsuitable.

History records sent, failed, and cancelled outcomes. tmux-send-later has no
telemetry and makes no network requests. See the [security policy](SECURITY.md)
for the full trust and data model.

## Upgrade

Read the [changelog](CHANGELOG.md), including its migration notes when upgrading
from an earlier product name, then use `prefix + U` with TPM. For a manual
installation:

```sh
git -C ~/.tmux/plugins/tmux-send-later pull --ff-only
tmux source-file ~/.tmux.conf
```

## Uninstall

Stop pending workers and generated systemd units before removing the plugin:

```sh
~/.tmux/plugins/tmux-send-later/scripts/cleanup.sh
```

Remove the plugin line from `~/.tmux.conf`, uninstall it through TPM or remove
the cloned directory, then reload tmux. Cleanup retains the state directory and
history for review; remove them separately if no longer needed.

## Help and contributing

See [Support](SUPPORT.md) for troubleshooting and issue reporting. Contributions
are welcome through [CONTRIBUTING.md](CONTRIBUTING.md); report vulnerabilities
through the private process in [SECURITY.md](SECURITY.md).

tmux-send-later is available under the [MIT Licence](LICENSE).
