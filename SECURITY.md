# Security policy

## Supported versions

Security fixes are provided for the latest release only.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## Report a vulnerability

Use GitHub's [private vulnerability reporting](https://github.com/hongymagic/tmux-send-later/security/advisories/new).
Do not disclose a suspected vulnerability in a public issue, discussion, or
pull request.

Include the affected version or commit, operating system, tmux and Bash
versions, reproduction steps, likely impact, and any suggested mitigation.
Use harmless sample input and remove tokens, terminal contents, socket paths,
and other private data. The maintainer aims to acknowledge reports within seven
days and will coordinate validation, remediation, and disclosure with the
reporter.

## Trust and data model

tmux-send-later runs with the same user privileges as tmux. It deliberately
sends the text you schedule into the captured pane, where a shell or application
may interpret it; the default trailing `Enter` can execute a command. Review the
target and text before submitting a job.

The plugin has no sandbox or privilege boundary. It trusts tmux and the
executables it finds on `PATH`, including optional fzf, gum, setsid, and
systemd tools. As with any tmux plugin, install only revisions you trust.

Pending text, pane and socket identifiers, and job metadata are stored as
plaintext under `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-send-later` by
default. The history log is also plaintext. Newly created state uses a user-only
`umask 077`, but users are responsible for securing a custom or pre-existing
state directory and its backups. Do not schedule secrets if plaintext local
storage is unacceptable.

Socket identity and captured pane checks reduce accidental delivery to a stale
or reused target; they do not make an untrusted tmux server or pane safe. The
plugin does not make network requests.
