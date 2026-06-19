# GitHub Issue Tracker Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make GitHub ticket-system status handling use labels for non-Done roles and the real closed issue state for Done.

**Architecture:** Keep Tango's semantic registry-status abstraction unchanged while making the GitHub provider expose a synthetic `closed` status ID backed by `gh issue view --json state`. Status-map discovery, validation, automatch, attestation, generated GitHub ticket-system skill text, and docs all describe the same provider contract.

**Tech Stack:** Gleam, Gleeunit, `gh` CLI adapter boundaries, repo-local Markdown docs.

---

### Task 1: GitHub Status-Map Semantics

**Files:**
- Modify: `test/status_map_test.gleam`
- Modify: `src/tango/app/status_map.gleam`

- [x] **Step 1: Write failing tests** for GitHub discovery including `closed`, validation accepting `done -> closed`, and automatch preferring `closed` for Done even if a `done` label exists.
- [x] **Step 2: Run** `mise exec gleam@latest -- gleam test test/status_map_test.gleam` and verify the new tests fail before implementation.
- [x] **Step 3: Implement** GitHub-only discovery and automatch handling for synthetic `closed`.
- [x] **Step 4: Re-run** `mise exec gleam@latest -- gleam test test/status_map_test.gleam` and verify the status-map tests pass.

### Task 2: GitHub Ticket Attestation

**Files:**
- Modify: `test/attestation_test.gleam`
- Modify: `src/tango/attestation/configured.gleam`

- [x] **Step 1: Write failing tests** proving `human_review` is verified by label while `done`/`closed` is verified by issue state.
- [x] **Step 2: Run** `mise exec gleam@latest -- gleam test test/attestation_test.gleam` and verify the new tests fail before implementation.
- [x] **Step 3: Implement** GitHub ticket decoding so non-closed labels remain statuses and closed issue state contributes `closed`.
- [x] **Step 4: Re-run** `mise exec gleam@latest -- gleam test test/attestation_test.gleam` and verify attestation tests pass.

### Task 3: Generated Skill and Docs

**Files:**
- Modify: `test/capability_manager_test.gleam`
- Modify: `src/tango/capability/manager.gleam`
- Modify: `SPEC.md`
- Modify: `docs/architecture.md`
- Modify: `TODO.md` if the tracker has an applicable open item

- [x] **Step 1: Write failing generated-skill/default-status tests** for GitHub `done -> closed` and explicit skill instructions.
- [x] **Step 2: Run** `mise exec gleam@latest -- gleam test test/capability_manager_test.gleam` and verify the tests fail before implementation.
- [x] **Step 3: Update** GitHub ticket-system defaults and generated skill text.
- [x] **Step 4: Update** the spec and architecture docs to state GitHub Done uses closed issue state, not a label.
- [x] **Step 5: Re-run** `mise exec gleam@latest -- gleam test test/capability_manager_test.gleam`.

### Task 4: Full Verification

**Files:**
- All modified files

- [x] **Step 1: Run** `mise exec gleam@latest -- gleam format src test`.
- [x] **Step 2: Run** `mise exec gleam@latest -- gleam format --check src test`.
- [x] **Step 3: Run** `mise exec gleam@latest -- gleam check`.
- [x] **Step 4: Run** `mise exec gleam@latest -- gleam test`.
- [x] **Step 5: Inspect** `git diff --check` and `git status --short`.
