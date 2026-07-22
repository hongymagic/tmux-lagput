## Summary

Describe what changed and why.

## Related issue

Link the issue or explain why one is not needed.

## Verification

```sh
bash tests/test.sh
bash tests/test-calver.sh
bash tests/smoke-tmux.sh
bash -n tmux-lagput.tmux scripts/*.sh tests/*.sh tests/fixtures/* tests/fixtures-*/*
shellcheck tmux-lagput.tmux scripts/*.sh tests/*.sh tests/fixtures/* tests/fixtures-*/*
```

List any manual tmux testing and the platforms exercised.

## Checklist

- [ ] The change is focused and includes behavioural coverage where practical.
- [ ] macOS Bash 3 and current Linux Bash compatibility are preserved.
- [ ] fzf, gum, setsid, and systemd remain optional.
- [ ] Captured pane/client targeting and atomic job ownership remain intact.
- [ ] User-facing documentation and `CHANGELOG.md` are updated when needed.
- [ ] No secrets, scheduled input, terminal contents, or local state are included.
