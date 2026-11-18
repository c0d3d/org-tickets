# Remote Change Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before sync pushes anything, detect Jira edits made by someone else since each ticket's last sync; pull metadata-only edits into org, cancel the whole sync on content (summary/description) edits.

**Architecture:** Phase 1's existing per-ticket GET now records `fields.updated`, and phase 3 writes it as `JIRA_SYNCED` for successful pushes.  A new pre-flight step in a new module `org-tickets-conflict.el` runs before the buffer is parsed: it GETs `/myself` and each `JIRA_SYNCED` ticket with `?expand=changelog`, classifies foreign changes, then either cancels with a warning or pulls metadata and hands off to the existing phase 1.

**Tech Stack:** Emacs Lisp, org-mode, ERT, Jira REST v3.

**Spec:** `docs/superpowers/specs/2026-11-18-remote-change-check-design.md`

## Global Constraints

- No `cl-lib` anywhere (see CLAUDE.md table); no new dependencies.
- No file over 750 lines.  `org-tickets-sync-phases.el` is 545 — new logic goes in `org-tickets-conflict.el`.
- `org-tickets--` prefix, docstring on every function, functions ≲30 lines, ≤3 nesting levels.
- Content fields are exactly `fieldId` `"summary"` and `"description"`; every other changelog item is metadata.
- Never set or clear Jira's parent; the pull keeps the heading's local `PARENT`.
- Always run tests via `make test`; `make compile` must pass (warnings are errors).
- Commits: author/committer `Neil Locketz <neil@nlocketz.com>` via `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL` env vars; no `Co-Authored-By` line.

## Review Focus

1. A check GET fails (ticket deleted, 404, network) → sync stops with a message, buffer unlocked, nothing PUT/POSTed. (Task 3 test)
2. Changelog entries authored by me after the baseline, or by others at/before it → no conflict, no pull. (Task 2 tests)
3. Baseline and changelog timestamps in different UTC offsets (`+0000` vs `-0500`) → compared as instants, not strings. (Task 2 test)
4. Metadata pull on a nested Story with no `PARENT` property → no empty `PARENT` added; with one → value kept. (Task 2 tests)
5. Content conflict on one ticket and metadata-only change on another → the buffer is left untouched (no partial pull). (Task 3 test)

---

### Task 1: Record the `JIRA_SYNCED` baseline

**Files:**
- Modify: `org-tickets-api.el` (next to `org-tickets--issue-due-date`, ~line 47)
- Modify: `org-tickets-sync-phases.el` — `org-tickets--sync-result` record (~line 136), `org-tickets--make-existing-ticket-thunk` (167), `org-tickets--fire-ticket-put` (146), `org-tickets--sync-phase-3` (520)
- Create: `test/org-tickets-test-sync-remote-changes.el`; register it in `test/org-tickets-test.el`

**Interfaces:**
- Produces: `(org-tickets--issue-updated RESPONSE) -> string|nil` — `fields.updated` of an issue response.
- Produces: sync-result slot `synced` (string|nil).
- Produces: test helper `(org-tickets-test--issue-response &rest ARGS) -> parsed alist` in the new test file: plist `:updated :summary :labels :histories`, where `:histories` is a list of `(AUTHOR-ID AUTHOR-NAME CREATED FIELD-ID...)`; builds `fields` (with `attachment []`) plus `changelog.histories` in Jira's shape (`author.accountId`, `author.displayName`, `created`, `items[].fieldId`).  Built via `org-tickets-test--json` like `org-tickets-test--make-get-response`.

- [ ] **Step 1: Write the failing tests** in `test/org-tickets-test-sync-remote-changes.el` (standard header/footer, `(require 'org-tickets-test-fixtures)`, `(require 'org-tickets)`):
  - `org-tickets-test--sync-records-jira-synced-after-push`: feature `PROJ-10` with GET answering `:updated "2026-11-18T10:00:00.000+0000"`; after `org-tickets-test--run-sync`, `(org-tickets-test--prop-of "PROJ-10" "JIRA_SYNCED")` equals that string.
  - `org-tickets-test--sync-keeps-old-jira-synced-when-put-fails`: heading has `JIRA_SYNCED` `"2026-01-01T00:00:00.000+0000"`, no foreign history, GET answers `:updated "2026-11-18T10:00:00.000+0000"`, handler errors on PUT (call back with `nil "boom"`); afterwards `JIRA_SYNCED` is still the 2026-01-01 value.
  - `org-tickets-test--sync-new-ticket-gets-no-jira-synced`: a feature with no key is created; its heading has no `JIRA_SYNCED`.

- [ ] **Step 2: Run** `make test` — Expected: the first two new tests FAIL (property missing / not written), third passes.

