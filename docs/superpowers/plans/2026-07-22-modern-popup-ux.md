# Modern Popup UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make scheduling feel like a modern native tmux popup and turn pending-job management into a searchable palette without weakening pane targeting or requiring new dependencies.

**Architecture:** Keep tmux as the owner of one popup layer and continue passing the immutable pane ID across that boundary. Capture the triggering client as well, use tmux 3.3 popup titles and responsive geometry, and select the pending-job interface in the order fzf, gum, then plain Bash. Keep all job identifiers as validated data and invoke preview/cancellation helpers without `eval`.

**Tech Stack:** tmux 3.3+, macOS Bash 3-compatible shell, optional fzf, optional gum, dependency-free shell fixtures.

---

### Task 1: Specify popup routing and binding behaviour

**Files:**
- Modify: `tests/test.sh`
- Modify: `tests/fixtures/tmux`
- Modify: `tmux-lagput.tmux`
- Modify: `scripts/popup-schedule.sh`
- Modify: `scripts/popup-list.sh`

- [x] **Step 1: Write failing tests**

Add assertions proving that each binding contains both `#{pane_id}` and `#{client_name}`, uses `run-shell -b`, and has a `bind-key -N` description. Exercise both `--open` launchers and assert their recorded popup arguments contain:

```text
-EE
-c	client-1
-t	%42
-T	Schedule delayed send
-w	70%
-h	16
-b	rounded
```

Use the corresponding `Pending delayed sends`, `80%`, and `70%` values for the manager. Add test tmux option variables so configured geometry and disabled `off` bindings can be asserted without changing the real tmux server.

- [x] **Step 2: Verify the tests fail for the missing behaviour**

Run:

```sh
bash tests/test.sh
```

Expected: the new routing, title, geometry, background binding, description, and disabled-binding assertions fail while the existing scheduler assertions pass.

- [x] **Step 3: Implement the minimum popup and binding changes**

Build commands with Bash arrays so every value remains a separate argument:

```bash
popup_arguments=(display-popup -EE -t "$pane_id" -T 'Schedule delayed send' -w "$popup_width" -h "$popup_height")
[ -n "$client_name" ] && popup_arguments+=(-c "$client_name")
[ -n "$border_lines" ] && popup_arguments+=(-b "$border_lines")
tmux "${popup_arguments[@]}" \
    -e "TMUX_SEND_DELAYED_PANE_ID=$pane_id" \
    -e "TMUX_SEND_DELAYED_CLIENT_NAME=$client_name" \
    -e "TMUX_SEND_DELAYED_DISPLAY_TARGET=$display_target" \
    -e "TMUX_SEND_DELAYED_SCRIPT=$SCRIPT_PATH" \
    'exec "$TMUX_SEND_DELAYED_SCRIPT" --form'
```

Register non-disabled keys with descriptions and background launchers:

```bash
tmux bind-key -N 'Schedule delayed pane input' "$schedule_key" run-shell -b "$schedule_command"
tmux bind-key -N 'Manage delayed pane input' "$list_key" run-shell -b "$list_command"
```

- [x] **Step 4: Run the suite and confirm green**

Run `bash tests/test.sh`. Expected: all TAP assertions pass.

### Task 2: Add success feedback and a reviewable schedule form

**Files:**
- Modify: `tests/test.sh`
- Modify: `tests/fixtures/tmux`
- Modify: `scripts/popup-schedule.sh`

- [x] **Step 1: Write failing feedback tests**

Submit a valid plain form with an explicit confirmation and assert that the fake tmux log contains a client-targeted status message matching:

```text
display-message	-c	client-1	-d	3000	Scheduled in 1s -> work:1.0
```

Also reject the review once and assert no job is created, then preserve the entered values when the form restarts.

- [x] **Step 2: Verify red**

Run `bash tests/test.sh`. Expected: status feedback and review assertions fail because the current form schedules immediately.

- [x] **Step 3: Implement review and feedback**

After validating the three fields, render an ASCII-safe summary and ask for confirmation with `gum confirm` or the existing Esc-aware reader. On rejection, restart with the prior values. On success, call:

```bash
tmux display-message -c "$client_name" -d 3000 "Scheduled in $duration -> $display_target"
```

Omit `-c` only for direct/manual form invocation without a captured client. Return nonzero on scheduler failure so `display-popup -EE` remains visible.

- [x] **Step 4: Verify green**

Run `bash tests/test.sh`. Expected: every form and scheduler test passes.

### Task 3: Build a searchable pending-job palette

**Files:**
- Create: `tests/fixtures-fzf/fzf`
- Create: `tests/fixtures-gum/gum`
- Modify: `tests/test.sh`
- Modify: `scripts/popup-list.sh`

- [x] **Step 1: Write failing interface-selection and preview tests**

Create executable fake selectors. The fzf fixture records arguments, consumes tab-delimited rows, and emits a requested expect key plus a selected row. The gum fixture records `filter` and `confirm` calls and emits a selected row. Assert:

```text
fzf --delimiter=<TAB> --with-nth=2.. --expect=enter,ctrl-x,ctrl-r
gum filter --header=Target | Text | Remaining
```

Assert that fzf wins when both tools are available, gum is next, and forced plain mode still works. Exercise `--preview JOB_ID` and verify full text, pane ID, display target, exact run time, backend, trailing key, and job ID are rendered. Verify Ctrl-X plus confirmation cancels only the selected validated ID.

- [x] **Step 2: Verify red**

Run `bash tests/test.sh`. Expected: selector and preview assertions fail because the current manager only uses `gum choose` or a number.

- [x] **Step 3: Implement safe selection and preview helpers**

Represent each selectable row as:

```text
JOB_ID<TAB>REMAINING<TAB>TARGET<TAB>TEXT
```

Use `--with-nth=2..` so IDs remain available but hidden. Invoke preview through the current script with a shell-quoted script path and fzf's `{1}` placeholder; validate the ID again in `--preview` before reading `jobs/$id`. Never source metadata. Treat Enter or Ctrl-X as confirmed cancellation, Ctrl-R as reload, and Esc/empty output as close. Render the same details/actions in gum and plain modes.

- [x] **Step 4: Verify green**

Run `bash tests/test.sh`. Expected: the fzf, gum, plain, cancellation, and existing scheduling cases all pass.

### Task 4: Document and harden the shipped interface

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

- [x] **Step 1: Update documentation**

Document tmux 3.3+, the fzf/gum/plain preference order, the review step, status feedback, binding disabling, and these options with their defaults:

```tmux
set -g @send-delayed-popup-width '70%'
set -g @send-delayed-popup-height '16'
set -g @send-delayed-list-popup-width '80%'
set -g @send-delayed-list-popup-height '70%'
set -g @send-delayed-popup-border-lines 'rounded'
```

Update the repository guide if the fixture layout or supported optional interfaces changed.

- [x] **Step 2: Run complete verification**

```sh
bash tests/test.sh
bash -n tmux-lagput.tmux scripts/*.sh tests/test.sh tests/fixtures/* tests/fixtures-*/*
shellcheck tmux-lagput.tmux scripts/*.sh tests/test.sh tests/fixtures/* tests/fixtures-*/*
```

Then use an isolated `tmux -L tmux-lagput-verify` server to inspect both bindings, open the form against a disposable pane, schedule literal text that writes a marker, verify sent history, and terminate only that isolated server.

- [x] **Step 3: Review and publish**

Review `git diff --check`, `git diff`, and `git status --short`; stage only planned files, commit with `feat: modernise popup workflow`, push `main`, and verify the remote commit and private repository state with `gh repo view`.
