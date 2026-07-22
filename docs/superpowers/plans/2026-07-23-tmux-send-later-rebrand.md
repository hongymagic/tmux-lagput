# tmux-send-later Rebrand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename every local product, runtime, test, documentation, and release reference from tmux-lagput to tmux-send-later without changing scheduling behaviour.

**Architecture:** Apply one deliberate breaking rename across the public plugin entrypoint, tmux options, environment variables, state directory, and systemd units. Update tests and fixtures to assert only the new identity, then use a repository-wide stale-name scan and the full shell verification suite as the completion gate.

**Tech Stack:** Bash 3.2, tmux 3.3a+, TPM, systemd user units, GitHub Actions, Markdown, SVG.

---

### Task 1: Rename the runtime identity

**Files:**
- Rename: `tmux-lagput.tmux` to `tmux-send-later.tmux`
- Modify: `scripts/popup-schedule.sh`
- Modify: `scripts/popup-list.sh`
- Modify: `scripts/schedule-job.sh`

- [x] **Step 1: Rename the public entrypoint and configuration contract**

Apply these exact replacements throughout runtime code:

```text
tmux-lagput.tmux       -> tmux-send-later.tmux
@send-delayed-*        -> @send-later-*
TMUX_SEND_DELAYED_*    -> TMUX_SEND_LATER_*
tmux-lagput            -> tmux-send-later
```

- [x] **Step 2: Preserve scheduler invariants**

Keep captured pane/client handling, literal `send-keys`, atomic job moves,
worker PID validation, socket identity checks, optional dependencies, and
Bash 3.2 compatibility unchanged. Rename generated unit validation and creation
to the exact prefix:

```bash
tmux-send-later-$job_id.timer
tmux-send-later-$job_id.service
```

- [x] **Step 3: Check runtime syntax**

Run:

```sh
bash -n tmux-send-later.tmux scripts/*.sh
```

Expected: exit 0 with no output.

### Task 2: Rename tests and fixtures

**Files:**
- Modify: `tests/test.sh`
- Modify: `tests/test-calver.sh`
- Modify: `tests/smoke-tmux.sh`
- Modify: `tests/fixtures-fzf/fzf`
- Modify: `tests/fixtures-systemctl-publish-failure/systemctl`

- [x] **Step 1: Update all fixture contracts**

Point tests at `tmux-send-later.tmux`, use `TMUX_SEND_LATER_*`, assert
`@send-later-*`, and expect `tmux-send-later-*` unit names. Rename disposable
test directories, socket names, marker names, and the smoke-test session.

- [x] **Step 2: Run behavioural tests**

Run:

```sh
bash tests/test.sh
bash tests/test-calver.sh
bash tests/smoke-tmux.sh
```

Expected: every assertion passes and the smoke test reports successful delivery.

### Task 3: Rename documentation and repository metadata

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `CONTRIBUTING.md`
- Modify: `SECURITY.md`
- Modify: `SUPPORT.md`
- Modify: `CODE_OF_CONDUCT.md`
- Modify: `AGENTS.md`
- Modify: `.github/initial-release-notes.md`
- Modify: `.github/ISSUE_TEMPLATE/bug.yml`
- Modify: `.github/ISSUE_TEMPLATE/feature.yml`
- Modify: `.github/ISSUE_TEMPLATE/config.yml`
- Modify: `.github/PULL_REQUEST_TEMPLATE.md`

- [x] **Step 1: Update product language and URLs**

Use `tmux-send-later` as the full name, `send later` only as natural prose, and
`https://github.com/hongymagic/tmux-send-later` for repository links. Keep the
README centred on deferred input for foreground applications and TUIs.

- [x] **Step 2: Document the breaking rename**

Add an Unreleased changelog entry naming the entrypoint, option, environment,
state-path, and systemd-prefix changes. State that users should clean up pending
old-brand jobs before upgrading; do not add runtime compatibility aliases.

### Task 4: Rename automation and visual assets

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/assets/demo.svg`

- [x] **Step 1: Update CI commands**

Run syntax and ShellCheck against `tmux-send-later.tmux`.

- [x] **Step 2: Update accessible and visible SVG branding**

Replace both the SVG title and rendered footer label with `tmux-send-later`,
adjusting text placement if required so the longer name fits.

### Task 5: Verify the complete rebrand

**Files:**
- Review: all modified files

- [x] **Step 1: Prove the old identity is absent**

Run:

```sh
rg -n --hidden -g '!.git/**' -g '!CHANGELOG.md' \
  -g '!docs/superpowers/plans/**' \
  'tmux-lagput|TMUX_SEND_DELAYED|SEND_DELAYED|@send-delayed|send-delayed|lagput' .
```

Expected: exit 1 with no matches. The changelog and this implementation plan
retain the former names only to document the breaking migration.

- [x] **Step 2: Run the full repository gate**

Run:

```sh
bash tests/test.sh
bash tests/test-calver.sh
bash tests/smoke-tmux.sh
bash -n tmux-send-later.tmux scripts/*.sh tests/*.sh tests/fixtures/* tests/fixtures-*/*
shellcheck tmux-send-later.tmux scripts/*.sh tests/*.sh tests/fixtures/* tests/fixtures-*/*
git diff --check
```

Expected: every command exits 0.

- [x] **Step 3: Review scope**

Confirm `git status --short` contains only the planned rebrand and the README
simplification already requested in this working tree. Do not commit, push, or
rename the remote repository because those actions were not requested.