- [ ] **Step 3: Implement**
  - `org-tickets--issue-updated` in `org-tickets-api.el`.
  - Add `synced` slot to `org-tickets--sync-result`; thread it from the GET in `--make-existing-ticket-thunk` through `--fire-ticket-put` into the result (add a `synced` parameter after `due-date`).
  - `(org-tickets--apply-synced-updates PHASE-1-RESULTS)`: for each result with a key, non-nil `synced`, and **no error**, `org-entry-put` `"JIRA_SYNCED"` via `org-tickets--with-ticket-at-key`.  Call it in phase 3 after `--apply-due-date-updates`.

- [ ] **Step 4: Run** `make test` — Expected: all PASS.

- [ ] **Step 5: Commit** — `git add` the touched files; message `Sync: record JIRA_SYNCED baseline after each successful push`.

---

### Task 2: Classify foreign changes and pull metadata

**Files:**
- Create: `org-tickets-conflict.el` (requires `org-tickets-core`, `org-tickets-api`, `org-tickets-import`)
- Modify: `org-tickets.el` — require `org-tickets-conflict` after `org-tickets-sync-phases`
- Create: `test/org-tickets-test-conflict.el`; register in `test/org-tickets-test.el`

**Interfaces:**
- Consumes: `org-tickets--parse-jira-issue`, `org-tickets--write-ticket-properties` (import.el).
- Produces:
  - `(org-tickets--jira-time-later-p A B) -> bool` — A strictly after B, both Jira timestamps (`2026-11-18T10:15:30.123+0000`), compared as instants (use `iso8601-parse` / `encode-time`, not string compare).
  - `(org-tickets--foreign-changes RESPONSE ACCOUNT-ID SINCE) -> list of (FIELD-ID . AUTHOR-NAME)` — one entry per changelog item in histories whose `created` is later than SINCE and whose `author.accountId` is not ACCOUNT-ID; oldest-first order not required.
  - `(org-tickets--content-change-p CHANGE) -> bool` — FIELD-ID is `"summary"` or `"description"`.
  - `(org-tickets--conflict-line KEY CHANGES) -> string` — e.g. `"PROJ-12: description changed by Alice"`; multiple content changes joined `", "`, each `"<field> changed by <name>"`, only content changes listed.
  - `(org-tickets--pull-ticket-metadata RESPONSE)` — at point on the ticket heading: writes every metadata property from the parsed issue with `clear-missing` t, leaves headline, description, `JIRA_SYNCED` untouched, and restores the local `PARENT` (re-put if it had a value, delete if it had none).

- [ ] **Step 1: Write the failing tests** in `test/org-tickets-test-conflict.el` (move `org-tickets-test--issue-response` into `test/org-tickets-test-fixtures.el` if both test files need it — fixtures is 580 lines, stays under 750):
  - `--jira-time-later-p-compares-across-offsets`: `"2026-11-18T10:00:00.000-0500"` is later than `"2026-11-18T14:30:00.000+0000"`; reverse is not; equal instants → nil.
  - `--foreign-changes-ignores-my-edits`: history by `"me"` after SINCE → nil.
  - `--foreign-changes-ignores-edits-at-or-before-baseline`: history by `"bob"` with `created` equal to SINCE, and one before → nil.
  - `--foreign-changes-lists-each-item`: one `"bob"`/`"Bob"` history after SINCE with items `labels`, `description` → `(("labels" . "Bob") ("description" . "Bob"))` (compare as sets).
  - `--content-change-p`: t for `summary`/`description`, nil for `labels`, `customfield_10020`.
  - `--conflict-line-lists-content-only`: changes `(("labels" . "Bob") ("summary" . "Alice") ("description" . "Bob"))` for `PROJ-12` → `"PROJ-12: summary changed by Alice, description changed by Bob"`.
  - `--pull-metadata-updates-properties-not-content`: heading `Old title` with body `Local body`, `LABELS` `a`, `JIRA_SYNCED` `X`; response with summary `New title`, labels `["b"]`, a description → after pull: headline still `Old title`, body still `Local body`, `LABELS` = `"b"`, `JIRA_SYNCED` = `X`.
  - `--pull-metadata-keeps-local-parent`: heading with `PARENT` `PROJ-1`, response with no parent → `PARENT` still `PROJ-1`.
  - `--pull-metadata-adds-no-empty-parent`: heading without `PARENT` → after pull `(org-entry-get (point) "PARENT")` is nil.

- [ ] **Step 2: Run** `make test` — Expected: FAIL, functions void.

- [ ] **Step 3: Implement** the five functions in `org-tickets-conflict.el` with the signatures above.

- [ ] **Step 4: Run** `make test` and `make compile` — Expected: all PASS, no warnings.

- [ ] **Step 5: Commit** — message `Conflict: classify foreign Jira changes and pull metadata`.

---

### Task 3: Pre-flight check wired into sync

**Files:**
- Modify: `org-tickets-conflict.el` (add the check driver; now also requires `org-tickets-async`, `org-tickets-inherit`, `org-tickets-sync-phases`)
- Modify: `org-tickets-sync.el` — `org-tickets--sync-to-jira` (247); require `org-tickets-conflict`
- Modify: `test/org-tickets-test-sync-remote-changes.el`
- Modify: `docs/dev/modules.md` — add the `org-tickets-conflict.el` row; stack becomes `links, inherit → sync-phases → conflict → sync → cmd`

**Interfaces:**
- Consumes: Task 2 functions; `org-tickets--async-request`, `org-tickets--async-batch`, `org-tickets--sync-cleanup`, `org-tickets--with-writable-buffer`, `org-tickets--inherit-parent-properties-in-buffer`.
- Produces:
  - `(org-tickets--remote-change-candidates) -> list of (KEY . SYNCED)` — every heading in the current buffer with both `JIRA_KEY` and a non-empty `JIRA_SYNCED`.
  - `(org-tickets--check-remote-changes ORG-BUFFER CONTINUE)` — async.  No candidates → call CONTINUE immediately with no requests.  Otherwise GET `/rest/api/3/myself` (take `accountId`), then batch GET `/rest/api/3/issue/KEY?expand=changelog`.  Then, in ORG-BUFFER via `--safe-with-buffer`:
    - any request error → `(message "org-tickets: Sync cancelled, could not check KEY for remote changes: %s" err)` and `org-tickets--sync-cleanup`;
    - any content change → `(display-warning 'org-tickets TEXT :warning)` where TEXT is `"Sync cancelled: tickets changed in Jira by someone else:\n"` followed by one `--conflict-line` per conflicting ticket, newline-separated, then `"\nMerge them by hand (org-tickets-pull-remote-changes) and sync again."`; then `org-tickets--sync-cleanup`; buffer untouched;
    - otherwise → for each ticket with foreign changes, `--pull-ticket-metadata` at its heading (writable), re-run `org-tickets--inherit-parent-properties-in-buffer`, `(message "org-tickets: Pulled remote metadata for %s" KEYS)`, then CONTINUE.
    - errors signalled inside these callbacks must still unlock the buffer (`condition-case` → `--sync-cleanup` + message).
  - `org-tickets--sync-to-jira` order becomes: guard, clear sprint cache, ensure issue types, inherit, lock buffer + save point + set in-progress, then `--check-remote-changes` with CONTINUE = `(org-tickets--sync-start ORG-BUFFER)`.
  - `(org-tickets--sync-start ORG-BUFFER)` (in `org-tickets-sync.el`) — parse document, `--all-features-exist-p`, `--progress-init`, phase 1 under `--with-sync-abort`: the tail of today's `--sync-to-jira`.

- [ ] **Step 1: Write the failing tests** in `test/org-tickets-test-sync-remote-changes.el`.  Use a `:get` function of endpoint answering `/rest/api/3/myself` with `{"accountId":"me"}` and issue endpoints with `org-tickets-test--issue-response`; log requests.  Baseline in all headings: `JIRA_SYNCED` `"2026-11-01T00:00:00.000+0000"`.
  - `--sync-cancels-on-foreign-description-edit`: Bob edited `description` on `PROJ-10` after baseline → no PUT/POST in log; `display-warning` (stub and capture) text contains `"PROJ-10: description changed by Bob"`; `buffer-read-only` nil and `org-tickets--sync-in-progress` nil afterwards.
  - `--sync-cancel-leaves-buffer-untouched`: `PROJ-10` content conflict, `PROJ-20` labels-only change → `buffer-string` identical before and after.
  - `--sync-pulls-foreign-metadata-then-pushes`: Bob changed `labels` on `PROJ-10` (remote labels `["remote"]`) → heading `LABELS` is `"remote"`, and the PUT payload's `labels` field is `["remote"]` (use `org-tickets-test--payload-field`).
  - `--sync-ignores-my-own-remote-edits`: history by `"me"` on description → PUT sent, no warning.
  - `--sync-skips-check-without-baseline`: no `JIRA_SYNCED` on any heading → log has no `/rest/api/3/myself` request and no `?expand=changelog` GET.
  - `--sync-cancels-when-check-request-fails`: handler errors the changelog GET for `PROJ-10` → no PUT, buffer unlocked, message mentions `PROJ-10`.

- [ ] **Step 2: Run** `make test` — Expected: new tests FAIL (PUT sent / no warning); all pre-existing sync tests still PASS.

- [ ] **Step 3: Implement** `--remote-change-candidates`, `--check-remote-changes`, `--sync-start`, and the reordered `--sync-to-jira`; keep each function ≲30 lines by splitting the result handling into helpers (e.g. `--report-content-conflicts`, `--apply-metadata-pulls`).  Update `docs/dev/modules.md`.

- [ ] **Step 4: Run** `make test`, `make compile`, `make lint` — Expected: all PASS, no warnings.

- [ ] **Step 5: Commit** — message `Sync: check for foreign Jira edits before pushing`.
